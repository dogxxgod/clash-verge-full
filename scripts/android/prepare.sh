#!/usr/bin/env bash
# Prepares the Android build inputs that the desktop prebuild script does not cover:
#
#   * the mihomo core for Android (arm64), packaged both as a Tauri sidecar name
#     (`tauri-build` requires the target-triple suffixed file to exist) and as a
#     shared library inside the generated Gradle project, where Android extracts
#     it to a location the app is allowed to execute from;
#   * the geo databases the core reads from the bundled resources.
#
# Run after `tauri android init` has generated `src-tauri/gen/android`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

MIHOMO_VERSION="${MIHOMO_VERSION:-v1.19.32}"
MIHOMO_URL="https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/mihomo-android-arm64-v8-${MIHOMO_VERSION}.gz"

SIDECAR_DIR="src-tauri/sidecar"
RESOURCES_DIR="src-tauri/resources"
CACHE_DIR="node_modules/.verge"

mkdir -p "$SIDECAR_DIR" "$RESOURCES_DIR" "$CACHE_DIR"

# ---------------------------------------------------------------- mihomo core
CORE_CACHE="$CACHE_DIR/mihomo-android-arm64"
if [ ! -f "$CORE_CACHE" ]; then
  echo "==> Downloading mihomo ${MIHOMO_VERSION} (android/arm64)"
  curl -fL --retry 3 -o "$CORE_CACHE.gz" "$MIHOMO_URL"
  gunzip -f "$CORE_CACHE.gz"
  chmod 755 "$CORE_CACHE"
fi

# tauri-build copies `externalBin` entries named with the rust target triple.
for name in verge-mihomo verge-mihomo-alpha; do
  install -m 755 "$CORE_CACHE" "$SIDECAR_DIR/${name}-aarch64-linux-android"
done

# ------------------------------------------------------------- geo databases
fetch_resource() {
  local file="$1"
  local url="$2"
  if [ ! -f "$RESOURCES_DIR/$file" ]; then
    echo "==> Downloading resource $file"
    curl -fL --retry 3 -o "$RESOURCES_DIR/$file" "$url"
  fi
}

RULE_BASE="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest"
fetch_resource Country.mmdb "$RULE_BASE/country.mmdb"
fetch_resource ASN.mmdb "$RULE_BASE/GeoLite2-ASN.mmdb"
fetch_resource geosite.dat "$RULE_BASE/geosite.dat"
fetch_resource geoip.dat "$RULE_BASE/geoip.dat"

# ------------------------------------------------------- generated Gradle app
ANDROID_PROJECT="src-tauri/gen/android"
ANDROID_APP="$ANDROID_PROJECT/app/src/main"
if [ -d "$ANDROID_APP" ]; then
  echo "==> Installing core binaries into the Android project"
  for abi in arm64-v8a; do
    mkdir -p "$ANDROID_APP/jniLibs/$abi"
    for name in verge-mihomo verge-mihomo-alpha; do
      install -m 755 "$CORE_CACHE" "$ANDROID_APP/jniLibs/$abi/lib${name}.so"
    done
  done

  MANIFEST="$ANDROID_APP/AndroidManifest.xml"
  GRADLE="$ANDROID_PROJECT/app/build.gradle.kts"
  if [ -f "$GRADLE" ]; then
    if ! grep -q 'useLegacyPackaging' "$GRADLE"; then
      echo "==> Enabling extractNativeLibs so the core can be executed"
      python3 - "$GRADLE" <<'PY'
import sys

path = sys.argv[1]
with open(path) as handle:
    content = handle.read()

patch = """
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
"""

anchor = "android {"
index = content.index(anchor) + len(anchor)
content = content[:index] + "\n" + patch + content[index:]

with open(path, "w") as handle:
    handle.write(content)
PY
    fi

    if grep -q 'compileSdk = 37' "$GRADLE" && [ -d "$ANDROID_HOME/platforms/android-36" ]; then
      echo "==> Targeting Android 16 (API 36)"
      sed -i 's/compileSdk = 37/compileSdk = 36/; s/targetSdk = 37/targetSdk = 36/' "$GRADLE"
    fi
  fi

  if ! grep -q 'android:extractNativeLibs' "$MANIFEST"; then
    echo "==> Declaring extractNativeLibs in the manifest"
    python3 - "$MANIFEST" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path) as handle:
    content = handle.read()

content, count = re.subn(
    r"<application\b",
    '<application\n        android:extractNativeLibs="true"',
    content,
    count=1,
)
if count == 0:
    raise SystemExit(f"no <application> tag found in {path}")

with open(path, "w") as handle:
    handle.write(content)
PY
  fi
fi

echo "==> Android inputs ready"
