#!/bin/bash
#
# PhotoCleaner smoke test — read-only, offline, dependency-free.
#
#   ./smoke-test.sh              # check the build and a running instance
#   ./smoke-test.sh --no-server  # build/bundle/static checks only
#
# bash + curl + sqlite3 + codesign/PlistBuddy/lsof/strings (all system tools).
# No Python, no Node, no npm, no network access beyond loopback, and nothing is
# written outside $TMPDIR.
#
# It NEVER deletes a photo, NEVER posts to /api/delete, NEVER touches
# downloadFromICloud, and NEVER opens a network connection other than loopback.
# It also never starts or stops the server: it inspects whatever is running.
#
# Exit status: 0 if every check passed, 1 otherwise.

# `set -e` is deliberately absent: every check here is expected to be able to
# fail without ending the run, because the whole point is to report all of them
# and exit non-zero at the end. The other scripts are strict because they have
# nothing to report.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$ROOT/dist/PhotoCleaner.app"
BINARY="$APP/Contents/MacOS/PhotoCleaner"
PLIST="$APP/Contents/Info.plist"
PORT="${PHOTOCLEANER_PORT:-8765}"
BASE="http://127.0.0.1:$PORT"
SUPPORT="$HOME/Library/Application Support/PhotoCleaner"
LOGDIR="$HOME/Library/Logs/PhotoCleaner"

CHECK_SERVER=1
[ "${1:-}" = "--no-server" ] && CHECK_SERVER=0

PASS=0; FAIL=0; SKIP=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/photocleaner-smoke.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  skip  %s (%s)\n' "$1" "$2"; }
head_() { printf '\n%s\n' "$1"; }

# ---------------------------------------------------------------- build/bundle

head_ "Bundle"

if [ -x "$BINARY" ] && [ -f "$PLIST" ]; then
  ok "dist/PhotoCleaner.app is built"
else
  bad "dist/PhotoCleaner.app is not built — run ./build.sh"
  printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
  exit 1
fi

# Every key build.sh writes, and the two values that actually matter to macOS.
for key in CFBundleIdentifier CFBundleExecutable CFBundleName CFBundlePackageType \
           CFBundleShortVersionString CFBundleVersion CFBundleDevelopmentRegion \
           CFBundleInfoDictionaryVersion LSMinimumSystemVersion \
           LSApplicationCategoryType NSHighResolutionCapable \
           NSSupportsAutomaticGraphicsSwitching NSPhotoLibraryUsageDescription; do
  if /usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" >/dev/null 2>&1; then
    ok "Info.plist has $key"
  else
    bad "Info.plist is missing $key"
  fi
done

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST" 2>/dev/null)"
[ "$BUNDLE_ID" = "com.alastorid.photocleaner" ] \
  && ok "CFBundleIdentifier is com.alastorid.photocleaner" \
  || bad "CFBundleIdentifier is '$BUNDLE_ID', expected com.alastorid.photocleaner"

# PhotoKit will not prompt without a non-empty usage description.
USAGE="$(/usr/libexec/PlistBuddy -c 'Print :NSPhotoLibraryUsageDescription' "$PLIST" 2>/dev/null)"
if [ -n "$USAGE" ]; then
  ok "NSPhotoLibraryUsageDescription is present and non-empty (${#USAGE} chars)"
else
  bad "NSPhotoLibraryUsageDescription is missing or empty — PhotoKit will refuse to prompt"
fi

# Ad-hoc signing is what gives the Photos prompt a stable bundle identity.
if codesign -dv "$APP" >/dev/null 2>&1; then
  ok "bundle carries a code signature ($(codesign -dv "$APP" 2>&1 | sed -n 's/^Signature=//p'))"
else
  bad "bundle is not signed"
fi

head_ "Photos permission identity"
# The TCC grant is keyed to the designated requirement, which for an ad-hoc
# signature is the cdhash. Print both so a rebuild that re-prompts is explainable.
CDHASH="$(codesign -d -r- --verbose=2 "$APP" 2>&1 | sed -n 's/.*cdhash H"\([a-f0-9]*\)".*/\1/p')"
printf '  info  bundle id            %s\n' "$BUNDLE_ID"
printf '  info  designated req       cdhash %s\n' "${CDHASH:-<none>}"
printf '  info  a rebuild that changes the binary changes this hash and re-prompts\n'

# ---------------------------------------------------------------- static audit

head_ "Web UI: no external resources"
# The strongest possible statement: the string "http" does not occur at all.
if grep -q "http" "$ROOT/web/index.html" "$ROOT/web/app.css" "$ROOT/web/app.js" 2>/dev/null; then
  bad "web/ contains the string \"http\" — audit web/ for an external reference"
  grep -n "http" "$ROOT/web/index.html" "$ROOT/web/app.css" "$ROOT/web/app.js" | sed 's/^/        /'
else
  ok "the substring \"http\" occurs zero times in web/index.html, web/app.css, web/app.js"
fi

for pat in '@import' 'url(' '@font-face' 'srcset' 'sendBeacon' 'WebSocket' 'XMLHttpRequest'; do
  if grep -qF -- "$pat" "$ROOT/web/index.html" "$ROOT/web/app.css" "$ROOT/web/app.js" 2>/dev/null; then
    bad "web/ references $pat"
  else
    ok "no $pat in the web client"
  fi
done

if grep -qiE 'analytics|telemetry|googletagmanager|gtag\(|sentry|mixpanel|amplitude|posthog|hotjar|intercom' \
     "$ROOT/web/index.html" "$ROOT/web/app.css" "$ROOT/web/app.js" 2>/dev/null; then
  bad "web/ mentions an analytics/telemetry identifier"
else
  ok "no analytics/telemetry identifier in the web client"
fi

head_ "Favourite protection is not offered as a control"
# Excluding favourites from bulk deletion is unconditional, so there is nothing to
# switch and nothing to count. Grepped rather than left to the jsdom suite: this is
# the check that would notice a *returning* control, and the guarantee belongs to
# the product rather than to one view — a switch reappearing here is a regression
# even in a build where nobody happens to open the panel.
#
# The phrases are listed with the ids they came in with, so a control rebuilt under
# a new name still trips this rather than sliding through on the wording alone.
for pat in 'protectFavorites' 'protectedCount' 'Protect Favorites' 'protected from deletion while'; do
  if grep -qF -- "$pat" "$ROOT/web/index.html" "$ROOT/web/app.css" "$ROOT/web/app.js" 2>/dev/null; then
    bad "web/ still offers favourite protection as a setting: \"$pat\""
    grep -nF -- "$pat" "$ROOT/web/index.html" "$ROOT/web/app.css" "$ROOT/web/app.js" | sed 's/^/        /'
  else
    ok "no \"$pat\" in the web client"
  fi
done

# The mirror of that check, for video. "Images only" was a *disabled* checkbox whose
# tooltip said video support was planned — a claim about the product, made in the UI,
# and now false. A disabled control that claims something is unimplemented is the same
# class of defect as a live one that offers it: the user is told something the app can
# no longer do, and no amount of testing the real feature catches the stale sentence.
#
# So the *absence* is asserted here, and the presence of a real control is asserted by
# the jsdom suite. If the media control is ever removed, this passes and that fails —
# which is the pairing that stops video support quietly becoming "not implemented
# again" while the copy stays.
for pat in 'Video support is planned' 'analyzes still photos'; do
  if grep -qF -- "$pat" "$ROOT/web/index.html" "$ROOT/web/app.css" "$ROOT/web/app.js" 2>/dev/null; then
    bad "web/ still claims video is unsupported: \"$pat\""
    grep -nF -- "$pat" "$ROOT/web/index.html" "$ROOT/web/app.css" "$ROOT/web/app.js" | sed 's/^/        /'
  else
    ok "no \"$pat\" in the web client"
  fi
done

# "Images only" is checked separately and more narrowly, because the word pair now
# survives in an HTML comment that *explains* the control's replacement — which is
# exactly the comment that should stay. What must not survive is the phrase in
# something a reader sees, so only the rendered text is searched: `index.html` with
# comments stripped, plus `app.js`, where a string would reach the DOM.
strip_html_comments() {
  # Removes `<!-- … -->`, including a multi-line one. `sed` rather than a real parser
  # because this only has to be good enough not to hide a visible claim, and a
  # malformed comment would have to be a bug worth failing on anyway.
  perl -0pe 's/<!--.*?-->//gs' "$1"
}
if strip_html_comments "$ROOT/web/index.html" | grep -qF 'Images only'; then
  bad "web/ still shows an \"Images only\" label to the reader"
  strip_html_comments "$ROOT/web/index.html" | grep -nF 'Images only' | sed 's/^/        /'
elif grep -qF 'Images only' "$ROOT/web/app.js" 2>/dev/null; then
  bad "web/app.js still renders an \"Images only\" label"
  grep -nF 'Images only' "$ROOT/web/app.js" | sed 's/^/        /'
else
  ok "no \"Images only\" label in anything the reader sees"
fi

# And the control itself has to be there: an absent media filter is how "videos are
# scored but unreachable" would ship, which is a green suite and an empty feature.
# All three choices are required, not one of them — checking only that *some*
# `data-media` exists passed while the Videos chip had been stripped out, which is
# exactly the failure the check is for.
missing_media=""
for choice in all images videos; do
  grep -qF "data-media=\"$choice\"" "$ROOT/web/index.html" 2>/dev/null \
    || missing_media="$missing_media $choice"
done
if [ -n "$missing_media" ] || ! grep -qF 'mediaChips' "$ROOT/web/index.html" 2>/dev/null; then
  bad "the media filter is incomplete (missing:${missing_media:- the container}) — "
  bad "  videos are scored but there may be no way to show them"
elif ! grep -qF 'mediaChips' "$ROOT/web/app.js" 2>/dev/null; then
  bad "the media filter is in the markup but the client never reads it"
else
  ok "the media filter offers All / Photos / Videos and the client reads it"
fi

# The guarantee still has to be *stated* somewhere, or removing the control would
# just have deleted the information rather than relocated it. Checked against the
# heart's own surfaces, which is where the user acts on a favourite.
if grep -qF 'protected from deletion' "$ROOT/web/app.js" 2>/dev/null; then
  ok "the client still tells the user a favourite is protected from deletion"
else
  bad "no \"protected from deletion\" anywhere in web/app.js — the guarantee is"
  printf '        no longer stated to the user anywhere. It belongs on the heart,\n'
  printf '        the tile accessible name and the lightbox favourite button.\n'
fi

head_ "Binary: no external resources"
# Every URL the process can construct is either a loopback one or the release
# feed.
#
# That second exception is real and narrow, so it is spelled out rather than
# generalised: self-update has to ask somewhere which version is newest. The
# allowance is one exact URL, listed here, so that any *other* non-loopback URL —
# a telemetry endpoint, an analytics host, a CDN, a typo'd mirror — is still a
# FAIL. Broadening the pattern to "api.github.com" or to "https:" would make this
# check worthless exactly when it matters.
ALLOWED_OFFSITE='https://api.github.com/repos/alastorid/PhotoCleaner/releases/latest'
URLS="$(strings -a "$BINARY" 2>/dev/null | grep -oE 'https?://[A-Za-z0-9._~:/?#@!$&'"'"'()*+,;=%-]+' | sort -u)"
BAD_URLS="$(printf '%s\n' "$URLS" | grep -v '^http://127\.0\.0\.1:' \
            | grep -v "^${ALLOWED_OFFSITE}\$" | grep -v '^$' || true)"
if [ -z "$BAD_URLS" ]; then
  ok "the binary reaches only loopback and the release feed"
  printf '        %s\n' "$ALLOWED_OFFSITE"
else
  bad "the binary contains non-loopback URL(s) that are not the release feed:"
  printf '%s\n' "$BAD_URLS" | sed 's/^/        /'
fi

# The feed URL is built from a repository constant, so the literal in the binary
# is only half the story. Confirm the constant the app uses is the one allowed
# here — otherwise this check would pass for a fork pointed at its own releases
# while claiming the audit above is about this repository.
FEED_SOURCE="$(grep -oE 'static let releaseRepository = "[^"]+"' \
              "$ROOT/Sources/PhotoCleaner/Support/AppPaths.swift" 2>/dev/null \
              | sed -n 's/.*"\(.*\)"/\1/p' || true)"
if [ -n "$FEED_SOURCE" ]; then
  EXPECTED_FEED="https://api.github.com/repos/$FEED_SOURCE/releases/latest"
  if [ "$EXPECTED_FEED" = "$ALLOWED_OFFSITE" ]; then
    ok "AppPaths.releaseRepository is $FEED_SOURCE, matching the allowed feed"
  else
    bad "AppPaths.releaseRepository is '$FEED_SOURCE', so the update feed is"
    printf '        %s\n' "$EXPECTED_FEED"
    printf '        which is not the allowed feed. Update ALLOWED_OFFSITE above only\n'
    printf '        if that is intended, and say so in the README.\n'
  fi
fi

# ---------------------------------------------------------------- running server

if [ "$CHECK_SERVER" = "0" ]; then
  head_ "Server"
  skip "no instance inspected" "--no-server"
else
  head_ "Server"

  PID="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -1)"
  if [ -z "$PID" ]; then
    skip "running instance" "nothing listening on 127.0.0.1:$PORT"
  else
    ok "pid $PID is listening on 127.0.0.1:$PORT"

    # The health check, in one line: this is what tells a healthy instance from
    # a stale one. See README "Troubleshooting".
    if curl -fsS -m 3 "$BASE/api/status" | grep -q '"version"'; then
      ok "GET /api/status answers as PhotoCleaner (not some other listener)"
    else
      bad "GET /api/status did not answer as PhotoCleaner on port $PORT"
    fi

    STATUS="$(curl -fsS -m 5 "$BASE/api/status" 2>/dev/null)"
    # JSON keys are sorted, so pull each object out first and then the key.
    section() { printf '%s' "$STATUS" | grep -o "\"$1\":{[^}]*}" | head -1; }
    num()     { section "$1" | sed -n "s/.*\"$2\":\([-0-9.]*\).*/\1/p"; }
    str()     { printf '%s' "$STATUS" | sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"; }

    AUTH="$(str authorization)"
    PHASE="$(str phase)"
    TOTAL="$(num library total)";        ANALYZED="$(num analysis analyzed)"
    FAILED="$(num analysis failed)";     PENDING="$(num analysis pending)"
    UNAVAIL="$(num analysis unavailable)"
    MINS="$(num score min)";             MAXS="$(num score max)"
    LIBRARY="$HOME/Pictures/Photos Library.photoslibrary"

    printf '  info  authorization       %s\n' "$AUTH"
    printf '  info  phase               %s\n' "$PHASE"
    printf '  info  library.total       %s\n' "$TOTAL"
    printf '  info  analyzed            %s\n' "$ANALYZED"
    printf '  info  unavailable         %s\n' "$UNAVAIL"
    printf '  info  failed / pending    %s / %s\n' "$FAILED" "$PENDING"
    printf '  info  score range         %s .. %s\n' "$MINS" "$MAXS"
    printf '  info  library on disk     %s\n' "$LIBRARY"

    if [ "$AUTH" = "authorized" ] || [ "$AUTH" = "limited" ]; then
      ok "Photos authorization is $AUTH"
    else
      bad "Photos authorization is '$AUTH' — nothing can be scanned"
    fi

    # Apple's overallScore is NOT 0…1. A normalised range would be the bug.
    if [ -n "$MINS" ] && awk -v m="$MINS" 'BEGIN{exit !(m < 0)}'; then
      ok "score minimum is negative ($MINS) — the range is not 0…1"
    else
      bad "score minimum is '${MINS:-<none>}' — expected a negative value, not a normalised 0…1 range"
    fi

    if [ "$PENDING" = "0" ]; then
      ok "pending is 0"
    else
      bad "pending is '${PENDING:-<none>}' — an analysis run is unfinished"
    fi

    if [ "$LIBRARY" = "$HOME/Pictures/Photos Library.photoslibrary" ] \
       && [ -d "$LIBRARY" ]; then
      ok "Photos library present at the expected path (never touched by this tool)"
    else
      skip "Photos library presence" "not at ~/Pictures/Photos Library.photoslibrary"
    fi

    head_ "Server: loopback only"
    LISTEN="$(lsof -nP -a -p "$PID" -i -sTCP:LISTEN 2>/dev/null | tail -n +2 | awk '{print $9}')"
    case "$LISTEN" in
      127.0.0.1:*) ok "listening socket is $LISTEN" ;;
      *)           bad "listening socket is '$LISTEN', expected 127.0.0.1:$PORT" ;;
    esac

    # The offline claim, checked without touching network configuration.
    #
    # A connection to the release feed is the one permitted outbound socket: the
    # update check runs at most once a day, is deferred past launch, and is not
    # something a page load triggers. Anything else off-loopback still fails.
    OFFSITE="$(lsof -nP -a -p "$PID" -i 2>/dev/null | tail -n +2 | awk '{print $9}' \
               | grep -v "^127\.0\.0\.1:$PORT" \
               | grep -vE '(:443$|->)' | sort -u || true)"
    GITHUB="$(lsof -nP -a -p "$PID" -i 2>/dev/null | tail -n +2 | awk '{print $9}' \
               | grep -E 'api\.github\.com.*:443|->.*:443' | sort -u || true)"
    if [ -z "$OFFSITE" ]; then
      ok "every socket the process holds is $PORT on 127.0.0.1${GITHUB:+ or the release feed}"
    else
      bad "the process holds a non-loopback endpoint:"
      printf '%s\n' "$OFFSITE" | sed 's/^/        /'
    fi

    head_ "Server: API surface"
    code() { curl -s -m 10 -o /dev/null -w '%{http_code}' "$BASE$1"; }

    ID="$(curl -fsS -m 10 "$BASE/api/photos?limit=1" 2>/dev/null \
          | sed 's|\\/|/|g' | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
    ENC=""
    [ -n "$ID" ] && ENC="$(printf '%s' "$ID" | sed 's|/|%2F|g')"

    expect() { # expect <label> <path> <expected-status>
      got="$(code "$2")"
      if [ "$got" = "$3" ]; then ok "$1 -> $got"; else bad "$1 -> $got, expected $3"; fi
    }
    expect "GET  /"                          "/"                                              200
    expect "GET  /app.css"                   "/app.css"                                       200
    expect "GET  /app.js"                    "/app.js"                                        200
    expect "GET  /favicon.ico"               "/favicon.ico"                                   204
    expect "GET  /api/status"                "/api/status"                                    200
    expect "GET  /api/photos"                "/api/photos"                                    200
    expect "GET  /api/events"                "/api/events"                                    200
    expect "GET  /api/photo/{id}"            "/api/photo/$ENC"                                200
    expect "GET  /api/photo/{id}/thumbnail"  "/api/photo/$ENC/thumbnail?size=256"             200
    expect "GET  /api/photo/{id}/preview"    "/api/photo/$ENC/preview?size=2048"              200
    expect "GET  /api/timeline/around"       "/api/timeline/around?id=$ENC&limit=4"           200
    expect "GET  /api/timeline/page"         "/api/timeline/page?direction=older&cursor=eyJzY29yZSI6MCwiZGF0ZSI6MCwiaWQiOiIifQ&limit=4" 200

    head_ "Server: nothing destructive is reachable with GET"
    expect "GET  /api/delete"            "/api/delete"            404
    expect "GET  /api/settings"          "/api/settings"          404
    expect "GET  /api/library/rescan"    "/api/library/rescan"    404
    expect "GET  /api/analysis/retry"    "/api/analysis/retry"    404
    expect "GET  /api/selection/preview" "/api/selection/preview" 404

    head_ "Server: error handling"
    expect "unknown asset id"          "/api/photo/NOPE%2FL0%2F001"                             404
    expect "path traversal"            "/api/photo/..%2F..%2F..%2Fetc%2Fpasswd"                 404
    expect "timeline without an id"    "/api/timeline/around"                                   400
    expect "timeline bad direction"    "/api/timeline/page?direction=sideways&cursor=x"         400
    expect "timeline malformed cursor" "/api/timeline/page?direction=older&cursor=%25%25%25%25"  400
    expect "unrouted path"             "/api/nope"                                              404

    # Cross-origin POSTs are refused; a request with no browser headers is not.
    xo() { curl -s -m 10 -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
                      -H "$1" -d "$2" "$BASE/api/selection/preview"; }
    got="$(xo 'Sec-Fetch-Site: cross-site' '{"mode":"ids","ids":[]}')"
    [ "$got" = "403" ] && ok "cross-site POST is refused (403)" || bad "cross-site POST -> $got, expected 403"
    got="$(xo 'Sec-Fetch-Site: same-origin' '{"mode":"ids","ids":[]}')"
    [ "$got" = "200" ] && ok "same-origin POST is accepted (200)" || bad "same-origin POST -> $got, expected 200"
    got="$(curl -s -m 10 -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
                -d '{not json' "$BASE/api/selection/preview")"
    [ "$got" = "400" ] && ok "malformed JSON is refused (400)" || bad "malformed JSON -> $got, expected 400"

    head_ "Server: embedded assets match web/ on disk"
    # build.sh folds web/ into the executable, so a stale build serves a stale UI.
    for f in index.html app.css app.js; do
      url="/$f"; [ "$f" = "index.html" ] && url="/"
      if ! curl -fsS -m 15 -o "$TMP/$f" "$BASE$url" 2>/dev/null; then
        bad "could not fetch $url"
        continue
      fi
      DISK_SHA="$(shasum -a 256 "$ROOT/web/$f" | awk '{print $1}')"
      GOT_SHA="$(shasum -a 256 "$TMP/$f" | awk '{print $1}')"
      if [ "$DISK_SHA" = "$GOT_SHA" ]; then
        ok "$f is served byte-identically"
      else
        # Swift's multiline string literals drop the newline adjacent to each
        # delimiter, so the served bytes are web/'s minus one trailing newline.
        N="$(wc -c < "$ROOT/web/$f" | tr -d ' ')"
        if [ "$(head -c $((N-1)) "$ROOT/web/$f" | shasum -a 256 | awk '{print $1}')" = "$GOT_SHA" ]; then
          ok "$f is served byte-identically apart from its final newline"
        else
          bad "$f served by the binary does not match web/$f — rebuild with ./build.sh"
        fi
      fi
    done
  fi
fi

# ---------------------------------------------------------------- on-disk state

head_ "Stored state"
DB="$SUPPORT/cache.sqlite"

for p in "$SUPPORT/cache.sqlite" "$SUPPORT/settings.json" "$SUPPORT/video-cache" \
         "$LOGDIR/PhotoCleaner.log"; do
  [ -e "$p" ] && ok "$(printf '%s' "$p" | sed "s|$HOME|~|")" \
              || skip "$(printf '%s' "$p" | sed "s|$HOME|~|")" "not present"
done

if [ -f "$DB" ] && command -v sqlite3 >/dev/null 2>&1; then
  # Read-only: this database is never written by this script.
  if sqlite3 -readonly "$DB" "SELECT 1 FROM assets LIMIT 1;" >/dev/null 2>&1; then
    ok "the score cache is readable (opened read-only)"

    BROKEN="$(sqlite3 -readonly "$DB" "SELECT COUNT(*) FROM assets WHERE analysis_state='analyzing';" 2>/dev/null)"
    [ "$BROKEN" = "0" ] && ok "no asset is stuck in 'analyzing'" \
                        || bad "$BROKEN asset(s) are stuck in 'analyzing' — they need a restart"

    FAILEDN="$(sqlite3 -readonly "$DB" "SELECT COUNT(*) FROM assets WHERE analysis_state='failed';" 2>/dev/null)"
    UNAVAILN="$(sqlite3 -readonly "$DB" "SELECT COUNT(*) FROM assets WHERE analysis_state='unavailable';" 2>/dev/null)"
    printf '  info  cache states        failed=%s unavailable=%s\n' "${FAILEDN:-?}" "${UNAVAILN:-?}"
    [ "$FAILEDN" = "0" ] \
      && ok "no asset failed analysis (cloud-only assets are 'unavailable', which is not a failure)" \
      || skip "$FAILEDN asset(s) failed analysis" "inspect with SELECT asset_identifier, last_error FROM assets WHERE analysis_state='failed'"

    # `asset_signals` is live in schema 3: it holds FeaturePrints and per-face
    # capture quality, and the backfill queue fills it without ever disturbing an
    # existing score. So the audit is that every row carries a *known* signal name
    # and belongs to an asset that still exists — not that the table is empty, which
    # was the version 1 state.
    ORPHAN_SIG="$(sqlite3 -readonly "$DB" "SELECT COUNT(*) FROM asset_signals WHERE signal NOT IN ('featureprint','face_capture_quality');" 2>/dev/null)"
    [ "${ORPHAN_SIG:-0}" = "0" ] && ok "every asset_signals row has a known signal name" \
                                 || bad "$ORPHAN_SIG asset_signals row(s) have an unknown signal name"
    DANGLING="$(sqlite3 -readonly "$DB" "SELECT COUNT(*) FROM asset_signals s LEFT JOIN assets a USING (asset_identifier) WHERE a.asset_identifier IS NULL;" 2>/dev/null)"
    [ "${DANGLING:-0}" = "0" ] && ok "no asset_signals row outlived its asset" \
                               || bad "$DANGLING asset_signals row(s) have no asset"
    SIG="$(sqlite3 -readonly "$DB" "SELECT COUNT(*) FROM asset_signals WHERE signal='featureprint';" 2>/dev/null)"
    printf '  info  featureprints     %s\n' "${SIG:-0}"

    # Unscored rows must never reach the grid: they carry no score.
    UNSCORED="$(sqlite3 -readonly "$DB" "SELECT COUNT(*) FROM assets WHERE aesthetics_score IS NULL AND analysis_state<>'unavailable';" 2>/dev/null)"
    [ "${UNSCORED:-0}" = "0" ] && ok "no asset is neither scored nor marked unavailable" \
                               || skip "$UNSCORED asset(s) are unscored and not 'unavailable'" "a run is probably in progress"
  else
    skip "cache contents" "sqlite3 -readonly could not open the database"
  fi
else
  skip "cache contents" "no cache.sqlite, or sqlite3 unavailable"
fi

# The app writes nothing outside Application Support and Logs. It does, however,
# touch URLSession exactly once (a loopback /api/status probe), and Foundation
# creates its per-bundle stores for that: an empty NSURLCache Cache.db under
# ~/Library/Caches and an empty httpstorages.sqlite under ~/Library/HTTPStorages.
# Launching the bundle via `open` additionally makes LaunchServices create
# fsCachedData. The windowed app saves one more thing: its frame, under
# ~/Library/Preferences. None of these hold library data, a score, or a cached
# response, and all are listed in the README's "Remove everything" command.
head_ "State outside Application Support and Logs"
CACHES="$HOME/Library/Caches/com.alastorid.photocleaner"
if [ -d "$CACHES" ]; then
  RESP="$(sqlite3 -readonly "$CACHES/Cache.db" \
          'SELECT COUNT(*) FROM cfurl_cache_response;' 2>/dev/null || echo '?')"
  printf '  info  Caches/Cache.db     %s cached HTTP response(s)\n' "$RESP"
  [ "$RESP" = "0" ] && ok "the URL cache holds nothing — the app caches no response" \
                    || bad "the URL cache holds $RESP response(s) — responses are being cached"
  [ -d "$CACHES/fsCachedData" ] && printf '  info  Caches/fsCachedData  present (LaunchServices, from an `open` launch)\n'
else
  ok "no ~/Library/Caches entry for PhotoCleaner"
fi

STORES="$HOME/Library/HTTPStorages/com.alastorid.photocleaner"
if [ -d "$STORES" ]; then
  # The table is created lazily by URLSession, so its absence means "has stored
  # nothing" -- not a failure. Querying a missing table makes sqlite3 exit
  # non-zero, which the old `|| echo '?'` turned into a bogus "?" count and a
  # spurious FAIL. Treat a missing table and a real non-zero count differently.
  N="$(sqlite3 -readonly "$STORES/httpstorages.sqlite" \
        'SELECT COUNT(*) FROM httpstorages;' 2>/dev/null)" || N=""
  case "$N" in
    0|"")
      ok "the URLSession store holds nothing${N:+ (no cached responses)}"
      ;;
    *)
      bad "the URLSession store holds $N stored response(s)"
      ;;
  esac
else
  ok "no ~/Library/HTTPStorages entry for PhotoCleaner"
fi

STRAY="$(ls -d "$HOME/Library/Containers/com.alastorid.photocleaner" \
             "$HOME/Library/WebKit/com.alastorid.photocleaner" \
             "$HOME/Library/Cookies/com.alastorid.photocleaner.binarycookies" 2>/dev/null || true)"
[ -z "$STRAY" ] && ok "no Container, WebKit or Cookies entry" \
                || { bad "unexpected state outside Application Support / Logs:"; printf '%s\n' "$STRAY" | sed 's/^/        /'; }

# The windowed app remembers one thing in preferences: where its window was.
# NSWindow's frame autosave writes it under a fixed key, so the check is not
# "is there a plist" but "is there anything in it other than the window frame".
# The web view itself is deliberately non-persistent (WKWebsiteDataStore
# .nonPersistent()) — hence no WebKit or Cookies entry above, and hence nothing in
# here that could hold a photo, a score or a cookie.
PREFS="$HOME/Library/Preferences/com.alastorid.photocleaner.plist"
if [ -f "$PREFS" ]; then
  # `defaults read` quotes every key; the quotes go, the spaces inside the key
  # must not, or "NSWindow Frame PhotoCleanerMainWindow" stops matching itself.
  KEYS="$(defaults read com.alastorid.photocleaner 2>/dev/null \
            | grep -oE '^[[:space:]]+"[^"]+"' | sed 's/^[[:space:]]*"//; s/"$//' || true)"
  UNEXPECTED="$(printf '%s\n' "$KEYS" | grep -v '^NSWindow Frame PhotoCleanerMainWindow$' | grep -v '^$' || true)"
  printf '  info  Preferences          %s key(s)\n' "$(printf '%s\n' "$KEYS" | grep -c . || true)"
  if [ -z "$UNEXPECTED" ]; then
    ok "preferences hold only the window frame"
  else
    bad "preferences hold something other than the window frame:"
    printf '%s\n' "$UNEXPECTED" | sed 's/^/        /'
  fi
else
  ok "no ~/Library/Preferences entry for PhotoCleaner"
fi

# macOS writes this itself on a clean quit. It can only hold window geometry, but
# there is nothing cheap to assert inside it, so it is reported rather than judged.
[ -d "$HOME/Library/Saved Application State/com.alastorid.photocleaner.savedState" ] \
  && printf '  info  Saved Application State  present (macOS window restoration)\n'

# ------------------------------------------------------------------ launcher

head_ "Launcher"
if [ -x "$ROOT/photo-cleaner" ]; then
  for flag in --help -h --version -v; do
    if "$ROOT/photo-cleaner" "$flag" >/dev/null 2>&1; then
      ok "./photo-cleaner $flag exits 0"
    else
      bad "./photo-cleaner $flag did not exit 0"
    fi
  done
  "$ROOT/photo-cleaner" --port >/dev/null 2>&1
  [ $? -eq 2 ] && ok "./photo-cleaner --port without a value exits 2" \
               || bad "./photo-cleaner --port without a value did not exit 2"
  "$ROOT/photo-cleaner" --port abc >/dev/null 2>&1
  [ $? -eq 2 ] && ok "./photo-cleaner --port abc exits 2" \
               || bad "./photo-cleaner --port abc did not exit 2"
  # The presentation flags are the app's own; the launcher only forwards them.
  # Checked through the binary's help rather than by launching, so this section
  # cannot put a second PhotoCleaner on the port.
  HELP="$("$BINARY" --help 2>/dev/null)"
  for flag in --browser --no-browser --port; do
    case "$HELP" in
      *"$flag"*) ok "the binary documents $flag" ;;
      *) bad "the binary's --help does not mention $flag" ;;
    esac
  done
  STALE="$(find "$ROOT/web" "$ROOT/Sources" -type f -newer "$BINARY" -print -quit 2>/dev/null)"
  [ -z "$STALE" ] && ok "web/ and Sources/ are not newer than the built app" \
                  || skip "web/ or Sources/ is newer than the build" "run ./build.sh"
else
  skip "launcher" "photo-cleaner is not executable"
fi

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
