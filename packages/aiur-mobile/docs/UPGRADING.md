# Mobile dependency upgrades

Generated with `create-expo-app@5.0.0 --template blank-typescript@58.0.29`.
Baseline: Expo 58.0.20, React Native 0.88.0, React 19.3.0, TypeScript 6.0.3.
Native packages follow Expo's `bundledNativeModules.json`. Every direct runtime
and development dependency is an exact version; `@aiur/contracts` uses the
repository-local `file:../aiur-contracts` link. Commit the npm lockfile.
React Native 0.88 uses the New Architecture exclusively.

Use this checklist for each SDK upgrade:

- SDK: from ___ to ___; React Native: from ___ to ___.
- Read [Expo release notes](https://expo.dev/changelog) and
  [upgrade guidance](https://docs.expo.dev/workflow/upgrading-expo-sdk-walkthrough/).
  Breaking changes reviewed: ___.
- Run `npx expo install --fix`, replace any ranges with exact versions, and
  commit `package.json` with `package-lock.json`.
- Run `npm ci`, `npm run typecheck`, `npm run lint`, `npm test`, and
  `npm run prebuild:check`.
- Review regenerated native diffs: ___. `ios/` and `android/` stay untracked;
  retain native changes in `app.config.ts` or config plugins.
- Re-run iOS 17 simulator and Android API 29 emulator debug builds and check
  that the root reads “aiur”. Device rows re-run (when applicable): ___.
