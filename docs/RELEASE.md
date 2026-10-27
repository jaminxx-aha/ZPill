# Release Builds

## Version Source

`pubspec.yaml` is the Flutter version source and must include a monotonic
Android/iOS build number:

```yaml
version: 1.0.0+1
```

`ohos/AppScope/app.json5` must keep the same marketing version. Increase its
`versionCode` for every HarmonyOS release, then run:

```bash
tools/check_release_config.sh
```

## CI Gate

`.github/workflows/ci.yml` runs on pull requests and pushes to `main`. It
checks release configuration, analyzes, runs the full test suite, builds an
Android debug APK, and uploads that APK as a short-lived artifact. CI does not
receive production signing keys and therefore never publishes a release.

## Android Release Signing

Release builds use a dedicated signing config only when all four values are
present:

```bash
export ANDROID_KEYSTORE_PATH=/absolute/path/to/release.jks
export ANDROID_KEYSTORE_PASSWORD='...'
export ANDROID_KEY_ALIAS='...'
export ANDROID_KEY_PASSWORD='...'
flutter build appbundle --release
```

For a local interactive build, the same keys may be placed in the ignored
`android/key.properties` file using `storeFile`, `storePassword`, `keyAlias`,
and `keyPassword`. Keep that file and the keystore outside version control.
Without the complete set, Gradle produces an unsigned release artifact and
never falls back to the debug key.

## HarmonyOS Signing

The tracked `ohos/build-profile.json5` intentionally has an empty
`signingConfigs` list. Configure signing through DevEco Studio for the local
machine, but do not commit the generated certificate paths, profile paths,
aliases, or passwords. Put local certificate material in an ignored location;
the CI guard rejects committed password fields and machine-local absolute
paths.

Signing material that has appeared in repository history must be treated as
exposed and rotated before distribution.
