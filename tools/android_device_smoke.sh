#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ADB="${ADB:-adb}"
ANDROID_PACKAGE="${ANDROID_PACKAGE:-com.jaminxx.zpill}"
ANDROID_ACTIVITY="${ANDROID_ACTIVITY:-com.jaminxx.zpill/.MainActivity}"
LAUNCH_SETTLE_SECONDS="${LAUNCH_SETTLE_SECONDS:-8}"
APK="build/app/outputs/flutter-apk/app-debug.apk"

if ! command -v "$ADB" >/dev/null 2>&1; then
  echo "adb not found: $ADB" >&2
  exit 1
fi

"$ADB" wait-for-device
flutter build apk --debug --no-pub
"$ADB" install -r "$APK"
"$ADB" logcat -c
"$ADB" shell am force-stop "$ANDROID_PACKAGE"

launch_output="$("$ADB" shell am start -W -n "$ANDROID_ACTIVITY")"
printf '%s\n' "$launch_output"
if ! grep -q 'Status: ok' <<<"$launch_output"; then
  echo "Android activity did not launch successfully" >&2
  exit 1
fi

sleep "$LAUNCH_SETTLE_SECONDS"
if ! "$ADB" shell pidof "$ANDROID_PACKAGE" | grep -q '[0-9]'; then
  echo "Android app process is not running after launch" >&2
  exit 1
fi

recent_log="$("$ADB" logcat -d -v brief -t 1000)"
if grep -Eq 'FATAL EXCEPTION|Process: '"$ANDROID_PACKAGE"' \(pid' <<<"$recent_log"; then
  grep -E 'FATAL EXCEPTION|Process: '"$ANDROID_PACKAGE"' \(pid' <<<"$recent_log" >&2
  echo "Android app crashed during launch smoke test" >&2
  exit 1
fi

echo "Android launch smoke: OK ($ANDROID_PACKAGE)"
