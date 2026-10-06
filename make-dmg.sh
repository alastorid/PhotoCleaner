#!/bin/bash
#
# Packages dist/PhotoCleaner.app into a drag-and-drop DMG:
#
#     PhotoCleaner.app        the app
#     Applications -> /Applications
#
# Dropping the app on that arrow is the whole install. No installer, no
# AppleScript, no pkg, nothing to uninstall — the app's only footprint outside
# its own bundle is ~/Library/Application Support/PhotoCleaner and
# ~/Library/Logs/PhotoCleaner, which "Remove everything PhotoCleaner stores" in
# the README covers.
#
# Everything here is a system tool: hdiutil ships with macOS.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

APP_NAME="PhotoCleaner"
BUNDLE_ID="com.alastorid.photocleaner"
APP="$ROOT/dist/$APP_NAME.app"

usage() {
    cat <<'EOF'
usage: ./make-dmg.sh [--version N.N.N] [--arch arm64|x86_64] [--output FILE] [--no-build]

  --version N.N.N   Version stamped into the app and the DMG filename.
                    Defaults to PHOTOCLEANER_VERSION, else 1.0.0.
  --arch ARCH       Architecture to build for. Defaults to this Mac's.
  --output FILE     Where to write the DMG. Defaults to dist/PhotoCleaner-<version>-<arch>.dmg
  --no-build        Package the app that is already in dist/ instead of rebuilding.
  -h, --help        This text.
EOF
}

VERSION="${PHOTOCLEANER_VERSION:-1.0.0}"
ARCH="${PHOTOCLEANER_ARCH:-$(uname -m)}"
OUTPUT=""
BUILD=1

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
        --arch)    ARCH="${2:?--arch needs a value}";       shift 2 ;;
        --output)  OUTPUT="${2:?--output needs a value}";   shift 2 ;;
        --no-build) BUILD=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "make-dmg: unknown argument '$1' (try --help)" >&2; exit 1 ;;
    esac
done

if ! printf '%s' "$VERSION" | grep -qE '^[0-9]+(\.[0-9]+){0,2}$'; then
    echo "make-dmg: invalid version '$VERSION' — expected N, N.N or N.N.N" >&2
    exit 1
fi

[ -n "$OUTPUT" ] || OUTPUT="$ROOT/dist/$APP_NAME-$VERSION-$ARCH.dmg"

if [ "$BUILD" -eq 1 ]; then
    echo "==> Building $APP_NAME $VERSION ($ARCH)"
    PHOTOCLEANER_VERSION="$VERSION" PHOTOCLEANER_ARCH="$ARCH" "$ROOT/build.sh" 2>&1 | sed 's/^/    /'
fi

[ -d "$APP" ] || { echo "make-dmg: $APP does not exist — run ./build.sh" >&2; exit 1; }

# Package what was built, not what was asked for. A stale or mislabelled bundle
# silently shipped under a release version is the kind of bug nobody catches
# until a user reports the wrong build, so the two are compared here.
BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true)"
BUILT_ARCH="$(lipo -archs "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || echo unknown)"

if [ "$BUILT_VERSION" != "$VERSION" ]; then
    echo "make-dmg: $APP reports version '$BUILT_VERSION', expected '$VERSION'" >&2
    echo "          rebuild without --no-build" >&2
    exit 1
fi
if [ "$BUILT_ARCH" != "$ARCH" ]; then
    echo "make-dmg: $APP is built for '$BUILT_ARCH', expected '$ARCH'" >&2
    echo "          rebuild without --no-build" >&2
    exit 1
fi

# Stage the volume contents in a temporary directory. The trailing slash on the
# app copy matters: without it cp would copy the *contents* of the bundle into
# the destination directory instead of the bundle itself, and the volume would
# contain MacOS/ and Resources/ lying around loose.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/photocleaner-dmg.XXXXXX")"
MOUNT=""
cleanup() {
    if [ -n "$MOUNT" ]; then hdiutil detach "$MOUNT" -quiet 2>/dev/null || true; fi
    rm -rf "$STAGE"
}
trap cleanup EXIT

echo "==> Staging"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"

echo "==> Creating $(basename "$OUTPUT")"
hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$STAGE" \
    -format UDZO \
    -quiet \
    "$OUTPUT"

# A DMG that mounts but contains nothing is a release nobody can use, and
# hdiutil happily produces one. Verify by mounting the finished image rather
# than by trusting the staging directory: this checks the bytes that ship.
echo "==> Verifying"
hdiutil verify "$OUTPUT" >/dev/null 2>&1 \
    || { echo "make-dmg: hdiutil verify failed on $OUTPUT" >&2; exit 1; }

MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/photocleaner-mount.XXXXXX")"
hdiutil attach "$OUTPUT" -mountpoint "$MOUNT" -nobrowse -readonly -quiet

verify_failed=0
check() {
    if [ -e "$1" ]; then
        echo "    ok: $2"
    else
        echo "    MISSING: $2" >&2
        verify_failed=1
    fi
}

check "$MOUNT/$APP_NAME.app" "$APP_NAME.app present"
check "$MOUNT/$APP_NAME.app/Contents/MacOS/$APP_NAME" "executable present"

# The drag target has to be a symlink to the real /Applications, not a copy or
# a folder: readlink and the resolved path both have to agree, or dragging the
# app there installs it into the disk image and it vanishes on eject.
if [ -L "$MOUNT/Applications" ] && [ "$(readlink "$MOUNT/Applications")" = "/Applications" ]; then
    echo "    ok: Applications -> /Applications"
else
    echo "    MISSING: Applications symlink" >&2
    verify_failed=1
fi

MOUNTED_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$MOUNT/$APP_NAME.app/Contents/Info.plist" 2>/dev/null || true)"
if [ "$MOUNTED_ID" = "$BUNDLE_ID" ]; then
    echo "    ok: bundle identifier"
else
    echo "    MISSING: bundle identifier is '$MOUNTED_ID', expected '$BUNDLE_ID'" >&2
    verify_failed=1
fi

# The signature has to survive the round trip through the image. Gatekeeper
# re-checks it on the way out of /Volumes, so a bundle that verifies here but
# not after hdiutil is worse than no check at all.
if codesign --verify --deep --strict "$MOUNT/$APP_NAME.app" 2>/dev/null; then
    echo "    ok: signature intact inside the image"
else
    echo "    MISSING: signature does not verify inside the image" >&2
    verify_failed=1
fi

hdiutil detach "$MOUNT" -quiet
MOUNT=""
rmdir "$MOUNT" 2>/dev/null || true

if [ "$verify_failed" -ne 0 ]; then
    echo "make-dmg: $OUTPUT failed verification — not releasing this" >&2
    exit 1
fi

echo
echo "Built $OUTPUT"
echo "  $(du -h "$OUTPUT" | cut -f1), $APP_NAME $VERSION ($ARCH)"
echo "Release it with: gh release create v$VERSION $OUTPUT"
