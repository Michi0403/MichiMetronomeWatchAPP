# MichiMetronome 1.10.1 — r12 compile fix

Targeted source fix only.

`ContentView.swift` used a SwiftUI `frame` overload with:

    .frame(width: 34, minHeight: 32)

SwiftUI has no overload that combines a fixed `width` argument with `minHeight`
in that form.

It is now expressed as two compatible modifiers:

    .frame(width: 34)
    .frame(minHeight: 32)

No UI behavior, audio behavior, pitch detection, rhythm presets, settings,
signing, version/build number, or Xcode project settings were changed.
