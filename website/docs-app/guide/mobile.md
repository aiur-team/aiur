# Mobile local builds

The mobile app is an early developer scaffold in `packages/aiur-mobile/`.
It displays **aiur**; pairing, networking and dashboard screens are not available
in this scaffold. The app is not yet published.

## Prerequisites

- Node.js 24 and npm (the package includes `mise.toml`).
- Android: Android Studio, an Android SDK and JDK compatible with the pinned
  [Expo SDK](https://docs.expo.dev/versions/latest/), plus an Android 10
  (API 29) or newer emulator. Configure `ANDROID_HOME` and start the emulator.
- iOS: macOS, Xcode and its command line tools, CocoaPods, and an iOS 17 or
  newer simulator. Select the simulator in Xcode before running the app.

These commands build locally; no EAS account or paid cloud build service is
needed. iOS builds require macOS. Physical devices require platform signing.

## Install and check

From the repository root:

```sh
cd packages/aiur-mobile
npm ci
npm run typecheck
npm run lint
npm test
npm run prebuild:check
```

`prebuild:check` generates both native projects in a disposable directory and
checks their minimum OS settings. It does not compile native binaries or install
CocoaPods. All direct dependencies are pinned; upgrade notes and the checklist
live in `packages/aiur-mobile/docs/UPGRADING.md`.

## Run a debug app

From `packages/aiur-mobile/`, generate the native projects:

```sh
npx expo prebuild --clean
```

Then build and launch on the running emulator or simulator:

```sh
npx expo run:android --variant debug
# macOS only:
npx expo run:ios --configuration Debug
```

Both should display **aiur**. To choose a particular simulator/emulator, add
`--device` and select it from Expo's list. Subsequent launches can use
`npm run android` or `npm run ios`. `npm start` starts Metro for an installed
development build.

Native folders (`ios/`, `android/`) are generated and ignored by Git. Put native
configuration in `app.config.ts` and config plugins; `prebuild --clean` replaces
the generated folders. App identifiers are `dev.aiur.mobile` on both platforms;
the minimum versions are iOS 17 and Android 10 (API 29).
