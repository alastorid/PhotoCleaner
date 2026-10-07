#!/bin/bash
#
# Builds and runs the PhotoCleaner regression suite.
#
# SwiftPM does not work on this machine — `swift package dump-package` fails to link
# `libPackageDescription` even for a three-line manifest — so there is no `swift test`.
# Instead the production sources and the tests are compiled together by `swiftc` into
# one throwaway executable in a temporary directory.
#
# The production sources are compiled *unmodified*: every case in Tests/ calls the
# real functions, so a failure means the real code misbehaved. Only `main.swift` is
# excluded, because Tests/ owns the entry point.
#
# Nothing here needs a network connection, a Photos library, or root, and nothing
# touches the real cache at ~/Library/Application Support/PhotoCleaner or `dist/`.
# The one thing it writes into the tree is the generated web-assets source, which
# build.sh produces too — see the embed step below.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/photocleaner-tests.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT

DEPLOYMENT_TARGET="15.0"
# The same override build.sh takes, and for the same reason: a tag-pinned release
# builds one architecture and should test that architecture rather than whatever
# the runner happens to be.
ARCH="${PHOTOCLEANER_ARCH:-$(uname -m)}"
case "$ARCH" in
    arm64|x86_64) ;;
    *)
        echo "run-tests: unsupported architecture '$ARCH' — set PHOTOCLEANER_ARCH to arm64 or x86_64" >&2
        exit 1
        ;;
esac
TARGET="${ARCH}-apple-macosx${DEPLOYMENT_TARGET}"

# Resolve the compiler through `xcrun` and take its `-sdk` from the same developer
# directory, exactly as build.sh does. A compiler shadowed on PATH (Homebrew,
# Swift.org) paired with the system SDK fails with "this SDK is not supported by the
# compiler", usually alongside a `redefinition of module 'SwiftBridging'`. Resolving
# the two together is what makes that impossible — and it is why a CI runner with a
# second Swift installed cannot silently compile against the wrong SDK.
SDK="$(xcrun --sdk macosx --show-sdk-path)"
SWIFTC="$(xcrun --find swiftc)"
SWIFT="$(xcrun --find swift)"

# `Sources/PhotoCleaner/Web/GeneratedWebAssets.swift` is generated from `web/` and
# is gitignored, so a fresh checkout does not have it — and `WebAssets.swift`
# references the type it defines, so the suite would not compile without it. Fold
# it in here rather than making "run ./build.sh first" an unwritten prerequisite:
# every documented way of running the suite has to work on its own.
#
# Generated into the temporary directory and compiled from there, never written into
# the tree. Two problems with the alternative: `build.sh` writes the same file, so two
# concurrent runs would race each other; and a fresh `cp` stamps an mtime new enough
# that swiftc reports the input as "modified during the build", which it checks by
# re-statting every source once the frontend jobs are in flight. Keeping the copy in
# `$BUILD` makes both impossible. Leaving the tree copy alone is `build.sh`'s job.
echo "==> Embedding the web UI"
GENERATED="$BUILD/GeneratedWebAssets.swift"
"$SWIFT" -sdk "$SDK" "$ROOT/tools/embed-web.swift" "$ROOT/web" "$GENERATED"

SOURCES=("$GENERATED")
while IFS= read -r file; do
    SOURCES+=("$file")
done < <(find "$ROOT/Sources" -name '*.swift' ! -name 'main.swift' \
    ! -path "*/Web/GeneratedWebAssets.swift" | sort)

TESTS=()
while IFS= read -r file; do
    TESTS+=("$file")
done < <(find "$ROOT/Tests" -name '*.swift' | sort)

# Counted separately from $SOURCES, which always begins with the generated assets and
# so can never be empty — the guard has to be about the tree, not the array.
TREE_SOURCES=$((${#SOURCES[@]} - 1))
if [ "$TREE_SOURCES" -eq 0 ]; then
    echo "run-tests: no production sources found under $ROOT/Sources" >&2
    exit 1
fi
if [ "${#TESTS[@]}" -eq 0 ]; then
    echo "run-tests: no test sources found under $ROOT/Tests" >&2
    exit 1
fi

echo "==> Compiling ${#SOURCES[@]} production + ${#TESTS[@]} test sources for $TARGET"
"$SWIFTC" \
    -Onone \
    -swift-version 6 \
    -sdk "$SDK" \
    -target "$TARGET" \
    "${SOURCES[@]}" \
    "${TESTS[@]}" \
    -o "$BUILD/photocleaner-tests" \
    -lsqlite3 \
    -framework AppKit \
    -framework AVFoundation \
    -framework Network \
    -framework Photos \
    -framework Vision \
    -framework WebKit

echo "==> Running"
# Log noise goes to a file rather than into the report; it is only shown if a case
# fails, so a red run is diagnosable and a green one is quiet.
STDERR_LOG="$BUILD/stderr.log"
set +e
"$BUILD/photocleaner-tests" "$@" 2>"$STDERR_LOG"
STATUS=$?
set -e

if [ -s "$STDERR_LOG" ]; then
    echo
    echo "----- stderr from the test process -----"
    cat "$STDERR_LOG"
    echo "--------------------------------------"
fi

exit "$STATUS"