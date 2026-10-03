import Foundation

enum MetronomeMode: String, Codable, CaseIterable, Sendable {
    case bpm
    case manual

    var title: String {
        switch self {
        case .bpm: "BPM"
        case .manual: "Manual"
        }
    }
}

enum ClickTone: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case wood
    case sharp
    case low
    case beep

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wood: "Wood"
        case .sharp: "Sharp"
        case .low: "Low"
        case .beep: "Beep"
        }
    }

    var subtitle: String {
        switch self {
        case .wood: "dry metronome click"
        case .sharp: "short bright tick"
        case .low: "lower wooden tick"
        case .beep: "clean electronic tick"
        }
    }
}

enum AccentTone: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case harmonic
    case octave
    case bell

    var id: String { rawValue }

    var title: String {
        switch self {
        case .harmonic: "Harmonic"
        case .octave: "Octave"
        case .bell: "Bell"
        }
    }

    var subtitle: String {
        switch self {
        case .harmonic: "bright harmonic downbeat"
        case .octave: "one octave above the beat"
        case .bell: "short bell-like accent"
        }
    }
}

enum TimeSignature: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case twoTwo
    case twoFour
    case threeFour
    case fourFour
    case fiveFour
    case sixFour
    case sevenFour
    case threeEight
    case fiveEight
    case sixEight
    case sevenEight
    case nineEight
    case twelveEight

    var id: String { rawValue }

    var numerator: Int {
        switch self {
        case .twoTwo, .twoFour:
            2
        case .threeFour, .threeEight:
            3
        case .fourFour:
            4
        case .fiveFour, .fiveEight:
            5
        case .sixFour, .sixEight:
            6
        case .sevenFour, .sevenEight:
            7
        case .nineEight:
            9
        case .twelveEight:
            12
        }
    }

    var denominator: Int {
        switch self {
        case .twoTwo:
            2

        case .twoFour,
             .threeFour,
             .fourFour,
             .fiveFour,
             .sixFour,
             .sevenFour:
            4

        case .threeEight,
             .fiveEight,
             .sixEight,
             .sevenEight,
             .nineEight,
             .twelveEight:
            8
        }
    }

    var label: String {
        "\(numerator)/\(denominator)"
    }

    var family: String {
        switch self {
        case .twoTwo:
            "Cut time"
        case .twoFour, .threeFour, .fourFour:
            "Common"
        case .fiveFour, .sixFour, .sevenFour:
            "Asymmetric / extended"
        case .threeEight, .fiveEight, .sixEight, .sevenEight, .nineEight, .twelveEight:
            "Eighth-note meters"
        }
    }

    static func migrated(beatsPerBar: Int) -> TimeSignature {
        switch beatsPerBar {
        case 2: .twoFour
        case 3: .threeFour
        case 5: .fiveFour
        case 6: .sixFour
        case 7: .sevenFour
        case 9: .nineEight
        case 12: .twelveEight
        default: .fourFour
        }
    }
}

enum RhythmPreset: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case plain
    case rock
    case hipHop
    case classical
    case waltz
    case sixEight
    case custom

    var id: String { rawValue }

    static var selectableCases: [RhythmPreset] {
        allCases.filter { $0 != .custom }
    }

    var title: String {
        switch self {
        case .plain: "Plain"
        case .rock: "Rock"
        case .hipHop: "Hip-Hop"
        case .classical: "Classical"
        case .waltz: "Waltz"
        case .sixEight: "6/8 Pulse"
        case .custom: "Custom"
        }
    }

    var subtitle: String {
        switch self {
        case .plain:
            "classic downbeat + steady base"
        case .rock:
            "strong 1 & 3, alternating fifth"
        case .hipHop:
            "heavy downbeat with a wider 4th beat"
        case .classical:
            "simple tonic–fifth–octave contour"
        case .waltz:
            "3/4 strong first beat"
        case .sixEight:
            "two grouped pulses in 6/8"
        case .custom:
            "edited beat accents / notes"
        }
    }

    var timeSignature: TimeSignature {
        switch self {
        case .waltz:
            .threeFour
        case .sixEight:
            .sixEight
        default:
            .fourFour
        }
    }

    var accentPattern: [Bool] {
        switch self {
        case .plain:
            [true, false, false, false]
        case .rock:
            [true, false, true, false]
        case .hipHop:
            [true, false, false, true]
        case .classical:
            [true, false, false, false]
        case .waltz:
            [true, false, false]
        case .sixEight:
            [true, false, false, true, false, false]
        case .custom:
            []
        }
    }

    /// Optional semitone offsets from the configured base note.
    /// nil = use the base note unchanged.
    var noteOffsets: [Int?] {
        switch self {
        case .plain:
            [nil, nil, nil, nil]
        case .rock:
            [nil, 7, nil, 7]
        case .hipHop:
            [nil, 7, nil, 10]
        case .classical:
            [nil, 7, 12, 7]
        case .waltz:
            [nil, 7, 7]
        case .sixEight:
            [nil, nil, nil, 7, nil, nil]
        case .custom:
            []
        }
    }
}

struct MetronomeSettings: Codable, Equatable, Sendable {
    nonisolated static let minimumBPM = 30.0
    nonisolated static let maximumBPM = 300.0
    nonisolated static let minimumManualInterval = 0.06
    nonisolated static let maximumManualInterval = 4.0

    // Watch-speaker-friendly range. This avoids base notes that technically
    // exist as MIDI but are not useful / clearly audible on the Watch.
    nonisolated static let minimumBaseMidiNote = 48   // C3
    nonisolated static let maximumBaseMidiNote = 84   // C6

    // Safety ceiling only, not a musical limitation.
    nonisolated static let maximumManualEvents = 8_192

    var bpm: Double = 120
    var timeSignature: TimeSignature = .fourFour
    var hapticsEnabled: Bool = true
    var audioEnabled: Bool = true
    var accentDownbeat: Bool = true
    var clickTone: ClickTone = .wood
    var accentTone: AccentTone = .harmonic
    var baseMidiNote: Int = 69
    var rhythmPreset: RhythmPreset = .plain

    /// One accent flag per BPM beat. Beat 0 mirrors accentDownbeat.
    var bpmBeatAccents: [Bool] = []

    /// Optional semitone offset from baseMidiNote per BPM beat.
    var bpmBeatNoteOffsets: [Int?] = []

    var mode: MetronomeMode = .bpm
    var manualIntervals: [Double] = []

    // One optional MIDI note number per manual beat/event.
    // nil means rhythm-only (for example a finger-tapped pattern).
    var manualMidiNotes: [Int?] = []

    var statusNotificationsEnabled: Bool = false

    var beatsPerBar: Int {
        timeSignature.numerator
    }

    mutating func normalize() {
        bpm = min(
            max(bpm.rounded(), Self.minimumBPM),
            Self.maximumBPM
        )

        baseMidiNote = min(
            max(
                baseMidiNote,
                Self.minimumBaseMidiNote
            ),
            Self.maximumBaseMidiNote
        )

        let beatCount = max(beatsPerBar, 1)

        bpmBeatAccents = Array(
            bpmBeatAccents.prefix(beatCount)
        )

        if bpmBeatAccents.count < beatCount {
            bpmBeatAccents.append(
                contentsOf: Array(
                    repeating: false,
                    count: beatCount - bpmBeatAccents.count
                )
            )
        }

        if bpmBeatAccents.isEmpty {
            bpmBeatAccents = Array(
                repeating: false,
                count: beatCount
            )
        }

        bpmBeatAccents[0] = accentDownbeat

        bpmBeatNoteOffsets = Array(
            bpmBeatNoteOffsets.prefix(beatCount)
        )

        if bpmBeatNoteOffsets.count < beatCount {
            bpmBeatNoteOffsets.append(
                contentsOf: Array(
                    repeating: nil,
                    count: beatCount - bpmBeatNoteOffsets.count
                )
            )
        }

        bpmBeatNoteOffsets = bpmBeatNoteOffsets.map { offset in
            guard let offset else {
                return nil
            }

            let requested = baseMidiNote + offset
            let clamped = min(
                max(
                    requested,
                    Self.minimumBaseMidiNote
                ),
                Self.maximumBaseMidiNote
            )

            return clamped - baseMidiNote
        }

        manualIntervals = Array(
            manualIntervals
                .prefix(
                    Self.maximumManualEvents
                )
                .map {
                    min(
                        max(
                            $0,
                            Self.minimumManualInterval
                        ),
                        Self.maximumManualInterval
                    )
                }
        )

        manualMidiNotes = Array(
            manualMidiNotes
                .prefix(manualIntervals.count)
                .map { note in
                    guard let note else {
                        return nil
                    }

                    return min(max(note, 0), 127)
                }
        )

        if manualMidiNotes.count < manualIntervals.count {
            manualMidiNotes.append(
                contentsOf: Array(
                    repeating: nil,
                    count:
                        manualIntervals.count
                        - manualMidiNotes.count
                )
            )
        }
    }
}

enum SettingsStore {
    private static let key = "MichiMetronome.Settings.v7"
    private static let legacyV6Key = "MichiMetronome.Settings.v6"
    private static let legacyV5Key = "MichiMetronome.Settings.v5"
    private static let legacyV4Key = "MichiMetronome.Settings.v4"
    private static let legacyV3Key = "MichiMetronome.Settings.v3"

    private struct V6Settings: Codable {
        var bpm: Double = 120
        var timeSignature: TimeSignature = .fourFour
        var hapticsEnabled: Bool = true
        var audioEnabled: Bool = true
        var accentDownbeat: Bool = true
        var clickTone: ClickTone = .wood
        var baseMidiNote: Int = 69
        var mode: MetronomeMode = .bpm
        var manualIntervals: [Double] = []
        var manualMidiNotes: [Int?] = []
        var statusNotificationsEnabled: Bool = false
    }

    private struct V5Settings: Codable {
        var bpm: Double = 120
        var timeSignature: TimeSignature = .fourFour
        var hapticsEnabled: Bool = true
        var audioEnabled: Bool = true
        var accentDownbeat: Bool = true
        var clickTone: ClickTone = .wood
        var mode: MetronomeMode = .bpm
        var manualIntervals: [Double] = []
        var manualMidiNotes: [Int?] = []
        var statusNotificationsEnabled: Bool = false
    }

    private struct V4Settings: Codable {
        var bpm: Double = 120
        var timeSignature: TimeSignature = .fourFour
        var hapticsEnabled: Bool = true
        var audioEnabled: Bool = true
        var accentDownbeat: Bool = true
        var clickTone: ClickTone = .wood
        var mode: MetronomeMode = .bpm
        var manualIntervals: [Double] = []
        var statusNotificationsEnabled: Bool = false
    }

    private struct V3Settings: Codable {
        var bpm: Double = 120
        var beatsPerBar: Int = 4
        var hapticsEnabled: Bool = true
        var audioEnabled: Bool = true
        var accentDownbeat: Bool = true
        var clickTone: ClickTone = .wood
        var mode: MetronomeMode = .bpm
        var manualIntervals: [Double] = []
        var statusNotificationsEnabled: Bool = false
    }

    static func load() -> MetronomeSettings {
        if
            let data = UserDefaults.standard.data(
                forKey: key
            ),
            var settings = try? JSONDecoder()
                .decode(
                    MetronomeSettings.self,
                    from: data
                )
        {
            settings.normalize()
            return settings
        }

        if
            let data = UserDefaults.standard.data(
                forKey: legacyV6Key
            ),
            let old = try? JSONDecoder().decode(
                V6Settings.self,
                from: data
            )
        {
            var migrated = MetronomeSettings(
                bpm: old.bpm,
                timeSignature: old.timeSignature,
                hapticsEnabled: old.hapticsEnabled,
                audioEnabled: old.audioEnabled,
                accentDownbeat: old.accentDownbeat,
                clickTone: old.clickTone,
                accentTone: .harmonic,
                baseMidiNote: old.baseMidiNote,
                rhythmPreset: .plain,
                bpmBeatAccents: [],
                bpmBeatNoteOffsets: [],
                mode: old.mode,
                manualIntervals: old.manualIntervals,
                manualMidiNotes: old.manualMidiNotes,
                statusNotificationsEnabled:
                    old.statusNotificationsEnabled
            )

            migrated.normalize()
            save(migrated)
            return migrated
        }

        if
            let data = UserDefaults.standard.data(
                forKey: legacyV5Key
            ),
            let old = try? JSONDecoder().decode(
                V5Settings.self,
                from: data
            )
        {
            var migrated = MetronomeSettings(
                bpm: old.bpm,
                timeSignature: old.timeSignature,
                hapticsEnabled: old.hapticsEnabled,
                audioEnabled: old.audioEnabled,
                accentDownbeat: old.accentDownbeat,
                clickTone: old.clickTone,
                accentTone: .harmonic,
                baseMidiNote: 69,
                rhythmPreset: .plain,
                bpmBeatAccents: [],
                bpmBeatNoteOffsets: [],
                mode: old.mode,
                manualIntervals: old.manualIntervals,
                manualMidiNotes: old.manualMidiNotes,
                statusNotificationsEnabled:
                    old.statusNotificationsEnabled
            )

            migrated.normalize()
            save(migrated)
            return migrated
        }

        if
            let data = UserDefaults.standard.data(
                forKey: legacyV4Key
            ),
            let old = try? JSONDecoder().decode(
                V4Settings.self,
                from: data
            )
        {
            var migrated = MetronomeSettings(
                bpm: old.bpm,
                timeSignature: old.timeSignature,
                hapticsEnabled: old.hapticsEnabled,
                audioEnabled: old.audioEnabled,
                accentDownbeat: old.accentDownbeat,
                clickTone: old.clickTone,
                accentTone: .harmonic,
                baseMidiNote: 69,
                rhythmPreset: .plain,
                bpmBeatAccents: [],
                bpmBeatNoteOffsets: [],
                mode: old.mode,
                manualIntervals: old.manualIntervals,
                manualMidiNotes: Array(
                    repeating: nil,
                    count: old.manualIntervals.count
                ),
                statusNotificationsEnabled:
                    old.statusNotificationsEnabled
            )

            migrated.normalize()
            save(migrated)
            return migrated
        }

        if
            let data = UserDefaults.standard.data(
                forKey: legacyV3Key
            ),
            let old = try? JSONDecoder().decode(
                V3Settings.self,
                from: data
            )
        {
            var migrated = MetronomeSettings(
                bpm: old.bpm,
                timeSignature:
                    .migrated(
                        beatsPerBar:
                            old.beatsPerBar
                    ),
                hapticsEnabled:
                    old.hapticsEnabled,
                audioEnabled:
                    old.audioEnabled,
                accentDownbeat:
                    old.accentDownbeat,
                clickTone:
                    old.clickTone,
                accentTone:
                    .harmonic,
                baseMidiNote:
                    69,
                rhythmPreset:
                    .plain,
                bpmBeatAccents:
                    [],
                bpmBeatNoteOffsets:
                    [],
                mode:
                    old.mode,
                manualIntervals:
                    old.manualIntervals,
                manualMidiNotes: Array(
                    repeating: nil,
                    count:
                        old.manualIntervals.count
                ),
                statusNotificationsEnabled:
                    old.statusNotificationsEnabled
            )

            migrated.normalize()
            save(migrated)
            return migrated
        }

        var fresh = MetronomeSettings()
        fresh.normalize()
        return fresh
    }

    static func save(
        _ settings: MetronomeSettings
    ) {
        var normalized = settings
        normalized.normalize()

        guard
            let data = try? JSONEncoder()
                .encode(normalized)
        else {
            return
        }

        UserDefaults.standard.set(
            data,
            forKey: key
        )
    }
}
