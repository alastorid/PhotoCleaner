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

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/photocleaner-tests.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT

DEPLOYMENT_TARGET="15.0"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macosx${DEPLOYMENT_TARGET}"

# Resolve the compiler through `xcrun` and take its `-sdk` from the same developer
# directory, exactly as build.sh does. A compiler shadowed on PATH (Homebrew,
# Swift.org) paired with the system SDK fails with "this SDK is not supported by the
# compiler", usually alongside a `redefinition of module 'SwiftBridging'`. Resolving
# the two together is what makes that impossible — and it is why a CI runner with a
# second Swift installed cannot silently compile against the wrong SDK.
SDK="$(xcrun --sdk macosx --show-sdk-path)"
SWIFTC="$(xcrun --find swiftc)"

SOURCES=()
while IFS= read -r file; do
    SOURCES+=("$file")
done < <(find "$ROOT/Sources" -name '*.swift' ! -name 'main.swift' | sort)

TESTS=()
while IFS= read -r file; do
    TESTS+=("$file")
done < <(find "$ROOT/Tests" -name '*.swift' | sort)

if [ "${#SOURCES[@]}" -eq 0 ]; then
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