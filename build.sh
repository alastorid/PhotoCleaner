#!/bin/bash
#
# Builds dist/PhotoCleaner.app — a minimal, ad-hoc signed macOS application
# bundle. There is no Xcode project: a bundle is required only because macOS
# attributes the Photos permission prompt to a bundle identity, and PhotoKit
# refuses to prompt without NSPhotoLibraryUsageDescription.
#
# Everything is built from the system toolchain. No package manager, no
# dependency resolution, no third-party runtime.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

APP="$ROOT/dist/PhotoCleaner.app"
BINARY="$APP/Contents/MacOS/PhotoCleaner"
GENERATED="$ROOT/Sources/PhotoCleaner/Web/GeneratedWebAssets.swift"
DEPLOYMENT_TARGET="15.0"

# CalculateImageAestheticsScoresRequest (Vision) is macOS 15+; the deployment
# target must not be lowered without also replacing the model, which this tool
# deliberately does not do.
#
# PHOTOCLEANER_ARCH pins the architecture. Left unset, the build is for whatever
# Mac it runs on, which is what a developer wants. The release workflow sets it
# explicitly so the published DMG says arm64 on its filename and is arm64
# inside, rather than inheriting the runner's architecture by accident.
ARCH="${PHOTOCLEANER_ARCH:-$(uname -m)}"
case "$ARCH" in
    arm64|x86_64) ;;
    *)
        echo "build: unsupported architecture '$ARCH' — set PHOTOCLEANER_ARCH to arm64 or x86_64" >&2
        exit 1
        ;;
esac
TARGET="${ARCH}-apple-macosx${DEPLOYMENT_TARGET}"

# The version stamped into CFBundleShortVersionString/CFBundleVersion. It is the
# version ./photo-cleaner --version prints, because the app reads it back out of
# its own Info.plist rather than carrying a second copy — one build, one truth.
#
# Local builds take the default. The release workflow passes the pushed tag, so
# tagging v1.2.3 and building it yields a 1.2.3 app. Apple's format for both keys
# is up to three integers separated by dots, so "1.2.3-rc1" is refused here
# rather than shipped as a bundle macOS will not accept.
VERSION="${PHOTOCLEANER_VERSION:-1.0.0}"
if ! printf '%s' "$VERSION" | grep -qE '^[0-9]+(\.[0-9]+){0,2}$'; then
    echo "build: invalid PHOTOCLEANER_VERSION '$VERSION' — expected N, N.N or N.N.N" >&2
    exit 1
fi

# Resolve the compiler and the SDK from the same Apple developer directory.
# Bare `swift`/`swiftc` are whatever PATH finds first; a Homebrew or Swift.org
# toolchain shadowing the system one pairs a foreign compiler with this Mac's
# SDK, which is what produces "this SDK is not supported by the compiler" (and
# the "redefinition of module 'SwiftBridging'" noise that comes with it).
if ! command -v xcrun >/dev/null 2>&1; then
    echo "build: xcrun not found — install the Xcode Command Line Tools (xcode-select --install)" >&2
    exit 1
fi
if ! SWIFT="$(xcrun --find swift 2>/dev/null)" \
   || ! SWIFTC="$(xcrun --find swiftc 2>/dev/null)" \
   || ! SDK="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null)"; then
    echo "build: no usable Swift toolchain — install the Xcode Command Line Tools (xcode-select --install)" >&2
    exit 1
fi

BUILD_LOG="$(mktemp -t photocleaner-build)"
trap 'rm -f "$BUILD_LOG"' EXIT

# A toolchain/SDK mismatch is environmental, and swiftc reports it as a wall of
# module errors that buries the cause. Recognise the signature and say what to do.
diagnose_swift_failure() {
    grep -qE "SDK is not supported by the compiler|redefinition of module 'SwiftBridging'" "$1" || return 0
    cat >&2 <<EOF

build: the Swift toolchain and the macOS SDK on this Mac do not match.

  compiler: $SWIFTC
            $("$SWIFTC" --version 2>&1 | sed -n '1{s/^swift-driver version: [^ ]* //;p;}')
  SDK:      $SDK

This is a broken or partially updated Xcode Command Line Tools installation, not
a problem with PhotoCleaner. To repair it:

  1. Reinstall the Command Line Tools. \`xcode-select --install\` can itself fetch
     a mismatched build, so prefer the matching "Command Line Tools for Xcode"
     .dmg from https://developer.apple.com/download/all/ :

       sudo rm -rf /Library/Developer/CommandLineTools
       # then install the .dmg, or: xcode-select --install

  2. Or install Xcode and point the tools at it:

       sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

EOF
}

echo "==> Embedding the web UI"
if ! "$SWIFT" -sdk "$SDK" "$ROOT/tools/embed-web.swift" "$ROOT/web" "$GENERATED" 2>&1 | tee "$BUILD_LOG"; then
    diagnose_swift_failure "$BUILD_LOG"
    echo "build: embedding the web UI failed" >&2
    exit 1
fi

echo "==> Compiling for $TARGET"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SOURCES=()
while IFS= read -r file; do
    SOURCES+=("$file")
done < <(find "$ROOT/Sources" -name '*.swift' | sort)

if [ "${#SOURCES[@]}" -eq 0 ]; then
    echo "build: no Swift sources found" >&2
    exit 1
fi

# Link to a temporary path and move it into place only on success, so a failed
# or interrupted link can never leave a half-written executable behind for
# ./photo-cleaner to run.
STAGED="$BINARY.staged"
rm -f "$STAGED"

# -warnings-as-errors: the project compiles clean, and keeping it that way is
# worth more than the occasional papercut from a future SDK.
if ! "$SWIFTC" \
    -O \
    -swift-version 6 \
    -target "$TARGET" \
    -sdk "$SDK" \
    -warnings-as-errors \
    "${SOURCES[@]}" \
    -o "$STAGED" 2>&1 | tee "$BUILD_LOG"; then
    diagnose_swift_failure "$BUILD_LOG"
    echo "build: compilation failed; the previously built app is untouched" >&2
    rm -f "$STAGED"
    exit 1
fi

if [ ! -x "$STAGED" ]; then
    echo "build: swiftc reported success but produced no executable" >&2
    rm -f "$STAGED"
    exit 1
fi

mv -f "$STAGED" "$BINARY"

echo "==> Writing the bundle"
# The icon is drawn from code, not copied from a checked-in blob: see
# tools/make-icon.swift. A failure here is not fatal to the build — an app
# without an icon still runs, it just shows the generic one — but it is worth
# saying out loud rather than silently shipping.
echo "==> Drawing the icon"
ICON="$APP/Contents/Resources/AppIcon.icns"
rm -f "$ICON"
if ! "$SWIFT" -sdk "$SDK" "$ROOT/tools/make-icon.swift" "$ICON" 2>&1 | tee "$BUILD_LOG"; then
    diagnose_swift_failure "$BUILD_LOG"
    echo "build: could not render the icon; it will be the generic macOS one" >&2
    rm -f "$ICON"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>PhotoCleaner</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.alastorid.photocleaner</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>PhotoCleaner</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.photography</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSPhotoLibraryUsageDescription</key>
    <string>PhotoCleaner reads your photo library to score photos with Apple's on-device aesthetics model, so you can review and delete them yourself. Nothing leaves this Mac.</string>
    <!-- The window is a WKWebView loading http://127.0.0.1:<port>. App Transport
         Security applies to a hosted web view but not to a page typed into
         Safari, so this is what stops the window's own interface from being
         blocked. NSAllowsLocalNetworking is the narrow key: loopback and .local
         only, not a blanket NSAllowsArbitraryLoads. -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

# Stamp the version. The heredoc above carries the same two keys with the
# default value so the file is complete on its own; these two lines are what
# makes PHOTOCLEANER_VERSION take effect. Set (not Add) on purpose: a key the
# heredoc dropped should fail the build, not silently reappear here.
echo "==> Stamping version $VERSION"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

# Read the versions back rather than trusting the writes: a bundle whose
# Info.plist disagrees with the version being released is exactly the kind of
# thing that is only noticed by a user, months later.
for key in CFBundleShortVersionString CFBundleVersion; do
    STAMPED="$(/usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist" 2>/dev/null)"
    if [ "$STAMPED" != "$VERSION" ]; then
        echo "build: $key is '$STAMPED' after stamping, expected '$VERSION'" >&2
        exit 1
    fi
done

# Ad-hoc signature. Not required to run, but a signed bundle gets a stable
# identity for the Photos permission prompt.
echo "==> Signing (ad-hoc)"
codesign --force --sign - "$APP" 2>&1 | sed 's/^/    /'

echo
echo "Built $APP"
echo "  version $VERSION, $ARCH"
echo "Run it with ./photo-cleaner"
