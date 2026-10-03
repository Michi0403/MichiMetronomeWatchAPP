import SwiftUI

private struct PlayTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(
            to: CGPoint(
                x: rect.minX,
                y: rect.minY
            )
        )
        path.addLine(
            to: CGPoint(
                x: rect.maxX,
                y: rect.midY
            )
        )
        path.addLine(
            to: CGPoint(
                x: rect.minX,
                y: rect.maxY
            )
        )
        path.closeSubpath()
        return path
    }
}

struct ContentView: View {
    @EnvironmentObject private var engine: MetronomeEngine
    @State private var showSettings = false
    @State private var showTempoEditor = false
    @State private var showMeterPicker = false

    var body: some View {
        ScrollView {
            VStack(spacing: 7) {
                header
                modePicker

                if engine.settings.mode == .bpm {
                    BPMPanel(
                        showTempoEditor:
                            $showTempoEditor
                    )
                } else {
                    ManualPanel()
                }

                playbackButton
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
        }
        .task {
            engine.prepareForUse()
        }
        .sheet(
            isPresented: $showSettings
        ) {
            SettingsView()
                .environmentObject(engine)
        }
        .sheet(
            isPresented: $showTempoEditor
        ) {
            TempoCrownView()
                .environmentObject(engine)
        }
        .sheet(
            isPresented: $showMeterPicker
        ) {
            MeterPickerView()
                .environmentObject(engine)
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(
                    engine.isRunning
                    ? Color.green
                    : Color.secondary.opacity(0.5)
                )
                .frame(width: 6, height: 6)

            Text(
                engine.isPreparing
                ? "PREPARING"
                : (engine.isRunning ? "RUNNING" : "READY")
            )
            .font(
                .system(
                    size: 10,
                    weight: .bold
                )
            )
            .foregroundStyle(
                engine.isRunning
                ? .green
                : .secondary
            )

            Spacer()

            if engine.settings.mode == .bpm {
                Button {
                    showMeterPicker = true
                } label: {
                    HStack(spacing: 3) {
                        Text(
                            engine.settings
                                .timeSignature.label
                        )
                        .font(
                            .system(
                                size: 12,
                                weight: .semibold
                            )
                            .monospacedDigit()
                        )

                        Image(
                            systemName:
                                "chevron.down"
                        )
                        .font(
                            .system(
                                size: 8,
                                weight: .bold
                            )
                        )
                    }
                    .frame(
                        minWidth: 58,
                        minHeight: 44
                    )
                    .contentShape(
                        .interaction,
                        RoundedRectangle(
                            cornerRadius: 12
                        )
                    )
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(
                        cornerRadius: 12
                    )
                    .fill(
                        Color.white
                            .opacity(0.08)
                    )
                )
                .accessibilityLabel(
                    "Time signature, \(engine.settings.timeSignature.label)"
                )
                .accessibilityHint(
                    "Opens the meter selector"
                )
            }

            Button {
                showSettings = true
            } label: {
                Image(
                    systemName: "gearshape.fill"
                )
                .font(.system(size: 15))
                .frame(
                    width: 44,
                    height: 44
                )
                .contentShape(
                    .interaction,
                    Rectangle()
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
    }

    private var modePicker: some View {
        HStack(spacing: 5) {
            modeButton(.bpm)
            modeButton(.manual)
        }
    }

    private func modeButton(
        _ mode: MetronomeMode
    ) -> some View {
        Button {
            engine.selectMode(mode)
        } label: {
            Text(mode.title)
                .font(
                    .system(
                        size: 12,
                        weight: .semibold
                    )
                )
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(
            engine.settings.mode == mode
            ? .green
            : .gray
        )
        .frame(
            maxWidth: .infinity,
            minHeight: 42
        )
        .contentShape(
            .interaction,
            RoundedRectangle(
                cornerRadius: 12
            )
        )
    }

    private var playbackButton: some View {
        Button {
            engine.toggle()
        } label: {
            HStack(spacing: 8) {
                if engine.isPreparing {
                    ProgressView()
                        .controlSize(.small)
                } else if engine.isRunning {
                    RoundedRectangle(
                        cornerRadius: 2
                    )
                    .frame(
                        width: 15,
                        height: 15
                    )
                } else {
                    PlayTriangle()
                        .frame(
                            width: 16,
                            height: 18
                        )
                }

                Text(
                    engine.isRunning
                    ? "STOP"
                    : "START"
                )
            }
            .font(
                .system(
                    size: 18,
                    weight: .heavy
                )
            )
            .frame(
                maxWidth: .infinity,
                minHeight: 50,
                maxHeight: 50
            )
            .contentShape(
                RoundedRectangle(
                    cornerRadius: 16
                )
            )
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(
                cornerRadius: 16
            )
            .fill(
                engine.isRunning
                ? Color.red
                : Color.green
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: 16
            )
            .stroke(
                Color.white.opacity(0.22),
                lineWidth: 1.5
            )
        }
        .foregroundStyle(
            engine.isRunning
            ? Color.white
            : Color.black
        )
        .opacity(
            engine.isPreparing
            || (
                !engine.isRunning
                && !engine.canStart
            )
            ? 0.45
            : 1
        )
        .disabled(
            engine.isPreparing
            || (
                !engine.isRunning
                && !engine.canStart
            )
        )
        .accessibilityLabel(
            engine.isRunning
            ? "Stop metronome"
            : "Start metronome"
        )
    }

}

private struct BPMPanel: View {
    @EnvironmentObject private var engine:
        MetronomeEngine

    @Binding var showTempoEditor: Bool
    @State private var showRhythmPresets = false

    var body: some View {
        VStack(spacing: 6) {
            Button {
                showTempoEditor = true
            } label: {
                VStack(spacing: -1) {
                    Text(
                        "\(Int(engine.settings.bpm))"
                    )
                    .font(
                        .system(
                            size: 34,
                            weight: .bold,
                            design: .rounded
                        )
                    )
                    .monospacedDigit()

                    Text(
                        "BPM • \(engine.baseNoteName) • tap for crown"
                    )
                    .font(
                        .system(
                            size: 9,
                            weight: .semibold
                        )
                    )
                    .foregroundStyle(.green)
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: 56
                )
                .padding(.vertical, 4)
                .contentShape(
                    .interaction,
                    RoundedRectangle(
                        cornerRadius: 14
                    )
                )
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(
                    cornerRadius: 14
                )
                .fill(
                    Color.white.opacity(0.06)
                )
            )

            BPMBeatStrip()

            Button {
                showRhythmPresets = true
            } label: {
                HStack(spacing: 4) {
                    Image(
                        systemName:
                            "music.quarternote.3"
                    )
                    Text("Rhythm")
                    Spacer()
                    Text(
                        engine.settings
                            .rhythmPreset.title
                    )
                    .foregroundStyle(
                        .secondary
                    )
                }
                .font(
                    .system(
                        size: 11,
                        weight: .semibold
                    )
                )
                .frame(
                    maxWidth: .infinity,
                    minHeight: 34
                )
            }
            .buttonStyle(.bordered)

            TempoStepGrid()
        }
        .sheet(
            isPresented:
                $showRhythmPresets
        ) {
            RhythmPresetView()
                .environmentObject(engine)
        }
    }
}



private struct TempoStepGrid: View {
    private let columns = [
        GridItem(
            .flexible(),
            spacing: 6
        ),
        GridItem(
            .flexible(),
            spacing: 6
        )
    ]

    var body: some View {
        LazyVGrid(
            columns: columns,
            spacing: 6
        ) {
            // Negative is always left, positive always right.
            // Matching step sizes stay on the same row.
            TempoStepButton(
                title: "-5",
                delta: -5
            )
            TempoStepButton(
                title: "+5",
                delta: 5
            )
            TempoStepButton(
                title: "-1",
                delta: -1
            )
            TempoStepButton(
                title: "+1",
                delta: 1
            )
        }
    }
}

private struct TempoStepButton: View {
    @EnvironmentObject private var engine:
        MetronomeEngine

    let title: String
    let delta: Int

    var body: some View {
        Button {
            engine.nudgeBPM(delta)
        } label: {
            Text(title)
                .font(
                    .system(
                        size: 15,
                        weight: .bold
                    )
                    .monospacedDigit()
                )
                .frame(
                    maxWidth: .infinity,
                    minHeight: 44
                )
                .contentShape(
                    .interaction,
                    RoundedRectangle(
                        cornerRadius: 12
                    )
                )
        }
        .buttonStyle(.bordered)
    }
}

private struct TempoCrownView: View {
    @EnvironmentObject private var engine:
        MetronomeEngine

    @Environment(\.dismiss)
    private var dismiss

    @State private var draftBPM = 120.0
    @FocusState private var crownFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 9) {
                Text("Tempo")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(spacing: -2) {
                    Text(
                        "\(Int(draftBPM.rounded()))"
                    )
                    .font(
                        .system(
                            size: 48,
                            weight: .bold,
                            design: .rounded
                        )
                    )
                    .monospacedDigit()

                    Text("BPM • turn crown")
                        .font(
                            .caption2
                            .weight(.semibold)
                        )
                        .foregroundStyle(.green)
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: 70
                )
                .focusable()
                .focused($crownFocused)
                .digitalCrownRotation(
                    $draftBPM,
                    from:
                        MetronomeSettings.minimumBPM,
                    through:
                        MetronomeSettings.maximumBPM,
                    by: 1,
                    sensitivity: .medium,
                    isContinuous: false,
                    isHapticFeedbackEnabled: false
                )

                HStack(spacing: 6) {
                    draftStep("-5", -5)
                    draftStep("+5", 5)
                }

                HStack(spacing: 6) {
                    draftStep("-1", -1)
                    draftStep("+1", 1)
                }

                HStack(spacing: 6) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 44
                    )

                    Button("Save") {
                        engine.setBPM(
                            draftBPM
                        )
                        dismiss()
                    }
                    .buttonStyle(
                        .borderedProminent
                    )
                    .tint(.green)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 44
                    )
                }

                Text(
                    "Closing with × discards changes."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
        }
        .task {
            draftBPM =
                engine.settings.bpm

            await Task.yield()
            crownFocused = true
        }
        .onDisappear {
            crownFocused = false
        }
    }

    @ViewBuilder
    private func draftStep(
        _ title: String,
        _ delta: Int
    ) -> some View {
        Button(title) {
            draftBPM =
                min(
                    max(
                        draftBPM
                            + Double(delta),
                        MetronomeSettings
                            .minimumBPM
                    ),
                    MetronomeSettings
                        .maximumBPM
                )
        }
        .font(
            .system(
                size: 15,
                weight: .bold
            )
            .monospacedDigit()
        )
        .buttonStyle(.bordered)
        .frame(
            maxWidth: .infinity,
            minHeight: 44
        )
    }
}


private struct BPMBeatStrip: View {
    @EnvironmentObject private var engine:
        MetronomeEngine

    @State private var showBeatEditor = false
    @State private var editingBeat = 0

    var body: some View {
        ScrollView(
            .horizontal,
            showsIndicators: false
        ) {
            HStack(spacing: 4) {
                ForEach(
                    0..<engine.settings
                        .beatsPerBar,
                    id: \.self
                ) { beat in
                    beatCell(beat)
                        .onLongPressGesture(
                            minimumDuration: 0.42
                        ) {
                            editingBeat = beat
                            showBeatEditor = true
                        }
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: 38
        )
        .sheet(
            isPresented:
                $showBeatEditor
        ) {
            BPMBeatEditorView(
                beatIndex:
                    editingBeat
            )
            .environmentObject(engine)
        }
    }

    private func beatCell(
        _ beat: Int
    ) -> some View {
        let active =
            engine.isRunning
            && beat == engine.beatIndex

        let accented =
            engine.isBPMBeatAccented(
                beat
            )

        return VStack(spacing: 1) {
            Circle()
                .fill(
                    active
                    ? Color.green
                    : (
                        accented
                        ? Color.orange
                        : Color.secondary
                            .opacity(0.35)
                    )
                )
                .frame(
                    width: active ? 9 : 7,
                    height: active ? 9 : 7
                )

            Text(
                engine.bpmBeatNoteName(
                    at: beat
                )
            )
            .font(
                .system(
                    size: 8,
                    weight:
                        accented
                        ? .bold
                        : .medium,
                    design: .rounded
                )
                .monospaced()
            )
            .foregroundStyle(
                accented
                ? .orange
                : .secondary
            )
            .lineLimit(1)
        }
        .frame(
            width: 34
        )
        .frame(
            minHeight: 32
        )
        .background(
            RoundedRectangle(
                cornerRadius: 8
            )
            .fill(
                active
                ? Color.green.opacity(0.10)
                : Color.white.opacity(0.035)
            )
        )
        .contentShape(
            RoundedRectangle(
                cornerRadius: 8
            )
        )
        .accessibilityLabel(
            "Beat \(beat + 1), \(engine.bpmBeatNoteName(at: beat))\(accented ? ", accented" : "")"
        )
        .accessibilityHint(
            "Long press to edit"
        )
    }
}

private struct BPMBeatEditorView: View {
    @EnvironmentObject private var engine:
        MetronomeEngine

    @Environment(\.dismiss)
    private var dismiss

    let beatIndex: Int

    @State private var draftAccent = false
    @State private var draftNote = 69.0
    @State private var useBaseNote = true
    @FocusState private var crownFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("Beat \(beatIndex + 1)")
                    .font(.headline)

                Toggle(
                    "Accent",
                    isOn: $draftAccent
                )

                Toggle(
                    "Use base note",
                    isOn: $useBaseNote
                )

                VStack(spacing: -1) {
                    Text(
                        useBaseNote
                        ? engine.baseNoteName
                        : noteName(
                            Int(
                                draftNote
                                    .rounded()
                            )
                        )
                    )
                    .font(
                        .system(
                            size: 38,
                            weight: .bold,
                            design: .rounded
                        )
                        .monospaced()
                    )

                    Text(
                        useBaseNote
                        ? "Base note"
                        : "Turn crown to override"
                    )
                    .font(.caption2)
                    .foregroundStyle(
                        .secondary
                    )
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: 60
                )
                .focusable(
                    !useBaseNote
                )
                .focused(
                    $crownFocused
                )
                .digitalCrownRotation(
                    $draftNote,
                    from:
                        Double(
                            MetronomeSettings
                                .minimumBaseMidiNote
                        ),
                    through:
                        Double(
                            MetronomeSettings
                                .maximumBaseMidiNote
                        ),
                    by: 1,
                    sensitivity: .medium,
                    isContinuous: false,
                    isHapticFeedbackEnabled:
                        false
                )
                .onChange(
                    of: draftNote
                ) { _, _ in
                    if crownFocused {
                        useBaseNote = false
                    }
                }

                HStack(spacing: 6) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 44
                    )

                    Button("Save") {
                        engine.setBPMBeat(
                            beatIndex,
                            accent:
                                draftAccent,
                            midiNoteOverride:
                                useBaseNote
                                ? nil
                                : Int(
                                    draftNote
                                        .rounded()
                                )
                        )
                        dismiss()
                    }
                    .buttonStyle(
                        .borderedProminent
                    )
                    .tint(.green)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 44
                    )
                }
            }
            .padding(.horizontal, 7)
        }
        .task {
            draftAccent =
                engine.isBPMBeatAccented(
                    beatIndex
                )

            if let note =
                engine.bpmBeatOverrideMidiNote(
                    at: beatIndex
                )
            {
                useBaseNote = false
                draftNote =
                    Double(note)
            } else {
                useBaseNote = true
                draftNote =
                    Double(
                        engine.settings
                            .baseMidiNote
                    )
            }

            await Task.yield()
            crownFocused =
                !useBaseNote
        }
        .onChange(
            of: useBaseNote
        ) { _, value in
            crownFocused = !value
        }
        .onDisappear {
            crownFocused = false
        }
    }

    private func noteName(
        _ midiNote: Int
    ) -> String {
        let names = [
            "C", "C♯", "D", "D♯",
            "E", "F", "F♯", "G",
            "G♯", "A", "A♯", "B"
        ]

        let clamped =
            min(max(midiNote, 0), 127)

        return
            "\(names[clamped % 12])\(clamped / 12 - 1)"
    }
}

private struct RhythmPresetView: View {
    @EnvironmentObject private var engine:
        MetronomeEngine

    @Environment(\.dismiss)
    private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(
                    RhythmPreset
                        .selectableCases
                ) { preset in
                    Button {
                        engine
                            .applyRhythmPreset(
                                preset
                            )
                        dismiss()
                    } label: {
                        VStack(
                            alignment: .leading,
                            spacing: 2
                        ) {
                            HStack {
                                Text(preset.title)
                                    .font(
                                        .body
                                        .weight(
                                            .semibold
                                        )
                                    )

                                Spacer()

                                if
                                    engine.settings
                                        .rhythmPreset
                                        == preset
                                {
                                    Image(
                                        systemName:
                                            "checkmark.circle.fill"
                                    )
                                    .foregroundStyle(
                                        .green
                                    )
                                }
                            }

                            Text(
                                preset.subtitle
                            )
                            .font(.caption2)
                            .foregroundStyle(
                                .secondary
                            )
                        }
                        .frame(
                            minHeight: 44
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Rhythm")
        }
    }
}


private struct MeterPickerView: View {
    @EnvironmentObject private var engine:
        MetronomeEngine

    @Environment(\.dismiss)
    private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Common") {
                    meterRow(.twoTwo)
                    meterRow(.twoFour)
                    meterRow(.threeFour)
                    meterRow(.fourFour)
                }

                Section("Odd / extended") {
                    meterRow(.fiveFour)
                    meterRow(.sixFour)
                    meterRow(.sevenFour)
                }

                Section("Eighth-note meters") {
                    meterRow(.threeEight)
                    meterRow(.fiveEight)
                    meterRow(.sixEight)
                    meterRow(.sevenEight)
                    meterRow(.nineEight)
                    meterRow(.twelveEight)
                }
            }
            .navigationTitle("Meter")
        }
    }

    @ViewBuilder
    private func meterRow(
        _ meter: TimeSignature
    ) -> some View {
        Button {
            engine.setTimeSignature(meter)
            dismiss()
        } label: {
            HStack {
                Text(meter.label)
                    .font(
                        .system(
                            size: 18,
                            weight: .semibold
                        )
                        .monospacedDigit()
                    )

                Spacer()

                if
                    engine.settings
                        .timeSignature == meter
                {
                    Image(
                        systemName:
                            "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                }
            }
            .frame(minHeight: 44)
            .contentShape(
                .interaction,
                Rectangle()
            )
        }
        .buttonStyle(.plain)
    }
}

private struct ManualPanel: View {
    @EnvironmentObject private var engine: MetronomeEngine

    var body: some View {
        VStack(spacing: 8) {
            if engine.isRecordingMicrophonePattern {
                microphoneRecordingView
            } else if engine.isRecordingManualPattern {
                recordingView
            } else if engine.settings.manualIntervals.isEmpty {
                emptyView
            } else {
                patternView
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "hand.tap.fill")
                .font(.title2)
                .foregroundStyle(.green)

            Text("Record your rhythm")
                .font(.headline)

            Text("Tap the beat naturally. The exact gaps are looped, so it can be irregular.")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Button {
                    engine.beginManualRecording()
                } label: {
                    Label(
                        "Tap",
                        systemImage:
                            "hand.tap.fill"
                    )
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 44
                    )
                }
                .buttonStyle(
                    .borderedProminent
                )
                .tint(.green)

                Button {
                    engine
                        .beginMicrophoneRecording()
                } label: {
                    Label(
                        "Mic",
                        systemImage:
                            "mic.fill"
                    )
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 44
                    )
                }
                .buttonStyle(
                    .borderedProminent
                )
                .tint(.blue)
            }

            if let error =
                engine.microphoneError
            {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(
                        .center
                    )
            }
        }
        .padding(.vertical, 8)
    }

    private var recordingView: some View {
        VStack(spacing: 8) {
            Text("\(engine.manualTapCount) taps")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                engine.recordManualTap()
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "hand.tap.fill")
                        .font(.title2)
                    Text("TAP")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 62)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)

            HStack(spacing: 6) {
                Button("Cancel") {
                    engine.cancelManualRecording()
                }
                .buttonStyle(.bordered)
                .frame(
                    maxWidth: .infinity,
                    minHeight: 44
                )

                Button("Use") {
                    engine.finishManualRecording()
                }
                .buttonStyle(.borderedProminent)
                .frame(
                    maxWidth: .infinity,
                    minHeight: 44
                )
                .disabled(engine.manualTapCount < 2)
            }
        }
    }

    private var microphoneRecordingView: some View {
        VStack(spacing: 7) {
            HStack {
                Image(
                    systemName:
                        "mic.fill"
                )
                .foregroundStyle(.blue)

                Text(
                    engine.isPreparingMicrophone
                    ? "Starting microphone…"
                    : "\(engine.microphoneOnsetCount) notes"
                )
                .font(
                    .caption
                    .monospacedDigit()
                )

                Spacer()
            }

            VStack(spacing: 1) {
                Text(
                    engine.detectedNoteName
                    ?? "—"
                )
                .font(
                    .system(
                        size: 34,
                        weight: .bold,
                        design: .rounded
                    )
                )

                if
                    let frequency =
                        engine.detectedFrequency,
                    let cents =
                        engine.detectedCents
                {
                    Text(
                        String(
                            format:
                                "%.1f Hz  •  %+.0f¢",
                            frequency,
                            cents
                        )
                    )
                    .font(
                        .caption2
                        .monospacedDigit()
                    )
                    .foregroundStyle(
                        abs(cents) <= 5
                        ? .green
                        : .secondary
                    )
                } else {
                    Text(
                        "Play or sing clear notes"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(
                maxWidth: .infinity,
                minHeight: 58
            )
            .background(
                RoundedRectangle(
                    cornerRadius: 14
                )
                .fill(
                    Color.white
                        .opacity(0.06)
                )
            )

            ProgressView(
                value:
                    engine.microphoneLevel,
                total: 1
            )

            HStack(spacing: 6) {
                Button("Cancel") {
                    engine
                        .cancelMicrophoneRecording()
                }
                .buttonStyle(.bordered)
                .frame(
                    maxWidth: .infinity,
                    minHeight: 44
                )

                Button("Use") {
                    engine
                        .finishMicrophoneRecording()
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .frame(
                    maxWidth: .infinity,
                    minHeight: 44
                )
                .disabled(
                    engine.microphoneOnsetCount
                        < 2
                    || engine
                        .isPreparingMicrophone
                )
            }
        }
    }

    private var patternView: some View {
        VStack(spacing: 6) {
            PatternTimelineView()

            HStack {
                Text("\(engine.settings.manualIntervals.count) beats")
                    .font(.caption2.monospacedDigit())

                Spacer()

                if let bpm = engine.manualApproximateBPM {
                    Text("~\(bpm) BPM")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if
                engine.isRunning,
                let note =
                    engine.currentPlaybackNoteName
            {
                HStack(spacing: 5) {
                    Image(
                        systemName:
                            "speaker.wave.2.fill"
                    )
                    .foregroundStyle(.blue)

                    Text(note)
                        .font(
                            .system(
                                size: 22,
                                weight: .bold,
                                design: .rounded
                            )
                            .monospaced()
                        )

                    Text("now")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
            }

            if
                let notes =
                    engine.manualNoteSummary
            {
                Text(notes)
                    .font(
                        .caption2
                        .monospaced()
                    )
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
            }

            HStack(spacing: 6) {
                Button {
                    engine.beginManualRecording()
                } label: {
                    Label(
                        "Tap",
                        systemImage:
                            "hand.tap.fill"
                    )
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 44
                    )
                }
                .buttonStyle(.bordered)

                Button {
                    engine
                        .beginMicrophoneRecording()
                } label: {
                    Label(
                        "Mic",
                        systemImage:
                            "mic.fill"
                    )
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 44
                    )
                }
                .buttonStyle(.bordered)
                .tint(.blue)
            }

            Button {
                engine.clearManualPattern()
            } label: {
                Label(
                    "Clear pattern",
                    systemImage: "trash"
                )
                .frame(
                    maxWidth: .infinity,
                    minHeight: 40
                )
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
    }
}

private struct PatternTimelineView: View {
    @EnvironmentObject private var engine: MetronomeEngine

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { context in
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.22))
                        .frame(height: 3)
                        .offset(y: 12)

                    ForEach(
                        Array(engine.manualBeatPositions.enumerated()),
                        id: \.offset
                    ) { index, position in
                        Circle()
                            .fill(
                                isCurrent(index)
                                ? Color.green
                                : Color.white.opacity(0.72)
                            )
                            .frame(
                                width: isCurrent(index) ? 10 : 7,
                                height: isCurrent(index) ? 10 : 7
                            )
                            .offset(
                                x: max(
                                    0,
                                    geometry.size.width * position - 4
                                ),
                                y: 8
                            )
                    }

                    if engine.isRunning {
                        Rectangle()
                            .fill(Color.green)
                            .frame(width: 2, height: 26)
                            .offset(
                                x: geometry.size.width
                                    * engine.manualProgress(at: context.date)
                            )
                    }
                }
            }
        }
        .frame(height: 28)
        .padding(.horizontal, 2)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.05))
        )
    }

    private func isCurrent(_ index: Int) -> Bool {
        engine.isRunning && engine.beatIndex == index
    }
}



private struct SettingsView: View {
    @EnvironmentObject private var engine:
        MetronomeEngine

    @Environment(\.dismiss)
    private var dismiss

    @State private var showTuner = false
    @State private var showBaseNote = false

    var body: some View {
        NavigationStack {
            List {
                Section("Output") {
                    Toggle(
                        "Sound",
                        isOn: Binding(
                            get: {
                                engine.settings
                                    .audioEnabled
                            },
                            set: {
                                engine
                                    .setAudioEnabled($0)
                            }
                        )
                    )

                    Toggle(
                        "Haptics",
                        isOn: Binding(
                            get: {
                                engine.settings
                                    .hapticsEnabled
                            },
                            set: {
                                engine
                                    .setHapticsEnabled($0)
                            }
                        )
                    )

                    Picker(
                        "Beat sound",
                        selection: Binding(
                            get: {
                                engine.settings
                                    .clickTone
                            },
                            set: {
                                engine
                                    .setClickTone($0)
                            }
                        )
                    ) {
                        ForEach(
                            ClickTone.allCases
                        ) { tone in
                            Text(tone.title)
                                .tag(tone)
                        }
                    }

                    Toggle(
                        "Accent first beat",
                        isOn: Binding(
                            get: {
                                engine.settings
                                    .accentDownbeat
                            },
                            set: {
                                engine
                                    .setAccentDownbeat($0)
                            }
                        )
                    )

                    Picker(
                        "Accent sound",
                        selection: Binding(
                            get: {
                                engine.settings
                                    .accentTone
                            },
                            set: {
                                engine
                                    .setAccentTone($0)
                            }
                        )
                    ) {
                        ForEach(
                            AccentTone.allCases
                        ) { tone in
                            Text(tone.title)
                                .tag(tone)
                        }
                    }

                    Button {
                        engine.previewAccent()
                    } label: {
                        Label(
                            "Preview accent",
                            systemImage:
                                "speaker.wave.2.fill"
                        )
                    }

                    Button {
                        showBaseNote = true
                    } label: {
                        HStack {
                            Label(
                                "Base note",
                                systemImage:
                                    "music.note"
                            )

                            Spacer()

                            Text(
                                engine.baseNoteName
                            )
                            .font(
                                .body
                                .monospaced()
                            )
                            .foregroundStyle(
                                .secondary
                            )
                        }
                    }
                }

                Section("Tools") {
                    Button {
                        showTuner = true
                    } label: {
                        Label(
                            "Instrument Tuner",
                            systemImage:
                                "tuningfork"
                        )
                    }
                }

                Section("App") {
                    Toggle(
                        "Notify when leaving",
                        isOn: Binding(
                            get: {
                                engine.settings
                                    .statusNotificationsEnabled
                            },
                            set: {
                                engine
                                    .setStatusNotificationsEnabled(
                                        $0
                                    )
                            }
                        )
                    )
                }

                if let warning =
                    engine.outputWarning
                {
                    Section("Output status") {
                        Text(warning)
                            .font(.caption2)
                            .foregroundStyle(
                                .orange
                            )
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(
                    placement:
                        .confirmationAction
                ) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .sheet(
            isPresented: $showTuner
        ) {
            TunerView()
                .environmentObject(engine)
        }
        .sheet(
            isPresented: $showBaseNote
        ) {
            BaseNoteView()
                .environmentObject(engine)
        }
    }
}


private struct TunerView: View {
    @EnvironmentObject private var engine:
        MetronomeEngine

    @Environment(\.dismiss)
    private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("Instrument Tuner")
                    .font(.headline)

                VStack(spacing: 1) {
                    Text(
                        engine.detectedNoteName
                        ?? "—"
                    )
                    .font(
                        .system(
                            size: 46,
                            weight: .bold,
                            design: .rounded
                        )
                    )

                    if
                        let frequency =
                            engine.detectedFrequency,
                        let cents =
                            engine.detectedCents
                    {
                        Text(
                            String(
                                format:
                                    "%.1f Hz",
                                frequency
                            )
                        )
                        .font(
                            .caption
                            .monospacedDigit()
                        )

                        Text(
                            String(
                                format:
                                    "%+.0f cents",
                                cents
                            )
                        )
                        .font(
                            .caption
                            .monospacedDigit()
                        )
                        .foregroundStyle(
                            abs(cents) <= 5
                            ? .green
                            : .orange
                        )
                    } else {
                        Text(
                            "Play a steady note"
                        )
                        .font(.caption2)
                        .foregroundStyle(
                            .secondary
                        )
                    }
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: 86
                )
                .background(
                    RoundedRectangle(
                        cornerRadius: 16
                    )
                    .fill(
                        Color.white
                            .opacity(0.06)
                    )
                )

                ProgressView(
                    value:
                        engine.microphoneLevel,
                    total: 1
                )

                if let error =
                    engine.microphoneError
                {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(
                            .center
                        )
                }

                Button {
                    if
                        engine.isTunerActive
                        || engine
                            .isPreparingMicrophone
                    {
                        engine.stopTuner()
                    } else {
                        engine.beginTuner()
                    }
                } label: {
                    HStack {
                        if
                            engine
                                .isPreparingMicrophone
                        {
                            ProgressView()
                                .controlSize(.mini)
                        }

                        Text(
                            engine.isTunerActive
                            || engine
                                .isPreparingMicrophone
                            ? "Stop"
                            : "Start Tuner"
                        )
                    }
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 44
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(
                    engine.isTunerActive
                    || engine
                        .isPreparingMicrophone
                    ? .red
                    : .blue
                )

                Button("Done") {
                    if
                        engine.isTunerActive
                        || engine
                            .isPreparingMicrophone
                    {
                        engine.stopTuner()
                    }

                    dismiss()
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 6)
        }
        .interactiveDismissDisabled(
            engine.isTunerActive
            || engine.isPreparingMicrophone
        )
        .onDisappear {
            if
                engine.isTunerActive
                || engine
                    .isPreparingMicrophone
            {
                engine.stopTuner()
            }
        }
    }
}


private struct BaseNoteView: View {
    @EnvironmentObject private var engine:
        MetronomeEngine

    @Environment(\.dismiss)
    private var dismiss

    @State private var crownNote = 69.0
    @FocusState private var crownFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            Text("Base Note")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: -2) {
                Text(engine.baseNoteName)
                    .font(
                        .system(
                            size: 46,
                            weight: .bold,
                            design: .rounded
                        )
                        .monospaced()
                    )

                Text(
                    "MIDI \(engine.settings.baseMidiNote) • C3–C6"
                )
                .font(
                    .caption2
                    .monospacedDigit()
                )
                .foregroundStyle(.secondary)
            }
            .frame(
                maxWidth: .infinity,
                minHeight: 68
            )
            .focusable()
            .focused($crownFocused)
            .digitalCrownRotation(
                $crownNote,
                from:
                    Double(
                        MetronomeSettings
                            .minimumBaseMidiNote
                    ),
                through:
                    Double(
                        MetronomeSettings
                            .maximumBaseMidiNote
                    ),
                by: 1,
                sensitivity: .medium,
                isContinuous: false,
                isHapticFeedbackEnabled: false
            )
            .onChange(
                of: crownNote
            ) { _, value in
                engine.setBaseMidiNote(
                    Int(value.rounded())
                )
            }
            .onChange(
                of:
                    engine.settings.baseMidiNote
            ) { _, value in
                if Int(crownNote.rounded()) != value {
                    crownNote = Double(value)
                }
            }
            .task {
                crownNote =
                    Double(
                        engine.settings
                            .baseMidiNote
                    )

                await Task.yield()
                crownFocused = true
            }
            .onDisappear {
                crownFocused = false
            }

            HStack(spacing: 4) {
                BaseNoteStepButton(
                    title: "-12",
                    delta: -12
                )
                BaseNoteStepButton(
                    title: "+12",
                    delta: 12
                )
            }

            HStack(spacing: 4) {
                BaseNoteStepButton(
                    title: "-1",
                    delta: -1
                )
                BaseNoteStepButton(
                    title: "+1",
                    delta: 1
                )
            }

            HStack(spacing: 5) {
                Button {
                    engine.previewClick()
                } label: {
                    Label(
                        "Hear",
                        systemImage:
                            "speaker.wave.2.fill"
                    )
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 40
                    )
                }
                .buttonStyle(.bordered)

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .frame(
                    maxWidth: .infinity,
                    minHeight: 40
                )
            }
        }
        .padding(.horizontal, 7)
    }
}

private struct BaseNoteStepButton: View {
    @EnvironmentObject private var engine:
        MetronomeEngine

    let title: String
    let delta: Int

    var body: some View {
        Button(title) {
            engine.nudgeBaseMidiNote(delta)
        }
        .font(
            .system(
                size: 13,
                weight: .semibold
            )
            .monospacedDigit()
        )
        .buttonStyle(.bordered)
        .frame(
            maxWidth: .infinity,
            minHeight: 40
        )
    }
}
