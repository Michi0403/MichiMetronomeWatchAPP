# MichiMetronome 1.10.2 — r14 compile fix

Targeted concurrency compile fix for Xcode 26.6.

The Watch target uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, while the
playback scheduling value type `PlaybackPlan` is explicitly `nonisolated`.
The pure numeric `MetronomeSettings` constants therefore must not inherit
MainActor isolation.

The settings limits are now explicitly `nonisolated static let`, including:

- BPM limits
- manual interval limits
- base-note limits (C3 / MIDI 48 through C6 / MIDI 84)
- maximum captured manual events

This fixes the Xcode errors at `MetronomeEngine.swift:1695` and `:1698` without
moving playback scheduling onto the main actor and without changing musical,
audio, UI, persistence, signing, version, or build-number behavior.

Validation performed here:

- all Swift files pass syntax parsing
- `MetronomeSettings.swift` plus a nonisolated access probe type-checks with
  `-default-isolation MainActor -strict-concurrency=complete`

The local environment still does not contain the Xcode 26.6 watchOS SDK, so a
real Watch target build remains the final validation.

The separate `MessagesApplicationStub.xcassets` / `Watch6,13` message is not a
source-code error. For physical-Watch runs, select the `MichiMetronome Watch
App` scheme. The root `MichiMetronome` scheme is the distribution/archive
wrapper and should be archived against a generic iOS destination rather than
run against a physical Watch.
