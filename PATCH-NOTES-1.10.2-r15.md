# MichiMetronome 1.10.2 — r15 archive version correction

Distribution metadata fix only.

The Xcode project still had `MARKETING_VERSION = 1.0.0` in all four
root/Watch Debug/Release build configurations. That made Organizer display
archives as version 1.0.0 even though the current source/package is 1.10.2.

Changed:
- `MARKETING_VERSION`: `1.0.0` → `1.10.2`
- `CURRENT_PROJECT_VERSION` remains `2`
- README/TestFlight checklist updated to `1.10.2 (2)`

No runtime, UI, audio, tuner, rhythm, signing, deployment-target, or bundle-ID
behavior was changed.
