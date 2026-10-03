# MichiMetronome 1.10.0 — first tester feedback pass

Public version remains 1.0.0. TestFlight build is now 2.

## Main controls

- Start/Stop is larger (50 pt high), uses heavier type, a stronger outline, and explicit START/STOP labels.
- Tempo Crown editing is transactional. Crown/step changes stay local until Save is tapped.
- Closing the Tempo sheet with × or Cancel discards changes instead of silently saving them.
- Tempo editor is scrollable, so Save/Cancel stay reachable on the smaller Apple Watch SE display.

## Accent

- The accent no longer depends on the regular Wood/Sharp/Low/Beep timbre.
- Default accent sound is a dedicated Harmonic timbre with a stronger transient.
- Accent sound is configurable: Harmonic, Octave, Bell.
- “Accent first beat” now drives the actual first BPM beat accent state.
- Accent preview added to Settings.

## Audio longevity

- The Core Audio scheduling horizon is reduced from 8 seconds to 2 seconds to keep the AVAudioPlayerNode queue shallow on Watch hardware.
- If watchOS stops the AVAudioEngine render graph while playback is prepared, scheduling now attempts to restart the engine rather than silently dropping every future note.

## Settings

- Removed the explanatory paragraphs from the main Settings list.
- Output is now focused on Sound, Haptics, Beat sound, Accent, Accent sound and Base note.
- Tuner is under Tools and notification behavior under App.

## Tuner

- Pitch calculation remains fast internally, but tuner text updates are limited to about 4 Hz (240 ms) for readability.
- Mic melody recording keeps its faster visual/event path.

## Base note

- Base-note selection is limited to C3…C6 (MIDI 48…84), a practical Watch-speaker range.
- Existing settings are migrated and clamped into that range.

## Rhythm presets

Added BPM-mode presets:

- Plain
- Rock
- Hip-Hop
- Classical
- Waltz
- 6/8 Pulse

Presets can set meter, per-beat accent pattern and per-beat note offsets from the configured base note. The default accent timbre for presets is Harmonic.

## Per-beat editing

The regular BPM screen now displays the note for each beat. Long-press a beat to edit it:

- Accent on/off
- Use base note or override the note with the Digital Crown

Edits are saved as a Custom rhythm and can be changed while keeping the global BPM workflow.

## Settings migration

Settings schema moves from v6 to v7. Existing v6/v5/v4/v3 settings migrate automatically.

## TestFlight/distribution cleanup

- CURRENT_PROJECT_VERSION: 2
- Root iOS wrapper deployment target: 15.0 (Watch app remains watchOS 26.0)
- Root wrapper declares `ITSAppUsesNonExemptEncryption = NO`
- Added a shared `MichiMetronome` archive scheme so a fresh checkout/ZIP does not require manually creating the root archive scheme again.
