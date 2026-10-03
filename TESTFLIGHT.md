# TestFlight checklist

## Before archive

- Open `MichiMetronome/MichiMetronome.xcodeproj`.
- Root bundle ID: `com.michi0403.michimetronome`.
- Watch bundle ID: `com.michi0403.michimetronome.watchkitapp`.
- Version/build: `1.0.0 (1)`.
- Automatic signing enabled for both generated targets.
- Team: `YS97976PCZ`.
- `PrivacyInfo.xcprivacy` visible inside `MichiMetronome Watch App`.
- App icon visible in the Watch target asset catalog.
- Microphone permission prompt works on physical Watch.
- Sound, Mic recording and Tuner tested on physical Watch.

## Archive

Archive the generated root/container target, not the legacy project and not a
bare Watch-only archive.

1. Scheme: `MichiMetronome`.
2. Product → Archive.
3. Organizer → Validate App.
4. Distribute App → TestFlight & App Store.
5. Keep automatic signing enabled during distribution.

## App Store Connect

Create/select the iOS-platform app record whose bundle ID is:

`com.michi0403.michimetronome`

The actual product is Watch-only; the iOS-platform record is the packaging record
used for this Watch-only distribution container.

After upload processing:

1. Open TestFlight.
2. Add the build to an Internal Testing group first if App Store Connect asks for it.
3. Create an External Testing group.
4. Add beta description, feedback email, review contact and What to Test.
5. Add build `1.0.0 (1)`.
6. Submit the first external build for TestFlight Beta App Review.
7. After approval, enable Public Link.
8. Send the link to the tester.

## Brother installation

Open the public TestFlight link on the iPhone paired with his Apple Watch.
Accept the beta in TestFlight, then install the Watch-only app.

## Build 2 (tester feedback pass)

The source package includes a shared root `MichiMetronome` scheme for archiving.
Archive the root scheme for App Store Connect/TestFlight. The Watch target remains
watchOS 26.0; the packaging wrapper now targets iOS 15.0. Build number is 2.
