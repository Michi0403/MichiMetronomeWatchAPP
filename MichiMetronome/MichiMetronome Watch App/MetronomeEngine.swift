import Accelerate
import AVFoundation
import Combine
import Darwin
import Foundation
import UserNotifications
import WatchKit

private nonisolated final class HapticOutput: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.michi0403.michimetronome.haptics",
        qos: .userInteractive
    )

    private let lock = NSLock()

    private var inFlight = false
    private var cooldownUntil: TimeInterval = 0

    func requestClick() {
        let now = ProcessInfo.processInfo.systemUptime

        lock.lock()

        guard
            !inFlight,
            now >= cooldownUntil
        else {
            lock.unlock()
            return
        }

        inFlight = true
        lock.unlock()

        queue.async { [weak self] in
            guard let self else {
                return
            }

            let started = ProcessInfo.processInfo.systemUptime

            WKInterfaceDevice.current().play(.click)

            let elapsed =
                ProcessInfo.processInfo.systemUptime
                - started

            self.lock.lock()

            self.inFlight = false

            // WatchKit provides no "haptic engine ready" API.
            // If starting it blocks, back off rather than hammering it
            // every beat and building a delayed queue.
            if elapsed > 0.20 {
                self.cooldownUntil =
                    ProcessInfo.processInfo.systemUptime
                    + 5.0
            }

            self.lock.unlock()
        }
    }
}


private nonisolated struct MicrophoneFrame: Sendable {
    let timestamp: TimeInterval
    let rms: Double
    let frequency: Double?
    let midiValue: Double?
    let midiNote: Int?
    let cents: Double?
    let confidence: Double
    let onset: Bool
}

private nonisolated struct MicrophoneCapturedEvent: Sendable {
    let timestamp: TimeInterval
    let midiNote: Int
}

private nonisolated final class MicrophoneEventStore: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [MicrophoneCapturedEvent] = []

    @discardableResult
    func append(
        _ event: MicrophoneCapturedEvent
    ) -> Int {
        lock.lock()
        events.append(event)
        let count = events.count
        lock.unlock()
        return count
    }

    func reset() {
        lock.lock()
        events.removeAll(
            keepingCapacity: true
        )
        lock.unlock()
    }

    func snapshotAndClear()
        -> [MicrophoneCapturedEvent]
    {
        lock.lock()

        let result =
            events.sorted {
                $0.timestamp
                    < $1.timestamp
            }

        events.removeAll(
            keepingCapacity: true
        )

        lock.unlock()
        return result
    }
}

private nonisolated enum MicrophoneCaptureError: LocalizedError {
    case permissionDenied
    case noInput
    case startFailed(String)
    case activationFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Microphone permission is required."
        case .noInput:
            "No usable microphone input is available."
        case .startFailed(let message):
            "Microphone could not start: \(message)"
        case .activationFailed(let message):
            "Microphone audio session could not activate: \(message)"
        }
    }
}

private nonisolated final class MicrophoneAnalyzer: @unchecked Sendable {
    typealias FrameHandler =
        @Sendable (MicrophoneFrame) -> Void

    typealias EventHandler =
        @Sendable (MicrophoneCapturedEvent) -> Void

    typealias Completion =
        @Sendable (Result<Void, Error>) -> Void

    private let controlQueue = DispatchQueue(
        label:
            "com.michi0403.michimetronome.microphone.control",
        qos: .userInitiated
    )

    private let analysisQueue = DispatchQueue(
        label:
            "com.michi0403.michimetronome.microphone.analysis",
        qos: .userInitiated
    )

    // Only one copied microphone block may wait for analysis at a time.
    // This prevents a slow Watch CPU from building an unbounded queue of
    // PCM arrays while the real-time audio callback keeps arriving.
    private let analysisGate =
        DispatchSemaphore(value: 1)

    private var engine: AVAudioEngine?
    private var running = false
    private var starting = false

    // Analysis state lives only on analysisQueue.
    private var smoothedRMS = 0.0
    private var previousRMS = 0.0
    private var lastOnsetTime = -Double.infinity

    // The note shown in the UI is also the note-transition state used by the
    // recorder. A displayed note change can therefore never happen without
    // producing the corresponding recorded event.
    private var displayedMidiNote: Int?
    private var candidateMidiNote: Int?
    private var candidateFrameCount = 0

    private var lastAnalysisTime = -Double.infinity
    private var analysisEpoch: TimeInterval?

    // Per-recording analyzer telemetry. `droppedAnalysisBlocks` is updated by
    // the audio tap while the other fields live on analysisQueue.
    private var droppedAnalysisBlocks = 0
    private var analyzedFrameCount = 0
    private var analysisTotalDuration = 0.0
    private var analysisMaximumDuration = 0.0

    private var inputCallbackCount = 0
    private var inputFrameTotal = 0
    private var inputFrameMinimum = Int.max
    private var inputFrameMaximum = 0
    private var lastVisualFrameTime = -Double.infinity

    // Short blocks are good for onset latency, but not enough for reliable
    // fundamental detection. Keep a rolling window for pitch estimation.
    private var sampleHistory: [Float] = []
    private let maximumPitchWindow = 4_096

    func start(
        onFrame: @escaping FrameHandler,
        onEvent: EventHandler? = nil,
        completion: @escaping Completion
    ) {
        controlQueue.async { [weak self] in
            guard let self else {
                return
            }

            if self.running {
                DispatchQueue.main.async {
                    completion(.success(()))
                }
                return
            }

            guard !self.starting else {
                return
            }

            self.starting = true

            AVAudioApplication
                .requestRecordPermission {
                    [weak self] granted in

                    guard let self else {
                        return
                    }

                    self.controlQueue.async {
                        guard granted else {
                            self.starting = false

                            DispatchQueue.main.async {
                                completion(
                                    .failure(
                                        MicrophoneCaptureError
                                            .permissionDenied
                                    )
                                )
                            }
                            return
                        }

                        let session =
                            AVAudioSession.sharedInstance()

                        do {
                            // Keep recording isolated from Watch speaker output.
                            // The metronome playback session is explicitly
                            // deactivated before this path starts.
                            try session.setCategory(
                                .record,
                                mode: .measurement,
                                options: []
                            )
                        } catch {
                            self.starting = false

                            DispatchQueue.main.async {
                                completion(
                                    .failure(error)
                                )
                            }
                            return
                        }

                        // watchOS has a dedicated asynchronous activation path.
                        // Waiting for the actual activation result avoids the
                        // playback->record priority race seen on second use.
                        session.activate {
                            [weak self]
                            activated,
                            activationError in

                            guard let self else {
                                return
                            }

                            self.controlQueue.async {
                                guard
                                    activated,
                                    activationError == nil
                                else {
                                    self.starting = false

                                    let message =
                                        activationError?
                                            .localizedDescription
                                        ?? "The audio session was not activated."

                                    DispatchQueue.main.async {
                                        completion(
                                            .failure(
                                                MicrophoneCaptureError
                                                    .activationFailed(
                                                        message
                                                    )
                                            )
                                        )
                                    }
                                    return
                                }

                                do {
                                    try self.startEngine(
                                        onFrame: onFrame,
                                        onEvent: onEvent
                                    )

                                    self.running = true
                                    self.starting = false

                                    DispatchQueue.main.async {
                                        completion(
                                            .success(())
                                        )
                                    }
                                } catch {
                                    self.running = false
                                    self.starting = false

                                    try? session.setActive(
                                        false,
                                        options: [
                                            .notifyOthersOnDeactivation
                                        ]
                                    )

                                    DispatchQueue.main.async {
                                        completion(
                                            .failure(error)
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
        }
    }

    func stop(
        completion: (@Sendable () -> Void)? = nil
    ) {
        controlQueue.async { [weak self] in
            guard let self else {
                return
            }

            self.starting = false

            if let engine = self.engine {
                engine.inputNode.removeTap(
                    onBus: 0
                )
                engine.stop()
                engine.reset()
            }

            self.engine = nil
            self.running = false

            let session =
                AVAudioSession.sharedInstance()

            try? session.setActive(
                false,
                options: [
                    .notifyOthersOnDeactivation
                ]
            )

            // Flush any analyzer block that was already accepted before Stop.
            // Completion only fires after that block has had a chance to emit
            // its musical event.
            self.analysisQueue.async {
                let averageMs =
                    self.analyzedFrameCount > 0
                    ? (
                        self.analysisTotalDuration
                        / Double(
                            self.analyzedFrameCount
                        )
                    ) * 1_000.0
                    : 0

                let maximumMs =
                    self.analysisMaximumDuration
                    * 1_000.0

                let averageInputFrames =
                    self.inputCallbackCount > 0
                    ? Double(
                        self.inputFrameTotal
                    )
                        / Double(
                            self.inputCallbackCount
                        )
                    : 0

                let minimumInputFrames =
                    self.inputFrameMinimum
                        == Int.max
                    ? 0
                    : self.inputFrameMinimum

                print(
                    String(
                        format:
                            "[MichiPitch] ANALYSIS_STATS callbacks=%d inputFramesAvg=%.1f inputFramesMin=%d inputFramesMax=%d analyzed=%d dropped=%d avgMs=%.2f maxMs=%.2f",
                        self.inputCallbackCount,
                        averageInputFrames,
                        minimumInputFrames,
                        self.inputFrameMaximum,
                        self.analyzedFrameCount,
                        self.droppedAnalysisBlocks,
                        averageMs,
                        maximumMs
                    )
                )

                self.resetAnalysisState()

                self.controlQueue.asyncAfter(
                    deadline: .now() + 0.06
                ) {
                    if let completion {
                        DispatchQueue.main.async {
                            completion()
                        }
                    }
                }
            }
        }
    }

    private func startEngine(
        onFrame: @escaping FrameHandler,
        onEvent: EventHandler?
    ) throws {
        droppedAnalysisBlocks = 0
        analyzedFrameCount = 0
        analysisTotalDuration = 0
        analysisMaximumDuration = 0
        inputCallbackCount = 0
        inputFrameTotal = 0
        inputFrameMinimum = Int.max
        inputFrameMaximum = 0
        lastVisualFrameTime = -Double.infinity

        let audioEngine = AVAudioEngine()
        let input = audioEngine.inputNode
        let format =
            input.outputFormat(forBus: 0)

        guard
            format.sampleRate > 0,
            format.channelCount > 0
        else {
            throw MicrophoneCaptureError.noInput
        }

        print(
            String(
                format:
                    "[MichiPitch] MIC_FORMAT sampleRate=%.1f channels=%u requestedTapFrames=1024",
                format.sampleRate,
                format.channelCount
            )
        )

        analysisQueue.async {
            self.resetAnalysisState()
        }

        input.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: format
        ) {
            [weak self] buffer, _ in

            guard
                let self,
                let channel =
                    buffer.floatChannelData?[0]
            else {
                return
            }

            let count =
                Int(buffer.frameLength)

            guard count > 0 else {
                return
            }

            // Never let analysis work queue up behind the real-time tap.
            // If the previous block is still being processed, drop this block
            // rather than increasing latency and eventually hanging the UI.
            guard
                self.analysisGate.wait(
                    timeout: .now()
                ) == .success
            else {
                self.droppedAnalysisBlocks += 1
                return
            }

            // Copy immediately off the audio callback's temporary buffer.
            let samples = Array(
                UnsafeBufferPointer(
                    start: channel,
                    count: count
                )
            )

            let timestamp =
                ProcessInfo.processInfo
                    .systemUptime

            let sampleRate =
                format.sampleRate

            self.analysisQueue.async {
                defer {
                    self.analysisGate.signal()
                }

                self.inputCallbackCount += 1
                self.inputFrameTotal +=
                    samples.count
                self.inputFrameMinimum =
                    min(
                        self.inputFrameMinimum,
                        samples.count
                    )
                self.inputFrameMaximum =
                    max(
                        self.inputFrameMaximum,
                        samples.count
                    )

                // `bufferSize: 1024` is only a request. On physical Watch the
                // audio system may deliver a much larger hardware I/O block.
                // Process that block as 1024-sample hops so temporal pitch
                // resolution is determined by audio samples, not callback rate.
                let hopSize = 1_024

                let callbackStartTimestamp =
                    timestamp
                    - Double(samples.count)
                        / sampleRate

                var offset = 0

                while offset < samples.count {
                    let end =
                        min(
                            offset + hopSize,
                            samples.count
                        )

                    let count =
                        end - offset

                    // Tiny callback tails add no useful pitch information.
                    // Their samples are still represented by the timestamp
                    // progression of the following callback.
                    guard count >= 256 else {
                        break
                    }

                    let frameTimestamp =
                        callbackStartTimestamp
                        + Double(end)
                            / sampleRate

                    if
                        frameTimestamp
                            - self.lastAnalysisTime
                            >= 0.018
                    {
                        self.lastAnalysisTime =
                            frameTimestamp

                        let chunk =
                            Array(
                                samples[
                                    offset..<end
                                ]
                            )

                        let analysisStarted =
                            ProcessInfo.processInfo
                                .systemUptime

                        let frame =
                            self.analyze(
                                samples: chunk,
                                sampleRate:
                                    sampleRate,
                                timestamp:
                                    frameTimestamp
                            )

                        let analysisDuration =
                            ProcessInfo.processInfo
                                .systemUptime
                            - analysisStarted

                        self.analyzedFrameCount += 1
                        self.analysisTotalDuration +=
                            analysisDuration
                        self.analysisMaximumDuration =
                            max(
                                self.analysisMaximumDuration,
                                analysisDuration
                            )

                        // Musical events are never UI-throttled.
                        if
                            frame.onset,
                            let midiNote =
                                frame.midiNote
                        {
                            onEvent?(
                                MicrophoneCapturedEvent(
                                    timestamp:
                                        frame.timestamp,
                                    midiNote:
                                        midiNote
                                )
                            )
                        }

                        // The Watch display does not need a 40+ Hz pitch feed.
                        // Onsets are delivered immediately; otherwise cap
                        // visual updates around 16 Hz.
                        if
                            frame.onset
                            || frameTimestamp
                                - self.lastVisualFrameTime
                                >= 0.060
                        {
                            self.lastVisualFrameTime =
                                frameTimestamp
                            onFrame(frame)
                        }
                    }

                    offset = end
                }
            }
        }

        audioEngine.prepare()

        do {
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)

            throw MicrophoneCaptureError
                .startFailed(
                    error.localizedDescription
                )
        }

        engine = audioEngine
    }

    private func resetAnalysisState() {
        smoothedRMS = 0
        previousRMS = 0
        lastOnsetTime = -Double.infinity
        displayedMidiNote = nil
        candidateMidiNote = nil
        candidateFrameCount = 0
        lastAnalysisTime = -Double.infinity
        analysisEpoch = nil
        sampleHistory.removeAll(
            keepingCapacity: true
        )
    }

    private func analyze(
        samples: [Float],
        sampleRate: Double,
        timestamp: TimeInterval
    ) -> MicrophoneFrame {
        if analysisEpoch == nil {
            analysisEpoch = timestamp
        }

        guard !samples.isEmpty else {
            return MicrophoneFrame(
                timestamp: timestamp,
                rms: 0,
                frequency: nil,
                midiValue: nil,
                midiNote: displayedMidiNote,
                cents: nil,
                confidence: 0,
                onset: false
            )
        }

        var sumSquares = 0.0

        for sample in samples {
            let value = Double(sample)
            sumSquares += value * value
        }

        let rms = sqrt(
            sumSquares
            / Double(samples.count)
        )

        sampleHistory.append(
            contentsOf: samples
        )

        if
            sampleHistory.count
                > maximumPitchWindow
        {
            sampleHistory.removeFirst(
                sampleHistory.count
                    - maximumPitchWindow
            )
        }

        let pitch =
            estimateRollingPitch(
                sampleRate: sampleRate,
                rms: rms
            )

        let rawMidiValue: Double?
        let rawMidiNote: Int?

        if
            let frequency = pitch.frequency
        {
            let value =
                69.0
                + 12.0
                * log2(
                    frequency / 440.0
                )

            rawMidiValue = value
            rawMidiNote =
                min(
                    max(
                        Int(value.rounded()),
                        0
                    ),
                    127
                )
        } else {
            rawMidiValue = nil
            rawMidiNote = nil
        }

        let previousEnvelope =
            max(
                smoothedRMS,
                0.001
            )

        smoothedRMS =
            smoothedRMS * 0.88
            + rms * 0.12

        // YIN confidence is substantially more meaningful than the previous
        // raw autocorrelation peak. Allow quieter notes while requiring a
        // reliable periodicity estimate.
        let confidentPitch =
            rawMidiNote != nil
            && pitch.confidence >= 0.68
            && rms >= 0.0035

        // Piano/guitar re-attacks were previously almost invisible because
        // both attack ratios were too strict. The refractory interval still
        // prevents one physical attack from becoming several events.
        let amplitudeAttack =
            rms >= 0.0038
            && rms
                > max(
                    previousRMS * 1.10,
                    previousEnvelope * 1.08
                )

        let enoughGap =
            timestamp
            - lastOnsetTime
            >= 0.060

        var onset = false

        if
            confidentPitch,
            let rawMidiNote
        {
            if rawMidiNote == displayedMidiNote {
                candidateMidiNote = nil
                candidateFrameCount = 0

                // Re-articulation of the same pitch.
                if
                    amplitudeAttack,
                    enoughGap
                {
                    onset = true
                    lastOnsetTime =
                        timestamp

                    logAcceptedNoteEvent(
                        kind: "REATTACK",
                        timestamp: timestamp,
                        midiNote: rawMidiNote,
                        frequency:
                            pitch.frequency,
                        midiValue:
                            rawMidiValue,
                        confidence:
                            pitch.confidence
                    )
                }
            } else {
                // Require two consecutive analyzed frames with the same
                // rounded MIDI note. This suppresses semitone-boundary jitter
                // without the old octave-prone autocorrelation behavior.
                if candidateMidiNote == rawMidiNote {
                    candidateFrameCount += 1
                } else {
                    candidateMidiNote =
                        rawMidiNote
                    candidateFrameCount = 1
                }

                let distance =
                    displayedMidiNote.map {
                        abs(
                            rawMidiNote - $0
                        )
                    }
                    ?? 0

                let largeLeapIsPlausible =
                    distance < 12
                    || amplitudeAttack
                    || pitch.confidence >= 0.88

                // Internal 1024-sample hops are ~23 ms at 44.1 kHz, so
                // two agreeing frames cost only ~46 ms and reject the
                // one-frame octave/transient mistakes seen in the benchmark.
                let requiredFrames = 2

                if
                    candidateFrameCount
                        >= requiredFrames,
                    largeLeapIsPlausible,
                    enoughGap
                {
                    displayedMidiNote =
                        rawMidiNote
                    candidateMidiNote = nil
                    candidateFrameCount = 0

                    // The same state transition powers display + recording.
                    onset = true
                    lastOnsetTime =
                        timestamp

                    logAcceptedNoteEvent(
                        kind: "CHANGE",
                        timestamp: timestamp,
                        midiNote: rawMidiNote,
                        frequency:
                            pitch.frequency,
                        midiValue:
                            rawMidiValue,
                        confidence:
                            pitch.confidence
                    )
                }
            }
        } else {
            candidateMidiNote = nil
            candidateFrameCount = 0
        }

        let displayCents: Double?

        if
            let rawMidiValue,
            let displayedMidiNote
        {
            displayCents =
                (
                    rawMidiValue
                    - Double(
                        displayedMidiNote
                    )
                )
                * 100.0
        } else {
            displayCents = nil
        }

        previousRMS = rms

        return MicrophoneFrame(
            timestamp: timestamp,
            rms: rms,
            frequency:
                pitch.frequency,
            midiValue:
                rawMidiValue,
            midiNote:
                displayedMidiNote,
            cents:
                displayCents,
            confidence:
                pitch.confidence,
            onset: onset
        )
    }

    private func logAcceptedNoteEvent(
        kind: String,
        timestamp: TimeInterval,
        midiNote: Int,
        frequency: Double?,
        midiValue: Double?,
        confidence: Double
    ) {
        let relative =
            max(
                0,
                timestamp
                - (analysisEpoch ?? timestamp)
            )

        let cents: Double

        if let midiValue {
            cents =
                (
                    midiValue
                    - Double(midiNote)
                )
                * 100.0
        } else {
            cents = 0
        }

        let frequencyText: String

        if let frequency {
            frequencyText =
                String(
                    format: "%.2f",
                    frequency
                )
        } else {
            frequencyText = "n/a"
        }

        let line =
            String(
                format:
                    "[MichiPitch] %@ t=%.3fs uptime=%.3f note=%@ midi=%d freq=%@Hz cents=%+.1f confidence=%.3f",
                kind,
                relative,
                timestamp,
                Self.debugNoteName(
                    midiNote: midiNote
                ),
                midiNote,
                frequencyText,
                cents,
                confidence
            )

        print(line)
    }

    private static func debugNoteName(
        midiNote: Int
    ) -> String {
        let names = [
            "C", "C#", "D", "D#",
            "E", "F", "F#", "G",
            "G#", "A", "A#", "B"
        ]

        let note =
            min(max(midiNote, 0), 127)

        let octave =
            note / 12 - 1

        return
            "\(names[note % 12])\(octave)"
    }

    private func estimateRollingPitch(
        sampleRate: Double,
        rms: Double
    ) -> (
        frequency: Double?,
        confidence: Double
    ) {
        guard
            rms >= 0.0025,
            sampleHistory.count >= 1_024
        else {
            return (nil, 0)
        }

        // High and upper-mid notes need temporal resolution more than a long
        // observation window. 1024 samples are ~23 ms at 44.1 kHz.
        let fastEstimate =
            estimatePitchYINAccelerated(
                samples:
                    Array(
                        sampleHistory
                            .suffix(1_024)
                    ),
                sampleRate:
                    sampleRate,
                minimumFrequency:
                    110.0,
                maximumFrequency:
                    1_800.0
            )

        if
            let fastFrequency =
                fastEstimate.frequency,
            fastFrequency >= 180.0,
            fastEstimate.confidence >= 0.82
        {
            return fastEstimate
        }

        guard sampleHistory.count >= 2_048 else {
            return fastEstimate
        }

        // Mid/low notes need several periods for stable identification.
        let mediumEstimate =
            estimatePitchYINAccelerated(
                samples:
                    Array(
                        sampleHistory
                            .suffix(2_048)
                    ),
                sampleRate:
                    sampleRate,
                minimumFrequency:
                    65.0,
                maximumFrequency:
                    1_200.0
            )

        let provisional: (
            frequency: Double?,
            confidence: Double
        )

        if
            mediumEstimate.confidence
                >= fastEstimate.confidence
                    - 0.03
        {
            provisional =
                mediumEstimate
        } else {
            provisional =
                fastEstimate
        }

        let provisionalFrequency =
            provisional.frequency

        // Low fundamentals are the difficult case: a short window may report
        // their second harmonic with excellent confidence. For anything below
        // ~220 Hz (or uncertain), explicitly compare a 4096-sample estimate.
        let needsLongWindow =
            sampleHistory.count >= 4_096
            && (
                provisionalFrequency == nil
                || provisionalFrequency! < 220.0
                || provisional.confidence < 0.80
            )

        guard needsLongWindow else {
            return provisional
        }

        let longEstimate =
            estimatePitchYINAccelerated(
                samples:
                    Array(
                        sampleHistory
                            .suffix(4_096)
                    ),
                sampleRate:
                    sampleRate,
                minimumFrequency:
                    40.0,
                maximumFrequency:
                    600.0
            )

        guard
            let longFrequency =
                longEstimate.frequency
        else {
            return provisional
        }

        guard
            let shortFrequency =
                provisional.frequency
        else {
            return longEstimate
        }

        let ratio =
            max(
                shortFrequency,
                longFrequency
            )
            / min(
                shortFrequency,
                longFrequency
            )

        // Prefer the lower estimate when the short window landed on a clean
        // integer harmonic (2x/3x/4x) and the fundamental is nearly as strong.
        let harmonicRatio =
            (
                abs(ratio - 2.0) <= 0.08
                || abs(ratio - 3.0) <= 0.10
                || abs(ratio - 4.0) <= 0.12
            )

        if
            longFrequency < shortFrequency,
            harmonicRatio,
            longEstimate.confidence
                >= provisional.confidence
                    - 0.10
        {
            return longEstimate
        }

        if
            longEstimate.confidence
                > provisional.confidence
                    + 0.035
        {
            return longEstimate
        }

        return provisional
    }

    /// YIN-style estimator with the expensive lag dot-products delegated to
    /// Accelerate/vDSP instead of nested Swift loops.
    private func estimatePitchYINAccelerated(
        samples: [Float],
        sampleRate: Double,
        minimumFrequency: Double,
        maximumFrequency: Double
    ) -> (
        frequency: Double?,
        confidence: Double
    ) {
        guard samples.count >= 512 else {
            return (nil, 0)
        }

        let targetRate = 12_000.0

        let decimation =
            max(
                1,
                Int(
                    floor(
                        sampleRate
                        / targetRate
                    )
                )
            )

        let reducedRate =
            sampleRate
            / Double(decimation)

        var reduced: [Float] = []
        reduced.reserveCapacity(
            samples.count
                / decimation + 1
        )

        var sourceIndex = 0

        while sourceIndex < samples.count {
            let end =
                min(
                    sourceIndex
                        + decimation,
                    samples.count
                )

            var total: Float = 0

            for index in sourceIndex..<end {
                total += samples[index]
            }

            reduced.append(
                total
                / Float(
                    end - sourceIndex
                )
            )

            sourceIndex = end
        }

        guard reduced.count >= 256 else {
            return (nil, 0)
        }

        var mean: Float = 0
        vDSP_meanv(
            reduced,
            1,
            &mean,
            vDSP_Length(
                reduced.count
            )
        )

        var negativeMean = -mean

        vDSP_vsadd(
            reduced,
            1,
            &negativeMean,
            &reduced,
            1,
            vDSP_Length(
                reduced.count
            )
        )

        let minimumLag =
            max(
                2,
                Int(
                    floor(
                        reducedRate
                        / maximumFrequency
                    )
                )
            )

        let maximumLag =
            min(
                Int(
                    ceil(
                        reducedRate
                        / minimumFrequency
                    )
                ),
                reduced.count / 2
            )

        guard
            maximumLag
                > minimumLag + 2
        else {
            return (nil, 0)
        }

        let comparisonCount =
            reduced.count
            - maximumLag

        guard comparisonCount >= 96 else {
            return (nil, 0)
        }

        // Prefix energy lets each YIN difference value use one accelerated dot
        // product plus O(1) energy lookups:
        //
        // Σ(x-y)^2 = Σx^2 + Σy^2 - 2Σxy
        var energyPrefix =
            Array(
                repeating: 0.0,
                count:
                    reduced.count + 1
            )

        for index in reduced.indices {
            let value =
                Double(reduced[index])

            energyPrefix[index + 1] =
                energyPrefix[index]
                + value * value
        }

        let firstEnergy =
            energyPrefix[
                comparisonCount
            ]

        var difference =
            Array(
                repeating: 0.0,
                count:
                    maximumLag + 1
            )

        reduced.withUnsafeBufferPointer {
            buffer in

            guard let base = buffer.baseAddress else {
                return
            }

            for lag in 1...maximumLag {
                var dot: Float = 0

                vDSP_dotpr(
                    base,
                    1,
                    base.advanced(
                        by: lag
                    ),
                    1,
                    &dot,
                    vDSP_Length(
                        comparisonCount
                    )
                )

                let secondEnergy =
                    energyPrefix[
                        lag
                        + comparisonCount
                    ]
                    - energyPrefix[lag]

                difference[lag] =
                    max(
                        0,
                        firstEnergy
                        + secondEnergy
                        - 2.0 * Double(dot)
                    )
            }
        }

        var normalized =
            Array(
                repeating: 1.0,
                count:
                    maximumLag + 1
            )

        var runningSum = 0.0

        for lag in 1...maximumLag {
            runningSum +=
                difference[lag]

            if runningSum > 0 {
                normalized[lag] =
                    difference[lag]
                    * Double(lag)
                    / runningSum
            }
        }

        let threshold = 0.18
        var selectedLag: Int?

        var lag = minimumLag

        while lag <= maximumLag {
            if normalized[lag] < threshold {
                var localLag = lag

                while
                    localLag + 1
                        <= maximumLag,
                    normalized[
                        localLag + 1
                    ]
                        < normalized[
                            localLag
                        ]
                {
                    localLag += 1
                }

                selectedLag = localLag
                break
            }

            lag += 1
        }

        if selectedLag == nil {
            var bestLag = minimumLag
            var bestValue =
                normalized[minimumLag]

            if
                minimumLag + 1
                    <= maximumLag
            {
                for candidate in
                    (minimumLag + 1)...maximumLag
                {
                    if
                        normalized[candidate]
                            < bestValue
                    {
                        bestValue =
                            normalized[candidate]
                        bestLag =
                            candidate
                    }
                }
            }

            guard bestValue <= 0.34 else {
                return (
                    nil,
                    max(
                        0,
                        1.0 - bestValue
                    )
                )
            }

            selectedLag = bestLag
        }

        guard let selectedLag else {
            return (nil, 0)
        }

        var refinedLag =
            Double(selectedLag)

        if
            selectedLag > minimumLag,
            selectedLag < maximumLag
        {
            let left =
                normalized[
                    selectedLag - 1
                ]

            let center =
                normalized[
                    selectedLag
                ]

            let right =
                normalized[
                    selectedLag + 1
                ]

            let denominator =
                left
                - 2.0 * center
                + right

            if abs(denominator) > 1e-12 {
                let offset =
                    0.5
                    * (left - right)
                    / denominator

                refinedLag +=
                    min(
                        1.0,
                        max(
                            -1.0,
                            offset
                        )
                    )
            }
        }

        guard refinedLag > 0 else {
            return (nil, 0)
        }

        let frequency =
            reducedRate
            / refinedLag

        guard
            frequency
                >= minimumFrequency,
            frequency
                <= maximumFrequency
        else {
            return (nil, 0)
        }

        let confidence =
            max(
                0,
                min(
                    1,
                    1.0
                    - normalized[
                        selectedLag
                    ]
                )
            )

        return (
            frequency,
            confidence
        )
    }

}

private nonisolated enum MusicalClock {
    // A MIDI-style musical resolution. We intentionally keep this internal
    // instead of depending on CoreMIDI/AVAudioSequencer, because Apple's
    // MIDI instrument/sequencer playback APIs are unavailable on watchOS.
    static let ticksPerBeat: Int64 = 960

    static func tick(
        forBeatIndex beatIndex: Int
    ) -> Int64 {
        Int64(max(beatIndex, 0))
            * ticksPerBeat
    }

    static func seconds(
        forTick tick: Int64,
        bpm: Double
    ) -> TimeInterval {
        let beats =
            Double(tick)
            / Double(ticksPerBeat)

        return beats
            * 60.0
            / max(bpm, 1)
    }
}

private nonisolated struct PlaybackPlan: Sendable {
    let mode: MetronomeMode
    let bpm: Double
    let beatsPerBar: Int
    let manualIntervals: [Double]
    let manualMidiNotes: [Int?]
    let baseMidiNote: Int
    let bpmBeatAccents: [Bool]
    let bpmBeatNoteOffsets: [Int?]
    let accentDownbeat: Bool
    let audioEnabled: Bool
    let hapticsEnabled: Bool
    let clickTone: ClickTone
    let accentTone: AccentTone

    func step(
        for eventIndex: Int
    ) -> Int {
        switch mode {
        case .bpm:
            return eventIndex
                % max(beatsPerBar, 1)

        case .manual:
            guard
                !manualIntervals.isEmpty
            else {
                return 0
            }

            return eventIndex
                % manualIntervals.count
        }
    }

    func accent(
        for eventIndex: Int
    ) -> Bool {
        let currentStep =
            step(for: eventIndex)

        switch mode {
        case .bpm:
            if
                currentStep >= 0,
                currentStep < bpmBeatAccents.count
            {
                return bpmBeatAccents[
                    currentStep
                ]
            }

            return
                accentDownbeat
                && currentStep == 0

        case .manual:
            return
                accentDownbeat
                && currentStep == 0
        }
    }

    func recordedMidiNote(
        for eventIndex: Int
    ) -> Int? {
        guard
            mode == .manual,
            !manualIntervals.isEmpty,
            !manualMidiNotes.isEmpty
        else {
            return nil
        }

        let step =
            eventIndex
            % manualIntervals.count

        guard step < manualMidiNotes.count else {
            return nil
        }

        return manualMidiNotes[step]
    }

    func playbackMidiNote(
        for eventIndex: Int
    ) -> Int {
        switch mode {
        case .bpm:
            let currentStep =
                step(for: eventIndex)

            if
                currentStep >= 0,
                currentStep
                    < bpmBeatNoteOffsets.count,
                let offset =
                    bpmBeatNoteOffsets[
                        currentStep
                    ]
            {
                return min(
                    max(
                        baseMidiNote + offset,
                        MetronomeSettings
                            .minimumBaseMidiNote
                    ),
                    MetronomeSettings
                        .maximumBaseMidiNote
                )
            }

            return baseMidiNote

        case .manual:
            return
                recordedMidiNote(
                    for: eventIndex
                )
                ?? baseMidiNote
        }
    }

    func noteDuration(
        for eventIndex: Int
    ) -> TimeInterval {
        switch mode {
        case .bpm:
            let beatDuration =
                60.0 / max(bpm, 1)

            return min(
                0.16,
                max(
                    0.055,
                    beatDuration * 0.42
                )
            )

        case .manual:
            guard !manualIntervals.isEmpty else {
                return 0.10
            }

            let interval =
                manualIntervals[
                    eventIndex
                    % manualIntervals.count
                ]

            return min(
                0.35,
                max(
                    0.035,
                    interval * 0.52
                )
            )
        }
    }

    /// Absolute musical time from the start of this playback.
    ///
    /// This is deliberately NOT calculated by repeatedly adding the previous
    /// interval. Every event is mapped independently from its musical position
    /// back to the start time, so long-running playback can't accumulate
    /// per-beat floating-point/host-time rounding error.
    func elapsedSeconds(
        for eventIndex: Int
    ) -> TimeInterval {
        let index = max(eventIndex, 0)

        switch mode {
        case .bpm:
            let tick =
                MusicalClock.tick(
                    forBeatIndex: index
                )

            return MusicalClock.seconds(
                forTick: tick,
                bpm: bpm
            )

        case .manual:
            guard
                !manualIntervals.isEmpty
            else {
                return 0
            }

            let count =
                manualIntervals.count

            let cycle =
                index / count

            let step =
                index % count

            let cycleDuration =
                manualIntervals.reduce(
                    0,
                    +
                )

            let stepOffset =
                manualIntervals
                    .prefix(step)
                    .reduce(0, +)

            return
                Double(cycle)
                    * cycleDuration
                + stepOffset
        }
    }

    func hostTime(
        for eventIndex: Int,
        startHostTime: UInt64
    ) -> UInt64 {
        startHostTime
            &+ AVAudioTime.hostTime(
                forSeconds:
                    elapsedSeconds(
                        for: eventIndex
                    )
            )
    }

    /// Returns the first event whose absolute position is not earlier
    /// than `hostTime`. This lets the live UI/haptic side skip straight
    /// over a system stall instead of replaying missed beats.
    func firstEventIndex(
        atOrAfter hostTime: UInt64,
        startHostTime: UInt64
    ) -> Int {
        guard
            hostTime > startHostTime
        else {
            return 0
        }

        let elapsed =
            AVAudioTime.seconds(
                forHostTime:
                    hostTime
                    - startHostTime
            )

        switch mode {
        case .bpm:
            let beatDuration =
                60.0 / max(bpm, 1)

            return max(
                0,
                Int(
                    ceil(
                        elapsed
                        / beatDuration
                        - 0.000_000_001
                    )
                )
            )

        case .manual:
            guard
                !manualIntervals.isEmpty
            else {
                return 0
            }

            let cycleDuration =
                manualIntervals.reduce(
                    0,
                    +
                )

            guard cycleDuration > 0 else {
                return 0
            }

            let count =
                manualIntervals.count

            let cycle =
                max(
                    0,
                    Int(
                        floor(
                            elapsed
                            / cycleDuration
                        )
                    )
                )

            let insideCycle =
                elapsed
                - Double(cycle)
                    * cycleDuration

            var offset = 0.0

            for step in 0..<count {
                if
                    offset
                    + 0.000_000_001
                    >= insideCycle
                {
                    return cycle
                        * count
                        + step
                }

                offset +=
                    manualIntervals[step]
            }

            return
                (cycle + 1)
                * count
        }
    }
}

@MainActor
final class MetronomeEngine: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isPreparing = false
    @Published private(set) var beatIndex = 0
    @Published private(set) var settings: MetronomeSettings
    @Published private(set) var isRecordingManualPattern = false
    @Published private(set) var manualTapCount = 0
    @Published private(set) var lastBeatDate: Date?
    @Published private(set) var outputWarning: String?
    @Published private(set) var currentPlaybackMidiNote: Int?

    @Published private(set) var isPreparingMicrophone = false
    @Published private(set) var isRecordingMicrophonePattern = false
    @Published private(set) var isTunerActive = false
    @Published private(set) var microphoneError: String?
    @Published private(set) var detectedFrequency: Double?
    @Published private(set) var detectedMidiNote: Int?
    @Published private(set) var detectedCents: Double?
    @Published private(set) var microphoneLevel: Double = 0
    @Published private(set) var microphoneOnsetCount = 0

    private var playbackTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?

    private var generation: UInt64 = 0
    private var recordingTapTimes: [TimeInterval] = []
    private let microphoneEventStore =
        MicrophoneEventStore()

    private var resumeAfterForeground = false
    private var lastTunerDisplayTimestamp =
        -Double.infinity

    private let audio = ClickAudioEngine()
    private let haptics = HapticOutput()
    private let microphone = MicrophoneAnalyzer()

    init() {
        settings = SettingsStore.load()

        Task {
            await audio.setTone(settings.clickTone)
        }
    }

    deinit {
        playbackTask?.cancel()
        preparationTask?.cancel()
    }

    var canStart: Bool {
        guard !microphoneOwnsAudioSession else {
            return false
        }

        switch settings.mode {
        case .bpm:
            return true

        case .manual:
            return !settings.manualIntervals.isEmpty
        }
    }

    var manualCycleDuration: TimeInterval {
        settings.manualIntervals.reduce(0, +)
    }

    var manualBeatPositions: [Double] {
        let intervals = settings.manualIntervals
        let total = intervals.reduce(0, +)

        guard total > 0, !intervals.isEmpty else {
            return []
        }

        var elapsed = 0.0
        var positions: [Double] = []

        for interval in intervals {
            positions.append(elapsed / total)
            elapsed += interval
        }

        return positions
    }

    var manualApproximateBPM: Int? {
        guard !settings.manualIntervals.isEmpty else {
            return nil
        }

        let average =
            settings.manualIntervals.reduce(0, +)
            / Double(settings.manualIntervals.count)

        guard average > 0 else {
            return nil
        }

        return Int((60.0 / average).rounded())
    }

    var detectedNoteName: String? {
        guard let detectedMidiNote else {
            return nil
        }

        return Self.noteName(
            midiNote: detectedMidiNote
        )
    }

    var baseNoteName: String {
        Self.noteName(
            midiNote: settings.baseMidiNote
        )
    }

    func bpmBeatMidiNote(
        at beat: Int
    ) -> Int {
        guard
            beat >= 0,
            beat < settings.beatsPerBar
        else {
            return settings.baseMidiNote
        }

        guard
            beat < settings
                .bpmBeatNoteOffsets.count,
            let offset =
                settings
                    .bpmBeatNoteOffsets[
                        beat
                    ]
        else {
            return settings.baseMidiNote
        }

        return min(
            max(
                settings.baseMidiNote
                    + offset,
                MetronomeSettings
                    .minimumBaseMidiNote
            ),
            MetronomeSettings
                .maximumBaseMidiNote
        )
    }

    func bpmBeatNoteName(
        at beat: Int
    ) -> String {
        Self.noteName(
            midiNote:
                bpmBeatMidiNote(
                    at: beat
                )
        )
    }

    func bpmBeatOverrideMidiNote(
        at beat: Int
    ) -> Int? {
        guard
            beat >= 0,
            beat
                < settings
                    .bpmBeatNoteOffsets.count,
            settings
                .bpmBeatNoteOffsets[
                    beat
                ] != nil
        else {
            return nil
        }

        return bpmBeatMidiNote(
            at: beat
        )
    }

    func isBPMBeatAccented(
        _ beat: Int
    ) -> Bool {
        guard
            beat >= 0,
            beat < settings
                .bpmBeatAccents.count
        else {
            return
                beat == 0
                && settings.accentDownbeat
        }

        return settings
            .bpmBeatAccents[
                beat
            ]
    }

    var currentPlaybackNoteName: String? {
        guard let currentPlaybackMidiNote else {
            return nil
        }

        return Self.noteName(
            midiNote: currentPlaybackMidiNote
        )
    }

    var manualNoteSummary: String? {
        let names: [String] =
            settings.manualMidiNotes
                .compactMap {
                    (note: Int?) -> String? in

                    guard let note else {
                        return nil
                    }

                    return Self.noteName(
                        midiNote: note
                    )
                }

        guard !names.isEmpty else {
            return nil
        }

        return names.joined(
            separator: "  "
        )
    }

    private var microphoneOwnsAudioSession: Bool {
        isPreparingMicrophone
            || isRecordingMicrophonePattern
            || isTunerActive
    }

    func prepareForUse() {
        guard
            settings.audioEnabled,
            !microphoneOwnsAudioSession
        else {
            return
        }

        let tone = settings.clickTone

        Task {
            _ = await audio.prepareSession(tone: tone)
        }
    }

    func manualProgress(at date: Date) -> Double {
        guard
            isRunning,
            settings.mode == .manual,
            manualCycleDuration > 0,
            let lastBeatDate
        else {
            return 0
        }

        let positions = manualBeatPositions

        guard
            !positions.isEmpty,
            beatIndex < positions.count
        else {
            return 0
        }

        let cycle = manualCycleDuration
        let basePosition =
            positions[beatIndex] * cycle

        let elapsedSinceBeat = max(
            0,
            date.timeIntervalSince(lastBeatDate)
        )

        let raw =
            basePosition + elapsedSinceBeat

        return raw.truncatingRemainder(
            dividingBy: cycle
        ) / cycle
    }

    func toggle() {
        if isRunning || isPreparing {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard
            !isRunning,
            !isPreparing,
            !microphoneOwnsAudioSession,
            canStart
        else {
            return
        }

        generation &+= 1

        let expectedGeneration = generation
        let requestedSettings = settings

        isPreparing = true
        outputWarning = nil

        preparationTask?.cancel()

        preparationTask = Task { [weak self] in
            guard let self else {
                return
            }

            var audioReady = true

            if requestedSettings.audioEnabled {
                audioReady = await self.audio.prepareSession(
                    tone: requestedSettings.clickTone
                )
            }

            guard
                !Task.isCancelled,
                self.generation == expectedGeneration
            else {
                return
            }

            let effectiveAudio =
                requestedSettings.audioEnabled
                && audioReady

            if requestedSettings.audioEnabled,
               !audioReady {
                self.outputWarning =
                    requestedSettings.hapticsEnabled
                    ? "Audio could not become ready. Running haptic-only."
                    : "Audio could not become ready."
            }

            guard
                effectiveAudio
                || requestedSettings.hapticsEnabled
            else {
                self.isPreparing = false
                return
            }

            await self.audio.clearScheduledAudio()

            guard
                !Task.isCancelled,
                self.generation == expectedGeneration
            else {
                return
            }

            let plan = PlaybackPlan(
                mode: requestedSettings.mode,
                bpm: requestedSettings.bpm,
                beatsPerBar:
                    requestedSettings.beatsPerBar,
                manualIntervals:
                    requestedSettings.manualIntervals,
                manualMidiNotes:
                    requestedSettings.manualMidiNotes,
                baseMidiNote:
                    requestedSettings.baseMidiNote,
                bpmBeatAccents:
                    requestedSettings.bpmBeatAccents,
                bpmBeatNoteOffsets:
                    requestedSettings.bpmBeatNoteOffsets,
                accentDownbeat:
                    requestedSettings.accentDownbeat,
                audioEnabled: effectiveAudio,
                hapticsEnabled:
                    requestedSettings.hapticsEnabled,
                clickTone:
                    requestedSettings.clickTone,
                accentTone:
                    requestedSettings.accentTone
            )

            self.beatIndex = 0
            self.lastBeatDate = nil
            self.isPreparing = false
            self.isRunning = true

            // Give Core Audio a small scheduling runway. Nothing is emitted
            // before all required audio setup has completed.
            let startHostTime =
                mach_absolute_time()
                + AVAudioTime.hostTime(
                    forSeconds: 0.25
                )

            self.beginPlaybackLoop(
                plan: plan,
                generation: expectedGeneration,
                startHostTime: startHostTime
            )
        }
    }

    func stop() {
        generation &+= 1

        preparationTask?.cancel()
        preparationTask = nil

        playbackTask?.cancel()
        playbackTask = nil

        isPreparing = false
        isRunning = false
        beatIndex = 0
        lastBeatDate = nil
        currentPlaybackMidiNote = nil

        Task(priority: .userInitiated) {
            await audio.clearScheduledAudio()
        }
    }

    func selectMode(_ mode: MetronomeMode) {
        guard settings.mode != mode else {
            return
        }

        stop()

        updateSettings { value in
            value.mode = mode
        }
    }

    func setBPM(_ bpm: Double) {
        updateSettings { value in
            value.bpm = bpm
        }

        if isRunning {
            rescheduleActivePlayback()
        }
    }

    func nudgeBPM(_ delta: Int) {
        setBPM(
            settings.bpm + Double(delta)
        )
    }

    func setTimeSignature(
        _ timeSignature: TimeSignature
    ) {
        guard
            settings.timeSignature
                != timeSignature
        else {
            return
        }

        updateSettings { value in
            value.timeSignature =
                timeSignature
            value.rhythmPreset =
                .custom
        }

        if isRunning {
            rescheduleActivePlayback()
        }
    }

    func setHapticsEnabled(_ enabled: Bool) {
        updateSettings { value in
            value.hapticsEnabled = enabled
        }

        if isRunning {
            rescheduleActivePlayback()
        }
    }

    func setAudioEnabled(_ enabled: Bool) {
        updateSettings { value in
            value.audioEnabled = enabled
        }

        if
            enabled,
            !microphoneOwnsAudioSession
        {
            prepareForUse()
        }

        if isRunning {
            restartPlayback()
        }
    }

    func setBaseMidiNote(
        _ midiNote: Int
    ) {
        let note = min(
            max(
                midiNote,
                MetronomeSettings
                    .minimumBaseMidiNote
            ),
            MetronomeSettings
                .maximumBaseMidiNote
        )

        guard settings.baseMidiNote != note else {
            return
        }

        updateSettings { value in
            value.baseMidiNote = note
        }

        if isRunning {
            rescheduleActivePlayback()
        }
    }

    func nudgeBaseMidiNote(
        _ delta: Int
    ) {
        setBaseMidiNote(
            settings.baseMidiNote + delta
        )
    }

    func setAccentDownbeat(_ enabled: Bool) {
        updateSettings { value in
            value.accentDownbeat = enabled

            if value.bpmBeatAccents.isEmpty {
                value.bpmBeatAccents =
                    Array(
                        repeating: false,
                        count:
                            max(
                                value.beatsPerBar,
                                1
                            )
                    )
            }

            value.bpmBeatAccents[0] =
                enabled
            value.rhythmPreset =
                .custom
        }

        if isRunning {
            rescheduleActivePlayback()
        }
    }

    func setAccentTone(
        _ tone: AccentTone
    ) {
        guard settings.accentTone != tone else {
            return
        }

        updateSettings { value in
            value.accentTone = tone
        }

        if isRunning {
            rescheduleActivePlayback()
        }
    }

    func setBPMBeat(
        _ beat: Int,
        accent: Bool,
        midiNoteOverride: Int?
    ) {
        guard
            beat >= 0,
            beat < settings.beatsPerBar
        else {
            return
        }

        updateSettings { value in
            let count =
                max(
                    value.beatsPerBar,
                    1
                )

            if value.bpmBeatAccents.count < count {
                value.bpmBeatAccents.append(
                    contentsOf: Array(
                        repeating: false,
                        count:
                            count
                            - value
                                .bpmBeatAccents
                                .count
                    )
                )
            }

            if value.bpmBeatNoteOffsets.count < count {
                value.bpmBeatNoteOffsets.append(
                    contentsOf: Array(
                        repeating: nil,
                        count:
                            count
                            - value
                                .bpmBeatNoteOffsets
                                .count
                    )
                )
            }

            value.bpmBeatAccents[beat] =
                accent

            if beat == 0 {
                value.accentDownbeat =
                    accent
            }

            if let midiNoteOverride {
                let note =
                    min(
                        max(
                            midiNoteOverride,
                            MetronomeSettings
                                .minimumBaseMidiNote
                        ),
                        MetronomeSettings
                            .maximumBaseMidiNote
                    )

                value.bpmBeatNoteOffsets[
                    beat
                ] =
                    note
                    - value.baseMidiNote
            } else {
                value.bpmBeatNoteOffsets[
                    beat
                ] = nil
            }

            value.rhythmPreset =
                .custom
        }

        if isRunning {
            rescheduleActivePlayback()
        }
    }

    func applyRhythmPreset(
        _ preset: RhythmPreset
    ) {
        guard preset != .custom else {
            return
        }

        updateSettings { value in
            value.mode = .bpm
            value.timeSignature =
                preset.timeSignature
            value.rhythmPreset =
                preset
            value.bpmBeatAccents =
                preset.accentPattern
            value.accentDownbeat =
                preset.accentPattern
                    .first
                    ?? true
            value.bpmBeatNoteOffsets =
                preset.noteOffsets

            // A pronounced harmonic accent is the safe preset default.
            value.accentTone =
                .harmonic
        }

        if isRunning {
            rescheduleActivePlayback()
        }
    }

    func setClickTone(_ tone: ClickTone) {
        updateSettings { value in
            value.clickTone = tone
        }

        Task {
            await audio.setTone(tone)
        }

        if isRunning {
            rescheduleActivePlayback()
        }
    }

    func previewClick() {
        let tone = settings.clickTone

        Task {
            await audio.preview(
                tone: tone,
                midiNote: settings.baseMidiNote
            )
        }

        if settings.hapticsEnabled,
           WKApplication.shared().applicationState == .active {
            haptics.requestClick()
        }
    }

    func previewAccent() {
        let tone = settings.clickTone
        let accentTone =
            settings.accentTone

        Task {
            await audio.previewAccent(
                tone: tone,
                accentTone: accentTone,
                midiNote:
                    settings.baseMidiNote
            )
        }

        if settings.hapticsEnabled,
           WKApplication.shared().applicationState
                == .active
        {
            haptics.requestClick()
        }
    }

    func previewHaptic() {
        guard
            settings.hapticsEnabled,
            WKApplication.shared()
                .applicationState == .active
        else {
            return
        }

        haptics.requestClick()
    }

    func setStatusNotificationsEnabled(
        _ enabled: Bool
    ) {
        updateSettings { value in
            value.statusNotificationsEnabled =
                enabled
        }

        if enabled {
            requestNotificationPermission()
        } else {
            clearStatusNotifications()
        }
    }

    // MARK: - Manual rhythm recording

    func beginManualRecording() {
        stop()

        updateSettings { value in
            value.mode = .manual
            value.manualIntervals = []
            value.manualMidiNotes = []
        }

        recordingTapTimes.removeAll(
            keepingCapacity: true
        )

        manualTapCount = 0
        isRecordingManualPattern = true
    }

    func recordManualTap() {
        guard isRecordingManualPattern else {
            return
        }

        let now =
            ProcessInfo.processInfo.systemUptime

        recordingTapTimes.append(now)
        manualTapCount =
            recordingTapTimes.count

        if settings.hapticsEnabled,
           WKApplication.shared().applicationState == .active {
            haptics.requestClick()
        }
    }

    func finishManualRecording() {
        guard isRecordingManualPattern else {
            return
        }

        isRecordingManualPattern = false

        guard recordingTapTimes.count >= 2 else {
            recordingTapTimes.removeAll()
            manualTapCount = 0
            return
        }

        var intervals = zip(
            recordingTapTimes,
            recordingTapTimes.dropFirst()
        )
        .map { previous, next in
            min(
                max(
                    next - previous,
                    MetronomeSettings
                        .minimumManualInterval
                ),
                MetronomeSettings
                    .maximumManualInterval
            )
        }

        let sorted = intervals.sorted()
        let closingInterval =
            sorted[sorted.count / 2]

        intervals.append(closingInterval)

        updateSettings { value in
            value.mode = .manual
            value.manualIntervals =
                intervals
            value.manualMidiNotes =
                Array(
                    repeating: nil,
                    count: intervals.count
                )
        }

        recordingTapTimes.removeAll()
        manualTapCount = 0
    }

    func cancelManualRecording() {
        isRecordingManualPattern = false
        recordingTapTimes.removeAll()
        manualTapCount = 0
    }

    func clearManualPattern() {
        stop()

        updateSettings { value in
            value.manualIntervals = []
            value.manualMidiNotes = []
        }
    }

    // MARK: - Microphone rhythm + tuner

    func beginMicrophoneRecording() {
        guard
            !isPreparingMicrophone,
            !isRecordingMicrophonePattern,
            !isTunerActive
        else {
            return
        }

        stop()

        isPreparingMicrophone = true
        isRecordingMicrophonePattern = true
        microphoneError = nil
        microphoneEventStore.reset()
        microphoneOnsetCount = 0
        clearDetectedPitch()

        print(
            "[MichiPitch] RECORDING_BEGIN uptime=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime))"
        )

        let owner = self
        let eventStore =
            microphoneEventStore

        Task { @MainActor in
            await owner.audio.deactivate()

            // Give watchOS a tiny route/session transition window after
            // playback deactivation before asking for record priority.
            try? await Task.sleep(
                nanoseconds: 60_000_000
            )

            owner.microphone.start(
                onFrame: { frame in
                    Task { @MainActor in
                        owner.handleMicrophoneFrame(
                            frame,
                            recordingPattern: true
                        )
                    }
                },
                onEvent: { event in
                    let count =
                        eventStore.append(
                            event
                        )

                    Task { @MainActor in
                        owner.microphoneOnsetCount =
                            count
                    }
                },
                completion: { result in
                    Task { @MainActor in
                        owner.isPreparingMicrophone =
                            false

                        if case
                            .failure(let error)
                            = result
                        {
                            owner.isRecordingMicrophonePattern =
                                false
                            owner.microphoneError =
                                error.localizedDescription

                            if owner.settings.audioEnabled {
                                owner.prepareForUse()
                            }
                        }
                    }
                }
            )
        }
    }

    func finishMicrophoneRecording() {
        guard
            isRecordingMicrophonePattern
        else {
            return
        }

        isPreparingMicrophone = false
        isRecordingMicrophonePattern = false

        let owner = self

        microphone.stop {
            Task { @MainActor in
                owner.commitMicrophonePattern()

                if owner.settings.audioEnabled {
                    owner.prepareForUse()
                }
            }
        }
    }

    func cancelMicrophoneRecording() {
        guard
            isRecordingMicrophonePattern
            || isPreparingMicrophone
        else {
            return
        }

        isPreparingMicrophone = false
        isRecordingMicrophonePattern = false
        microphoneEventStore.reset()
        microphoneOnsetCount = 0
        clearDetectedPitch()

        let owner = self

        microphone.stop {
            Task { @MainActor in
                if owner.settings.audioEnabled {
                    owner.prepareForUse()
                }
            }
        }
    }

    func beginTuner() {
        guard
            !isPreparingMicrophone,
            !isRecordingMicrophonePattern,
            !isTunerActive
        else {
            return
        }

        stop()

        isPreparingMicrophone = true
        isTunerActive = true
        microphoneError = nil
        lastTunerDisplayTimestamp =
            -Double.infinity
        clearDetectedPitch()

        let owner = self

        Task { @MainActor in
            await owner.audio.deactivate()

            try? await Task.sleep(
                nanoseconds: 60_000_000
            )

            owner.microphone.start(
                onFrame: { frame in
                    Task { @MainActor in
                        owner.handleMicrophoneFrame(
                            frame,
                            recordingPattern: false
                        )
                    }
                },
                completion: { result in
                    Task { @MainActor in
                        owner.isPreparingMicrophone =
                            false

                        if case
                            .failure(let error)
                            = result
                        {
                            owner.isTunerActive =
                                false
                            owner.microphoneError =
                                error.localizedDescription

                            if owner.settings.audioEnabled {
                                owner.prepareForUse()
                            }
                        }
                    }
                }
            )
        }
    }

    func stopTuner() {
        guard
            isTunerActive
            || isPreparingMicrophone
        else {
            return
        }

        isPreparingMicrophone = false
        isTunerActive = false
        clearDetectedPitch()

        let owner = self

        microphone.stop {
            Task { @MainActor in
                if owner.settings.audioEnabled {
                    owner.prepareForUse()
                }
            }
        }
    }

    private func handleMicrophoneFrame(
        _ frame: MicrophoneFrame,
        recordingPattern: Bool
    ) {
        // Keep the level meter responsive, but intentionally slow the tuner
        // text itself so a human can read it instead of watching 16 Hz jitter.
        microphoneLevel =
            min(
                1,
                max(
                    0,
                    frame.rms * 14.0
                )
            )

        if !recordingPattern {
            let interval =
                frame.timestamp
                - lastTunerDisplayTimestamp

            guard
                interval >= 0.24
                || lastTunerDisplayTimestamp
                    == -Double.infinity
            else {
                return
            }

            lastTunerDisplayTimestamp =
                frame.timestamp
        }

        if
            frame.confidence >= 0.50,
            let frequency =
                frame.frequency,
            let midiNote =
                frame.midiNote,
            let cents =
                frame.cents
        {
            detectedFrequency =
                frequency
            detectedMidiNote =
                midiNote
            detectedCents =
                cents
        } else if frame.rms < 0.006 {
            detectedFrequency = nil
            detectedMidiNote = nil
            detectedCents = nil
        }

        // Recording events are committed by MicrophoneAnalyzer on its serial
        // analysis queue before this visual frame reaches MainActor.
    }

    private func commitMicrophonePattern() {
        let capturedEvents =
            microphoneEventStore
                .snapshotAndClear()

        print(
            "[MichiPitch] RECORDING_END uptime=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime)) events=\(capturedEvents.count)"
        )

        defer {
            microphoneOnsetCount = 0
            clearDetectedPitch()
        }

        guard
            capturedEvents.count >= 2
        else {
            microphoneError =
                "Play or sing at least two clear note attacks."
            return
        }

        var intervals = zip(
            capturedEvents,
            capturedEvents.dropFirst()
        )
        .map { previous, next in
            min(
                max(
                    next.timestamp
                    - previous.timestamp,
                    MetronomeSettings
                        .minimumManualInterval
                ),
                MetronomeSettings
                    .maximumManualInterval
            )
        }

        let sorted = intervals.sorted()
        let closingInterval =
            sorted[sorted.count / 2]

        intervals.append(
            closingInterval
        )

        let notes =
            capturedEvents.map {
                Optional($0.midiNote)
            }

        let capturedCount =
            capturedEvents.count

        updateSettings { value in
            value.mode = .manual
            value.manualIntervals =
                intervals
            value.manualMidiNotes =
                notes
        }

        print(
            "[MichiPitch] PATTERN_COMMIT captured=\(capturedCount) saved=\(settings.manualIntervals.count) notes=\(settings.manualMidiNotes.count) cap=\(MetronomeSettings.maximumManualEvents)"
        )
    }

    private func clearDetectedPitch() {
        detectedFrequency = nil
        detectedMidiNote = nil
        detectedCents = nil
        microphoneLevel = 0
    }

    private static func noteName(
        midiNote: Int
    ) -> String {
        let names = [
            "C", "C♯", "D", "D♯",
            "E", "F", "F♯", "G",
            "G♯", "A", "A♯", "B"
        ]

        let clamped =
            min(max(midiNote, 0), 127)

        let name =
            names[
                clamped % 12
            ]

        let octave =
            clamped / 12 - 1

        return "\(name)\(octave)"
    }

    // MARK: - Scene/background

    func enteredBackground() {
        postStatusNotificationIfNeeded()

        if isRunning,
           !settings.audioEnabled {
            resumeAfterForeground = true
            stop()
        }
    }

    func becameActive() {
        clearStatusNotifications()

        // watchOS 26 can emit additional active/inactive transitions while
        // views and audio routes are changing. Never reconfigure the shared
        // AVAudioSession for playback while microphone recording/tuning owns it.
        guard !microphoneOwnsAudioSession else {
            return
        }

        if settings.audioEnabled {
            prepareForUse()
        }

        if resumeAfterForeground {
            resumeAfterForeground = false
            start()
        }
    }

    // MARK: - Playback

    private func restartPlayback() {
        guard isRunning else {
            return
        }

        stop()
        start()
    }

    private func rescheduleActivePlayback() {
        guard
            isRunning,
            !isPreparing
        else {
            return
        }

        generation &+= 1

        let expectedGeneration =
            generation

        playbackTask?.cancel()
        playbackTask = nil

        let currentSettings =
            settings

        let plan = PlaybackPlan(
            mode:
                currentSettings.mode,
            bpm:
                currentSettings.bpm,
            beatsPerBar:
                currentSettings.beatsPerBar,
            manualIntervals:
                currentSettings.manualIntervals,
            manualMidiNotes:
                currentSettings.manualMidiNotes,
            baseMidiNote:
                currentSettings.baseMidiNote,
            bpmBeatAccents:
                currentSettings.bpmBeatAccents,
            bpmBeatNoteOffsets:
                currentSettings.bpmBeatNoteOffsets,
            accentDownbeat:
                currentSettings.accentDownbeat,
            audioEnabled:
                currentSettings.audioEnabled,
            hapticsEnabled:
                currentSettings.hapticsEnabled,
            clickTone:
                currentSettings.clickTone,
            accentTone:
                currentSettings.accentTone
        )

        beatIndex = 0
        lastBeatDate = nil

        Task { [weak self] in
            guard let self else {
                return
            }

            await self.audio
                .clearScheduledAudio()

            guard
                self.isRunning,
                !self.isPreparing,
                self.generation
                    == expectedGeneration
            else {
                return
            }

            let startHostTime =
                mach_absolute_time()
                + AVAudioTime.hostTime(
                    forSeconds: 0.12
                )

            self.beginPlaybackLoop(
                plan: plan,
                generation:
                    expectedGeneration,
                startHostTime:
                    startHostTime
            )
        }
    }

    private func beginPlaybackLoop(
        plan: PlaybackPlan,
        generation expectedGeneration: UInt64,
        startHostTime: UInt64
    ) {
        playbackTask?.cancel()

        let audio = self.audio
        let haptics = self.haptics

        playbackTask = Task.detached(
            priority: .userInitiated
        ) { [weak self] in
            // Core Audio is the renderer, but musical position is the clock.
            //
            // Each event's host time is derived ABSOLUTELY from startHostTime
            // and its musical event index. We never derive beat N+1 from the
            // rounded host time of beat N. That makes this suitable for very
            // long runtime-generated sequences.
            var audioEventIndex = 0
            var liveEventIndex = 0

            // Keep the Watch audio queue shallow. Two seconds is ample
            // scheduling runway without continuously feeding a large buffer
            // backlog to AVAudioPlayerNode.
            let horizonSeconds = 2.0
            let lateToleranceSeconds = 0.050

            while !Task.isCancelled {
                let nowHostTime =
                    mach_absolute_time()

                if plan.audioEnabled {
                    let horizonHostTime =
                        nowHostTime
                        &+ AVAudioTime.hostTime(
                            forSeconds:
                                horizonSeconds
                        )

                    while !Task.isCancelled {
                        let eventHostTime =
                            plan.hostTime(
                                for:
                                    audioEventIndex,
                                startHostTime:
                                    startHostTime
                            )

                        guard
                            eventHostTime
                                <= horizonHostTime
                        else {
                            break
                        }

                        // Never enqueue an audio event which is already
                        // meaningfully in the past. The next event remains
                        // anchored to the original musical timeline.
                        if eventHostTime
                            + AVAudioTime.hostTime(
                                forSeconds: 0.010
                            )
                            >= nowHostTime
                        {
                            await audio
                                .scheduleNote(
                                    accent:
                                        plan.accent(
                                            for:
                                                audioEventIndex
                                        ),
                                    tone:
                                        plan.clickTone,
                                    accentTone:
                                        plan.accentTone,
                                    midiNote:
                                        plan.playbackMidiNote(
                                            for:
                                                audioEventIndex
                                        ),
                                    duration:
                                        plan.noteDuration(
                                            for:
                                                audioEventIndex
                                        ),
                                    hostTime:
                                        eventHostTime
                                )
                        }

                        audioEventIndex += 1
                    }
                }

                let now =
                    mach_absolute_time()

                var liveHostTime =
                    plan.hostTime(
                        for: liveEventIndex,
                        startHostTime:
                            startHostTime
                    )

                if liveHostTime < now {
                    let lateness =
                        AVAudioTime.seconds(
                            forHostTime:
                                now
                                - liveHostTime
                        )

                    if
                        lateness
                            > lateToleranceSeconds
                    {
                        liveEventIndex =
                            plan.firstEventIndex(
                                atOrAfter: now,
                                startHostTime:
                                    startHostTime
                            )

                        liveHostTime =
                            plan.hostTime(
                                for:
                                    liveEventIndex,
                                startHostTime:
                                    startHostTime
                            )
                    }
                }

                let beforeBeat =
                    mach_absolute_time()

                if liveHostTime > beforeBeat {
                    let wait =
                        AVAudioTime.seconds(
                            forHostTime:
                                liveHostTime
                                - beforeBeat
                        )

                    do {
                        try await Task.sleep(
                            nanoseconds:
                                UInt64(
                                    max(
                                        0,
                                        wait
                                    )
                                    * 1_000_000_000
                                )
                        )
                    } catch {
                        break
                    }
                }

                guard
                    !Task.isCancelled
                else {
                    break
                }

                // Re-check against the absolute clock after waking.
                // If the system held this task for too long, skip the
                // old live event instead of firing it late.
                let wakeHostTime =
                    mach_absolute_time()

                if wakeHostTime > liveHostTime {
                    let wakeLateness =
                        AVAudioTime.seconds(
                            forHostTime:
                                wakeHostTime
                                - liveHostTime
                        )

                    if
                        wakeLateness
                            > lateToleranceSeconds
                    {
                        liveEventIndex =
                            plan.firstEventIndex(
                                atOrAfter:
                                    wakeHostTime,
                                startHostTime:
                                    startHostTime
                            )

                        continue
                    }
                }

                if plan.hapticsEnabled {
                    haptics.requestClick()
                }

                let currentStep =
                    plan.step(
                        for: liveEventIndex
                    )

                let playbackNote =
                    plan.playbackMidiNote(
                        for: liveEventIndex
                    )

                await self?.publishBeat(
                    step: currentStep,
                    playbackMidiNote:
                        playbackNote,
                    generation:
                        expectedGeneration
                )

                liveEventIndex += 1
            }
        }
    }

    private func publishBeat(
        step: Int,
        playbackMidiNote: Int,
        generation expectedGeneration: UInt64
    ) {
        guard
            isRunning,
            generation == expectedGeneration
        else {
            return
        }

        beatIndex = step
        currentPlaybackMidiNote =
            playbackMidiNote
        lastBeatDate = Date()
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current()
            .requestAuthorization(
                options: [.alert]
            ) { _, _ in
            }
    }

    private func postStatusNotificationIfNeeded() {
        guard
            settings.statusNotificationsEnabled,
            isRunning
        else {
            return
        }

        let content =
            UNMutableNotificationContent()

        switch settings.mode {
        case .bpm:
            content.title =
                "Metronome \(Int(settings.bpm)) BPM"

            content.body =
                settings.timeSignature.label

        case .manual:
            let steps =
                settings.manualIntervals.count

            let approximateBPM =
                manualApproximateBPM
                    .map { " • ~\($0) BPM" }
                ?? ""

            content.title = "Manual rhythm"
            content.body =
                "\(steps) beats\(approximateBPM)"
        }

        let request = UNNotificationRequest(
            identifier:
                "MichiMetronome.CurrentStatus",
            content: content,
            trigger:
                UNTimeIntervalNotificationTrigger(
                    timeInterval: 1,
                    repeats: false
                )
        )

        UNUserNotificationCenter.current()
            .add(request)
    }

    private func clearStatusNotifications() {
        let center =
            UNUserNotificationCenter.current()

        center.removePendingNotificationRequests(
            withIdentifiers: [
                "MichiMetronome.CurrentStatus"
            ]
        )

        center.removeDeliveredNotifications(
            withIdentifiers: [
                "MichiMetronome.CurrentStatus"
            ]
        )
    }

    private func updateSettings(
        _ mutation:
            (inout MetronomeSettings) -> Void
    ) {
        var next = settings

        mutation(&next)
        next.normalize()

        settings = next
        SettingsStore.save(next)
    }
}
