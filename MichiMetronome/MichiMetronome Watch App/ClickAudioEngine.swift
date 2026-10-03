import AVFoundation
import Foundation

actor ClickAudioEngine {
    private struct BufferKey: Hashable {
        let tone: ClickTone
        let accentTone: AccentTone
        let midiNote: Int
        let accent: Bool
        let frameCount: Int
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    private let sourceFormat = AVAudioFormat(
        standardFormatWithSampleRate: 44_100,
        channels: 1
    )!

    private var connected = false
    private var prepared = false
    private var preparing = false
    private var bufferCache: [BufferKey: AVAudioPCMBuffer] = [:]

    init() {
        engine.attach(player)
    }

    var isReady: Bool {
        prepared && engine.isRunning
    }

    func prepareSession(tone: ClickTone) async -> Bool {
        _ = tone

        if prepared {
            if !engine.isRunning {
                do {
                    try engine.start()
                } catch {
                    prepared = false
                    return false
                }
            }

            if !player.isPlaying {
                player.play()
            }

            return true
        }

        if preparing {
            while preparing {
                try? await Task.sleep(
                    nanoseconds: 10_000_000
                )
            }

            return prepared
        }

        preparing = true
        defer { preparing = false }

        let session = AVAudioSession.sharedInstance()

        do {
            try session.setCategory(
                .playback,
                mode: .default,
                options: [.mixWithOthers]
            )

            _ = try await session.activate()

            if !connected {
                engine.connect(
                    player,
                    to: engine.mainMixerNode,
                    format: sourceFormat
                )
                connected = true
            }

            engine.prepare()
            try engine.start()
            player.play()

            prepared = true
            return true
        } catch {
            prepared = false
            return false
        }
    }

    func setTone(_ tone: ClickTone) {
        _ = tone
    }

    func scheduleNote(
        accent: Bool,
        tone: ClickTone,
        accentTone: AccentTone,
        midiNote: Int,
        duration: TimeInterval,
        hostTime: UInt64
    ) {
        guard prepared else {
            return
        }

        // watchOS may stop the render graph after a route / power transition.
        // Recover in-place instead of silently dropping every future beat.
        if !engine.isRunning {
            do {
                engine.prepare()
                try engine.start()
            } catch {
                prepared = false
                return
            }
        }

        let note = min(max(midiNote, 0), 127)
        let noteDuration = min(max(duration, 0.030), 0.45)
        let frameCount = max(
            1,
            Int(sourceFormat.sampleRate * noteDuration)
        )

        let key = BufferKey(
            tone: tone,
            accentTone: accentTone,
            midiNote: note,
            accent: accent,
            frameCount: frameCount
        )

        let buffer: AVAudioPCMBuffer

        if let cached = bufferCache[key] {
            buffer = cached
        } else {
            guard
                let generated = Self.makeNoteBuffer(
                    format: sourceFormat,
                    tone: tone,
                    accentTone: accentTone,
                    midiNote: note,
                    accent: accent,
                    frameCount: frameCount
                )
            else {
                return
            }

            if bufferCache.count >= 192 {
                bufferCache.removeAll(
                    keepingCapacity: true
                )
            }

            bufferCache[key] = generated
            buffer = generated
        }

        if !player.isPlaying {
            player.play()
        }

        player.scheduleBuffer(
            buffer,
            at: AVAudioTime(hostTime: hostTime),
            options: [],
            completionHandler: nil
        )
    }

    func preview(
        tone: ClickTone,
        midiNote: Int
    ) async {
        guard await prepareSession(tone: tone) else {
            return
        }

        let note = min(max(midiNote, 0), 127)
        let frameCount = Int(
            sourceFormat.sampleRate * 0.18
        )

        let key = BufferKey(
            tone: tone,
            accentTone: .harmonic,
            midiNote: note,
            accent: false,
            frameCount: frameCount
        )

        let buffer: AVAudioPCMBuffer

        if let cached = bufferCache[key] {
            buffer = cached
        } else {
            guard
                let generated = Self.makeNoteBuffer(
                    format: sourceFormat,
                    tone: tone,
                    accentTone: .harmonic,
                    midiNote: note,
                    accent: false,
                    frameCount: frameCount
                )
            else {
                return
            }

            bufferCache[key] = generated
            buffer = generated
        }

        enqueuePreviewBuffer(buffer)
    }

    func previewAccent(
        tone: ClickTone,
        accentTone: AccentTone,
        midiNote: Int
    ) async {
        guard await prepareSession(tone: tone) else {
            return
        }

        let note = min(max(midiNote, 0), 127)
        let frameCount = Int(
            sourceFormat.sampleRate * 0.18
        )

        let key = BufferKey(
            tone: tone,
            accentTone: accentTone,
            midiNote: note,
            accent: true,
            frameCount: frameCount
        )

        let buffer: AVAudioPCMBuffer

        if let cached = bufferCache[key] {
            buffer = cached
        } else {
            guard
                let generated = Self.makeNoteBuffer(
                    format: sourceFormat,
                    tone: tone,
                    accentTone: accentTone,
                    midiNote: note,
                    accent: true,
                    frameCount: frameCount
                )
            else {
                return
            }

            bufferCache[key] = generated
            buffer = generated
        }

        enqueuePreviewBuffer(buffer)
    }

    private func enqueuePreviewBuffer(
        _ buffer: AVAudioPCMBuffer
    ) {
        player.scheduleBuffer(
            buffer,
            at: nil,
            options: [],
            completionHandler: nil
        )
    }

    func clearScheduledAudio() {
        player.stop()

        if prepared, engine.isRunning {
            player.play()
        }
    }

    func suspend() {
        player.stop()

        if engine.isRunning {
            engine.pause()
        }
    }

    func deactivate() async {
        player.stop()
        engine.stop()
        engine.reset()
        prepared = false

        let session =
            AVAudioSession.sharedInstance()

        do {
            try session.setActive(
                false,
                options: [
                    .notifyOthersOnDeactivation
                ]
            )
        } catch {
            // The session can already be inactive, or watchOS can still be
            // finishing a route change. The next activation path reports a
            // real failure if the route is unavailable.
        }

        // Xcode 26.6 doesn't expose AVAudioSession.deactivate(...).
        // Give watchOS a short route handoff window before Mic activation.
        try? await Task.sleep(
            nanoseconds: 60_000_000
        )
    }

    private static func makeNoteBuffer(
        format: AVAudioFormat,
        tone: ClickTone,
        accentTone: AccentTone,
        midiNote: Int,
        accent: Bool,
        frameCount: Int
    ) -> AVAudioPCMBuffer? {
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
            ),
            let channel = buffer.floatChannelData?[0]
        else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)

        let effectiveMidiNote: Int

        if accent, accentTone == .octave {
            effectiveMidiNote = min(midiNote + 12, 127)
        } else {
            effectiveMidiNote = midiNote
        }

        let frequency =
            440.0
            * pow(
                2.0,
                Double(effectiveMidiNote - 69) / 12.0
            )

        let amplitude = accent ? 0.92 : 0.63
        let attackSeconds = accent ? 0.0025 : 0.004

        for frame in 0..<frameCount {
            let time =
                Double(frame) / format.sampleRate

            let normalized =
                Double(frame)
                / Double(max(frameCount - 1, 1))

            let attack =
                min(1.0, time / attackSeconds)

            let releasePower: Double

            if accent, accentTone == .bell {
                releasePower = 1.25
            } else {
                releasePower =
                    tone == .beep ? 1.5 : 2.8
            }

            let release =
                pow(
                    max(0, 1.0 - normalized),
                    releasePower
                )

            let envelope = attack * release

            let phase =
                2.0
                * Double.pi
                * frequency
                * time

            let harmonicSample: Double

            if accent {
                // Accent timbre is deliberately independent from the regular
                // click tone, so switching Wood/Sharp/Low/Beep can never make
                // the downbeat disappear.
                switch accentTone {
                case .harmonic:
                    harmonicSample =
                        sin(phase) * 0.52
                        + sin(phase * 2.0) * 0.26
                        + sin(phase * 3.0) * 0.14
                        + sin(phase * 5.0) * 0.08

                case .octave:
                    harmonicSample =
                        sin(phase) * 0.70
                        + sin(phase * 2.0) * 0.20
                        + sin(phase * 4.0) * 0.10

                case .bell:
                    harmonicSample =
                        sin(phase) * 0.54
                        + sin(phase * 2.01) * 0.24
                        + sin(phase * 3.97) * 0.14
                        + sin(phase * 6.11) * 0.08
                }
            } else {
                switch tone {
                case .wood:
                    harmonicSample =
                        sin(phase) * 0.74
                        + sin(phase * 2.01) * 0.18
                        + sin(phase * 3.97) * 0.08

                case .sharp:
                    harmonicSample =
                        sin(phase) * 0.55
                        + sin(phase * 2.0) * 0.28
                        + sin(phase * 4.0) * 0.17

                case .low:
                    harmonicSample =
                        sin(phase) * 0.84
                        + sin(phase * 2.0) * 0.16

                case .beep:
                    harmonicSample = sin(phase)
                }
            }

            let transient: Double

            if frame < 10 {
                let transientLevel =
                    accent ? 0.20 : 0.12

                transient =
                    frame.isMultiple(of: 2)
                    ? transientLevel
                    : -transientLevel
            } else {
                transient = 0
            }

            let sample =
                (
                    harmonicSample * envelope
                    + transient * release
                )
                * amplitude

            channel[frame] =
                Float(max(-1, min(1, sample)))
        }

        return buffer
    }
}
