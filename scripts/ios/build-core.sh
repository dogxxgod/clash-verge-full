#!/usr/bin/env bash
# Builds the mihomo core as a linkable iOS library (static archive per slice, then
# optionally an XCFramework).
#
# iOS cannot start a sidecar process, so unlike Android the core has to be linked
# into the app/Network Extension binary instead of being shipped as an executable.
# Upstream publishes no iOS artifact, so it is built from source here.
#
# The Go toolchain requires cgo for GOOS=ios, so a full Xcode installation (SDK +
# clang) is mandatory. Build inputs live outside the repository: the mihomo clone,
# the Go module cache and the output all default to paths under WORK_DIR.
#
# Usage:
#   scripts/ios/build-core.sh [options]
#
#   --device            build only the arm64 device slice
#   --simulator         build only the arm64 simulator slice
#   --all               build both slices (default)
#   --version <tag>     mihomo git tag to build (default: v1.19.32, the version
#                       scripts/android/prepare.sh downloads)
#   --work-dir <dir>    where the clone, module cache and outputs live
#   --out-dir <dir>     where the archives land (default: <work-dir>/out)
#   --min-ios <ver>     deployment target, default read from
#                       src-tauri/tauri.ios.conf.json (bundle.iOS.minimumSystemVersion)
#   --tags <list>       Go build tags (default: with_gvisor, as upstream's Makefile;
#                       pass --tags "" to build without any)
#   --no-xcframework    skip XCFramework creation
#   --no-link-test      skip linking a small C driver against each archive
#   --fresh             delete the existing clone before building
#   -h, --help          show this help
#
# Environment:
#   GO_BIN              go binary to use (default: go from PATH)
#   MIHOMO_VERSION      same as --version
#   WORK_DIR            same as --work-dir
#   OUT_DIR             same as --out-dir
#   TAGS                same as --tags
#   MIHOMO_GIT_URL      clone source (default: https://github.com/MetaCubeX/mihomo.git)
#
# Prerequisites: Xcode with the iphoneos and iphonesimulator SDKs (xcode-select -p
# must point into Xcode.app), Go >= 1.20 with cgo support, git, network access for
# the clone and the Go module downloads, and roughly 4 GiB of disk in WORK_DIR.
#
# Outputs (per requested slice and version):
#   <out-dir>/libmihomo-ios-arm64.a        device static archive (+ matching .h)
#   <out-dir>/libmihomo-iossim-arm64.a     simulator static archive (+ matching .h)
#   <out-dir>/mihomo.xcframework           both slices, when --no-xcframework is absent
#
# The archives are ~110-140 MiB each and are build artifacts: keep them out of git.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

MIHOMO_VERSION="${MIHOMO_VERSION:-v1.19.32}"
WORK_DIR="${WORK_DIR:-$HOME/.cache/clash-verge-ios-core}"
OUT_DIR="${OUT_DIR:-}"
MIN_IOS=""
GO_BIN="${GO_BIN:-go}"
MIHOMO_GIT_URL="${MIHOMO_GIT_URL:-https://github.com/MetaCubeX/mihomo.git}"

BUILD_DEVICE=0
BUILD_SIMULATOR=0
MAKE_XCFRAMEWORK=1
LINK_TEST=1
FRESH=0

usage() { awk 'NR > 1 { if ($0 == "set -euo pipefail") exit; print }' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --device) BUILD_DEVICE=1 ;;
    --simulator) BUILD_SIMULATOR=1 ;;
    --all) BUILD_DEVICE=1; BUILD_SIMULATOR=1 ;;
    --version) MIHOMO_VERSION="$2"; shift ;;
    --work-dir) WORK_DIR="$2"; shift ;;
    --out-dir) OUT_DIR="$2"; shift ;;
    --min-ios) MIN_IOS="$2"; shift ;;
    --tags) TAGS="$2"; shift ;;
    --no-xcframework) MAKE_XCFRAMEWORK=0 ;;
    --no-link-test) LINK_TEST=0 ;;
    --fresh) FRESH=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "!! unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [ "$BUILD_DEVICE" = 0 ] && [ "$BUILD_SIMULATOR" = 0 ]; then
  BUILD_DEVICE=1
  BUILD_SIMULATOR=1
fi

OUT_DIR="${OUT_DIR:-$WORK_DIR/out}"
CLONE_DIR="$WORK_DIR/mihomo"
BRIDGE_DIR="$CLONE_DIR/iosbridge"

# ------------------------------------------------------------- prerequisites
DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
case "$DEVELOPER_DIR" in
  *Xcode*.app/Contents/Developer) ;;
  *)
    echo "!! A full Xcode installation is required; the active developer directory is" >&2
    echo "!! '${DEVELOPER_DIR:-<none>}' (the command line tools alone have no iOS SDK)." >&2
    echo "!! Install Xcode, then run: sudo xcode-select -s /Applications/Xcode.app" >&2
    exit 1
    ;;
esac

if ! "$GO_BIN" version >/dev/null 2>&1; then
  echo "!! '$GO_BIN' is not a working Go toolchain; set GO_BIN to the go binary to use." >&2
  exit 1
fi

DEVICE_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
SIM_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
DEVICE_CC="$(xcrun --sdk iphoneos -f clang)"
SIM_CC="$(xcrun --sdk iphonesimulator -f clang)"

if [ -z "$MIN_IOS" ]; then
  MIN_IOS="$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1]))["bundle"]["iOS"].get("minimumSystemVersion", ""))
' "$REPO_ROOT/src-tauri/tauri.ios.conf.json" 2>/dev/null || true)"
fi
MIN_IOS="${MIN_IOS:-15.0}"

# Go's own modcache is used unless it is redirected; keep everything reproducible
# inside WORK_DIR and avoid the "GOPATH and GOROOT are the same" warning seen when
# the host Go install doubles as GOPATH.
export GOPATH="${GOPATH:-$WORK_DIR/gopath}"
export GOMODCACHE="${GOMODCACHE:-$WORK_DIR/gomodcache}"
export CGO_ENABLED=1
export GOOS=ios
export GOARCH=arm64

mkdir -p "$WORK_DIR" "$OUT_DIR" "$GOPATH" "$GOMODCACHE"

echo "==> mihomo version:    $MIHOMO_VERSION"
echo "==> device SDK:        $DEVICE_SDK"
echo "==> simulator SDK:     $SIM_SDK"
echo "==> deployment target: iOS $MIN_IOS"
echo "==> work dir:          $WORK_DIR"
echo "==> output dir:        $OUT_DIR"
echo "==> go:                $("$GO_BIN" version)"

# ------------------------------------------------------------------- source
if [ "$FRESH" = 1 ]; then
  echo "==> Removing the existing clone (--fresh)"
  rm -rf "$CLONE_DIR"
fi

if [ ! -d "$CLONE_DIR/.git" ]; then
  echo "==> Cloning mihomo $MIHOMO_VERSION"
  git clone --depth 1 --branch "$MIHOMO_VERSION" "$MIHOMO_GIT_URL" "$CLONE_DIR"
elif ! git -C "$CLONE_DIR" rev-parse -q --verify "refs/tags/$MIHOMO_VERSION" >/dev/null; then
  echo "==> Fetching tag $MIHOMO_VERSION into the existing clone"
  git -C "$CLONE_DIR" fetch --depth 1 origin "refs/tags/$MIHOMO_VERSION:refs/tags/$MIHOMO_VERSION"
fi

if ! git -C "$CLONE_DIR" rev-parse -q --verify "refs/tags/$MIHOMO_VERSION" >/dev/null; then
  echo "!! $CLONE_DIR has no tag $MIHOMO_VERSION; re-run with --fresh." >&2
  exit 1
fi
git -C "$CLONE_DIR" checkout --quiet --detach "refs/tags/$MIHOMO_VERSION"
echo "==> source commit:     $(git -C "$CLONE_DIR" rev-parse HEAD)"

# -------------------------------------------------------------- cgo bridge
# mihomo's main package only exposes a CLI; a c-archive needs exported C entry
# points, so a small bridge package is generated inside the clone (never in git).
mkdir -p "$BRIDGE_DIR"
BRIDGE_TMP="$(mktemp)"
cat > "$BRIDGE_TMP" <<'EOF'
// Package main is the cgo bridge that turns mihomo into a linkable iOS library.
// Generated by clash-verge-rev/scripts/ios/build-core.sh; not part of upstream.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"unsafe"

	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/log"
	_ "github.com/metacubex/mihomo/rules/provider"
)

//export mihomo_version
func mihomo_version() *C.char {
	return C.CString(constant.Version)
}

//export mihomo_set_home_dir
func mihomo_set_home_dir(dir *C.char) C.int {
	d := C.GoString(dir)
	constant.SetHomeDir(d)
	if err := config.Init(d); err != nil {
		log.Errorln("mihomo: config init failed: %s", err.Error())
		return -1
	}
	return 0
}

//export mihomo_parse_config
func mihomo_parse_config(data *C.char, n C.int) C.int {
	buf := C.GoBytes(unsafe.Pointer(data), n)
	if err := hub.Parse(buf); err != nil {
		log.Errorln("mihomo: parse config failed: %s", err.Error())
		return -1
	}
	return 0
}

//export mihomo_shutdown
func mihomo_shutdown() {
	executor.Shutdown()
}

func main() {}
EOF
if ! cmp -s "$BRIDGE_TMP" "$BRIDGE_DIR/main.go" 2>/dev/null; then
  echo "==> Writing the cgo bridge ($BRIDGE_DIR/main.go)"
  cp "$BRIDGE_TMP" "$BRIDGE_DIR/main.go"
fi
rm -f "$BRIDGE_TMP"

# ------------------------------------------------------------------- builds
# Upstream's Makefile builds with `-tags with_gvisor` (tailscale outbound plus the
# WithGVisor feature flag) and stamps constant.Version/BuildTime through ldflags,
# so do the same; otherwise mihomo_version() reports the Clash-compat default.
TAGS="${TAGS:-with_gvisor}"
LDFLAGS="-X github.com/metacubex/mihomo/constant.Version=$MIHOMO_VERSION
  -X github.com/metacubex/mihomo/constant.BuildTime=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
LDFLAGS="$(echo "$LDFLAGS" | tr '\n' ' ')"

# CGO_CFLAGS/CGO_LDFLAGS carry the SDK and the -target triple; the simulator must
# not also pass -mios-simulator-version-min, clang rejects the combination with
# "-Werror,-Woverriding-option".
build_slice() {
  local label="$1" cc="$2" sdk="$3" target="$4" out="$5"
  echo "==> Building $label slice -> $out"
  (
    set -x
    CC="$cc" \
    CGO_CFLAGS="-isysroot $sdk -arch arm64 -target $target" \
    CGO_LDFLAGS="-isysroot $sdk -arch arm64 -target $target" \
    "$GO_BIN" build -tags "$TAGS" -buildmode=c-archive -trimpath \
      -ldflags "$LDFLAGS" -o "$out" ./iosbridge
  )
}

DEVICE_ARCHIVE="$OUT_DIR/libmihomo-ios-arm64.a"
SIM_ARCHIVE="$OUT_DIR/libmihomo-iossim-arm64.a"

cd "$CLONE_DIR"

if [ "$BUILD_DEVICE" = 1 ]; then
  build_slice "device (arm64)" "$DEVICE_CC" "$DEVICE_SDK" \
    "arm64-apple-ios${MIN_IOS}" "$DEVICE_ARCHIVE"
fi

if [ "$BUILD_SIMULATOR" = 1 ]; then
  build_slice "simulator (arm64)" "$SIM_CC" "$SIM_SDK" \
    "arm64-apple-ios${MIN_IOS}-simulator" "$SIM_ARCHIVE"
fi

# ------------------------------------------------------------------ verify
# LC_BUILD_VERSION platform: 2 = PLATFORM_IOS, 7 = PLATFORM_IOSSIMULATOR.
verify_archive() {
  local archive="$1" expected_platform="$2" header="$3"
  [ -f "$archive" ] || { echo "!! missing archive $archive" >&2; return 1; }
  [ -f "$header" ] || { echo "!! missing generated header $header" >&2; return 1; }

  echo "==> $archive"
  ls -l "$archive" "$header"
  lipo -info "$archive"

  local platforms
  platforms="$(otool -l "$archive" | awk '/LC_BUILD_VERSION/{f=1} f&&/platform/{print $2; f=0}' | sort -u)"
  if [ "$platforms" != "$expected_platform" ]; then
    echo "!! unexpected Mach-O platform(s) in $archive: '${platforms:-none}' (want $expected_platform)" >&2
    return 1
  fi
  echo "    platform ${platforms} (2=IOS device, 7=IOSSIMULATOR) ok"

  local missing=0 sym
  for sym in mihomo_version mihomo_set_home_dir mihomo_parse_config mihomo_shutdown; do
    if ! nm -gU "$archive" | grep -q " T _${sym}$"; then
      echo "!! exported symbol $sym is missing from $archive" >&2
      missing=1
    fi
  done
  [ "$missing" = 0 ] || return 1
  echo "    exported symbols ok: $(nm -gU "$archive" | grep -c ' T _mihomo_') mihomo_* entries"
}

if [ "$BUILD_DEVICE" = 1 ]; then
  verify_archive "$DEVICE_ARCHIVE" 2 "${DEVICE_ARCHIVE%.a}.h"
fi
if [ "$BUILD_SIMULATOR" = 1 ]; then
  verify_archive "$SIM_ARCHIVE" 7 "${SIM_ARCHIVE%.a}.h"
fi

# --------------------------------------------------------------- link check
# Compiling an archive says nothing about linkability: the Go runtime references
# CoreFoundation/Security/libresolv, so a caller that forgets those frameworks
# gets undefined symbols. Link a throwaway driver against each slice to prove the
# archive is actually consumable, and print the flags the app has to repeat.
link_check() {
  local label="$1" cc="$2" sdk="$3" target="$4" archive="$5"
  local tmp
  tmp="$(mktemp -d)"

  cat > "$tmp/main.c" <<'EOF'
#include <stdio.h>
char *mihomo_version(void);
int main(void) { printf("mihomo %s\n", mihomo_version()); return 0; }
EOF

  echo "==> Link check ($label)"
  "$cc" -target "$target" -isysroot "$sdk" "$tmp/main.c" "$archive" \
    -framework CoreFoundation -framework Security -lresolv \
    -o "$tmp/link-check"
  file "$tmp/link-check"
  otool -l "$tmp/link-check" | awk '/LC_BUILD_VERSION/{f=1} f&&/platform/{print "    linked platform " $2; exit}'
  rm -rf "$tmp"
}

if [ "$LINK_TEST" = 1 ]; then
  if [ "$BUILD_DEVICE" = 1 ]; then
    link_check "device" "$DEVICE_CC" "$DEVICE_SDK" "arm64-apple-ios${MIN_IOS}" "$DEVICE_ARCHIVE"
  fi
  if [ "$BUILD_SIMULATOR" = 1 ]; then
    link_check "simulator" "$SIM_CC" "$SIM_SDK" "arm64-apple-ios${MIN_IOS}-simulator" "$SIM_ARCHIVE"
  fi
fi

# ------------------------------------------------------------- xcframework
if [ "$MAKE_XCFRAMEWORK" = 1 ]; then
  if [ "$BUILD_DEVICE" = 1 ] && [ "$BUILD_SIMULATOR" = 1 ]; then
    HEADERS_ROOT="$OUT_DIR/headers"
    rm -rf "$HEADERS_ROOT"
    mkdir -p "$HEADERS_ROOT/ios-arm64" "$HEADERS_ROOT/ios-arm64-simulator"
    cp "${DEVICE_ARCHIVE%.a}.h" "$HEADERS_ROOT/ios-arm64/"
    cp "${SIM_ARCHIVE%.a}.h" "$HEADERS_ROOT/ios-arm64-simulator/"

    XCFRAMEWORK="$OUT_DIR/mihomo.xcframework"
    rm -rf "$XCFRAMEWORK"
    echo "==> Creating $XCFRAMEWORK"
    xcodebuild -create-xcframework \
      -library "$DEVICE_ARCHIVE" -headers "$HEADERS_ROOT/ios-arm64" \
      -library "$SIM_ARCHIVE" -headers "$HEADERS_ROOT/ios-arm64-simulator" \
      -output "$XCFRAMEWORK"
    find "$XCFRAMEWORK" -maxdepth 2 -mindepth 1 | sort
  else
    echo "==> Skipping the XCFramework: both slices are required (use --all)."
  fi
fi

echo "==> Done. Link the archive/XCFramework into the app and the Network Extension;"
echo "    the C entry points are declared in libmihomo*.h."
echo "    The consuming target must keep -framework CoreFoundation -framework Security"
echo "    -lresolv in its link flags."
