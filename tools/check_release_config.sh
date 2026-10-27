#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail() {
  printf 'release config: %s\n' "$1" >&2
  exit 1
}

version_line="$(sed -nE 's/^version:[[:space:]]*([^[:space:]]+)[[:space:]]*$/\1/p' pubspec.yaml)"
[[ -n "$version_line" ]] || fail "pubspec.yaml has no version"
[[ "$version_line" == *+* ]] || fail "pubspec version must include a build number (for example 1.0.0+1)"

version_name="${version_line%%+*}"
build_number="${version_line##*+}"
[[ "$build_number" =~ ^[0-9]+$ ]] || fail "pubspec build number must be numeric"

ohos_version="$(sed -nE 's/^[[:space:]]*"versionName"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' ohos/AppScope/app.json5)"
[[ -n "$ohos_version" ]] || fail "ohos/AppScope/app.json5 has no versionName"
[[ "$ohos_version" == "$version_name" ]] ||
  fail "pubspec version $version_name does not match HarmonyOS $ohos_version"

if grep -Eq '"(storePassword|keyPassword)"[[:space:]]*:[[:space:]]*"[^"]+"' \
    ohos/build-profile.json5; then
  fail "HarmonyOS signing passwords must not be committed"
fi

if grep -Eq '(/Users/|/home/)[^"]+' ohos/build-profile.json5; then
  fail "HarmonyOS build profile must not contain machine-local signing paths"
fi

if grep -Fq 'signingConfigs.getByName("debug")' android/app/build.gradle.kts; then
  fail "Android release must not use the debug signing config"
fi

tracked_signing_material="$(
  git ls-files |
    grep -E '(^|/)(android/key\.properties|ohos/signing/local-signing\.json)$|\.(jks|keystore|p12|p7b|p8|mobileprovision|cer)$' ||
    true
)"
if [[ -n "$tracked_signing_material" ]]; then
  fail "tracked signing material must stay outside Git: $tracked_signing_material"
fi

if git grep -I -q -E -- \
    '-----BEGIN (RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----'; then
  fail "tracked files must not contain PEM private keys"
fi

printf 'release config: OK (%s, build %s)\n' "$version_name" "$build_number"
