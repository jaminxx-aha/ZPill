#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DEVECO_HOME="${DEVECO_HOME:-/Applications/DevEco-Studio.app/Contents}"
OHOS_FLUTTER="${OHOS_FLUTTER:-$HOME/development/flutter-ohos/bin/flutter}"
DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-$DEVECO_HOME/sdk}"
DEFAULT_JAVA_HOME="$DEVECO_HOME/jbr/Contents/Home"
JAVA_HOME="${JAVA_HOME:-$DEFAULT_JAVA_HOME}"

DEVECO_TOOLS="$DEVECO_HOME/tools"
export DEVECO_SDK_HOME
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$DEVECO_TOOLS/node/bin:$DEVECO_TOOLS/ohpm/bin:$DEVECO_TOOLS/hvigor/bin:$PATH"

if [[ ! -x "$OHOS_FLUTTER" ]]; then
  echo "OHOS_FLUTTER is not executable: $OHOS_FLUTTER" >&2
  exit 1
fi
if [[ ! -d "$DEVECO_SDK_HOME" ]]; then
  echo "DEVECO_SDK_HOME does not exist: $DEVECO_SDK_HOME" >&2
  exit 1
fi
if [[ ! -x "$JAVA_HOME/bin/java" ]]; then
  echo "JAVA_HOME has no executable java: $JAVA_HOME" >&2
  exit 1
fi
for tool in hvigorw ohpm; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "required HarmonyOS tool not found on PATH: $tool" >&2
    exit 1
  fi
done

# The OHOS fork resolves a different Flutter SDK transitive set. Generate both
# package metadata and the build from one toolchain, then avoid re-resolving.
"$OHOS_FLUTTER" pub get
"$OHOS_FLUTTER" build hap --debug --no-codesign --no-pub
