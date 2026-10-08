/* PhotoCleaner — embedded web client.
 *
 * Vanilla ES2020. No build step, no imports, no external requests: every call
 * below goes to the local server over the same origin, so the UI keeps working
 * with the network switched off.
 *
 * Selection model (deliberately unambiguous, see checkpoint §4.9):
 *   mode "ids"      — an explicit set of identifiers, chosen by clicking tiles.
 *   mode "matching" — every photo matching a *snapshot* of the score filter that
 *                     was taken when "Select all matching" was pressed, minus an
 *                     explicit exclusion set. Changing the live filter afterwards
 *                     never changes what will be deleted: the selection is
 *                     flagged stale, deletion is blocked, and the user has to
 *                     either re-snapshot it or clear it explicitly. "All" can
 *                     therefore never silently grow.
 *
 * Deletion is one step. The Delete button — and ⌫, and a tile menu's item, and
 * the lightbox's — sends the current selection straight to `/api/delete`, which
 * is the only caller of that endpoint in the whole file. The selection carries
 * the fingerprint of the set `/api/selection/preview` resolved for it, so a
 * library that changed underneath the button is refused rather than deleted, and
 * the server re-resolves the spec and re-checks favourite protection on the
 * deletion itself, so the number printed in the bar is the number Photos
 * deletes. Nothing is ever removed optimistically.
 *
 * Two views share one selection and one lightbox: the score grid, and "All
 * Photos" — a reverse-chronological window around one photo, grouped by day.
 * All Photos is strictly read-only: it issues GETs, it shares the selection
 * with the grid rather than owning one, and leaving it puts the grid back
 * exactly where it was.
 */
(() => {
  'use strict';

  /* -------------------------------------------------------------- constants */

  const PAGE_SIZE = 60;
  /**
   * Rung on the server's thumbnail ladder (128/256/384/512) asked for per grid.
   * A tile renders at 186…~260 px wide and is square, so 256 covers it on a 2×
   * display without upscaling.
   */
  const THUMB_SIZE = 256;
  /** A group cell is 128 px square, so it asks for the rung above it: a 128 px
   *  image on a 2× display wants 256 device pixels, and the ladder tops out at
   *  512, so this is the smallest rung that is not an upscale. */
  const THUMB_GROUP = 256;
  const PREVIEW_SIZE = 2048;
  /** Both range inputs share this many discrete steps across the observed range. */
  const SLIDER_TICKS = 1000;
  /** §4.12: at most one automatic grid refresh per this many milliseconds… */
  const AUTO_REFRESH_MS = 3000;
  /** …and only while the user is within this many pixels of the top. */
  const AUTO_REFRESH_SCROLL_LIMIT = 200;
  const SELECTION_PREVIEW_DEBOUNCE_MS = 150;
  /** Start fetching the next page this far before the sentinel scrolls into view. */
  const PAGINATION_MARGIN = 600;
  /** Photos per page in each direction of the All Photos window. */
  const ALL_PHOTOS_PAGE = 60;
  /** Same idea, for the two sentinels that bracket the All Photos window. */
  const ALL_PHOTOS_MARGIN = 800;
  /**
   * Groups fetched per pull in the Similar Groups view.
   *
   * This is a network granularity, not a page size — nothing is thrown away after a
   * fetch. The list keeps everything it has loaded and grows at either end, so the
   * only cost of a larger number is the work done for a scroll the reader then does
   * not complete. 24 is about two screens of contact sheet: enough that a fast
   * scroll does not outrun the fetches and stall at a boundary, and not so much that
   * the first paint waits on a long response.
   */
  const GROUPS_PAGE = 24;
  /** How often the group list reloads while a rebuild is running. */
  const GROUPS_POLL_MS = 2000;
  /** The two within-group orders, as the server names them. */
  const GROUP_ORDERS = ['aesthetics', 'best_shot'];
  /**
   * The three media filters, as the server names them, and the vocabulary the
   * media chips are built from — the same job `GROUP_ORDERS` does for the
   * within-group chips.
   *
   * Held as a closed set rather than read off the chips because an
   * unrecognised value is a **400** on the server, not a silent fallback to
   * `all`: `resolveAlbumSelection` already documents why, and a media filter
   * that quietly ignored what it was asked would be the same lie in a new place.
   * Three chips means three clicks a user can make and no more, so the set is
   * checked here rather than trusted from the DOM.
   */
  const MEDIA_CHOICES = ['all', 'images', 'videos'];
  /** `PHAssetMediaType.video` raw value. Stored raw on the wire so a row and the
   *  cache's `assets` table cannot disagree about what an asset is. */
  const MEDIA_TYPE_VIDEO = 2;
  /** How often to re-read the album list *while* an index pass is running. */
  const ALBUM_POLL_MS = 1500;
  const AUTHORIZED_PHASES = ['authorized', 'limited'];

  /* ----------------------------------------------------------------- DOM access */

  const elementCache = new Map();
  /**
   * Fail fast on a typo'd id: a missing element means the markup and this file
   * have drifted apart, which is much harder to debug as a silently inert
   * control than as an exception on the first line that needs it.
   */
  const $ = (id) => {
    let node = elementCache.get(id);
    if (node === undefined) {
      node = document.getElementById(id);
      if (!node) throw new Error('PhotoCleaner: missing element #' + id);
      elementCache.set(id, node);
    }
    return node;
  };

  /* ------------------------------------------------------------------- state */

  const emptySelection = () => ({
    mode: 'ids',
    ids: new Set(),
    excluded: new Set(),
    filter: null,
    resolved: 0,
    protectedFavorites: 0,
    /**
     * Identifiers this client named that the server does not have.
     *
     * Non-zero when a photo has left the library since the page that named it was
     * loaded, which is the one case where the bar's "N photos selected" and the
     * Delete button's count disagree for a reason protection does not explain.
     */
    unknownIdentifiers: 0,
    /**
     * True when the filter matched more assets than one resolution will return.
     *
     * The count is then the ceiling rather than the number of matches, so saying
     * "all N photos match" would be false and the deletion would cover a subset of
     * what the reader was shown. A 200,000-photo library is the only way to reach
     * it, which is exactly why it needs saying rather than assuming.
     */
    truncated: false,
    /**
     * The fingerprint of the candidate set the server resolved for *this*
     * selection, taken from `/api/selection/preview` and sent back on the
     * deletion. A library that changed between the preview the user read and the
     * Delete they pressed is refused rather than deleted — the number they agreed
     * to is the number that gets checked.
     *
     * Empty until the first preview lands, and after one fails; the server treats
     * a missing token as "no confirmation offered" and deletes, which is the same
     * answer a deletion outside the selection model gives.
     */
    confirmToken: '',
  });

  const state = {
    status: null,
    /** Real observed score extremes; the slider maps [min,max] → [0,SLIDER_TICKS]. */
    observed: { min: null, max: null },
    /** True once the user has moved a bound; stops the bounds from following the data. */
    pinned: false,
    lower: 0,
    upper: 0,
    
    sort: 'score_asc',
    /**
     * Media filter: 'all', 'images' or 'videos' — the three values the server
     * accepts on `?media=`.
     *
     * Written by two things, and read by neither of them blindly:
     * `selectMedia` sets it from a click, and `adoptAppliedMedia` overwrites it
     * with the `filter.media` the server echoes back. The second writer is the
     * load-bearing one: the chips render from *this* field, so a client that
     * showed its own request rather than the server's answer would draw "Videos"
     * over a grid of photographs — the one state in which every number on screen
     * is a lie. Exactly the rule the album filter already follows.
     */
    media: 'all',
    /** Album filter: 'all', 'none' (in no album), or an album identifier. */
    album: 'all',
    /** Albums the server has read, plus the indexing state behind them. */
    albums: { list: [], unassigned: 0, indexComplete: false, indexing: false,
              indexed: 0, total: 0, smartAlbums: [], smartAlbumsNote: '',
              loaded: false, error: '' },
    /** Album names per loaded row, from the page response. */
    rowAlbums: new Map(),
    items: [],
    nextCursor: null,
    total: 0,
    loading: false,
    /** Bumped by every reset so a page that arrives late is dropped instead of appended. */
    generation: 0,
    inflightGeneration: -1,
    firstLoadDone: false,
    /** True when the observed range was unusable and has just become usable again. */
    needsFirstPage: false,
    lastAnalyzed: -1,
    lastLibraryTotal: -1,
    lastGridRefresh: 0,
    reloadTimer: null,
    previewTimer: null,
    previewToken: 0,
    serverSettings: null,
    selection: emptySelection(),
    /** True while a deletion is in flight: Delete is inert and cannot be re-pressed. */
    deleting: false,
    lightbox: { open: false, queue: [], index: -1, live: false, allPhotos: false, groups: false, label: '' },
    /** Element focused before an overlay opened, so focus can go back there. */
    returnFocus: null,
    /** Shift-click anchor; invalidated whenever the grid contents change. */
    anchorIndex: -1,
    /**
     * "All Photos": a reverse-chronological window around one photo.
     *
     * `rows` is in *display* order (newest first) with the anchor at
     * `anchorIndex`. Both cursors walk outwards from the anchor's own
     * `(date, id)` sort key, so the neighbours of a photo from 2019 cost the
     * same two indexed queries as one from this morning — nothing ever walks
     * down from the newest photo in the library. The window is deliberately
     * unbounded in both directions, like Photos.
     */
    all: {
      active: false,
      /** Bumped on every open and close, so a late page is dropped, not spliced in. */
      generation: 0,
      anchorId: '',
      anchorRow: null,
      anchorIndex: -1,
      rows: [],
      /** Calendar-day group elements, keyed by day — or by month for older years. */
      groups: new Map(),
      olderCursor: null,
      newerCursor: null,
      olderEnd: false,
      newerEnd: false,
      total: 0,
      loadingOlder: false,
      loadingNewer: false,
      /** Why there is nothing on screen, when there is nothing. */
      note: '',
      /** Where the score grid was, so that Back is lossless. See `closeAllPhotos`. */
      returnScrollY: 0,
      returnFocusId: '',
    },
    /**
     * "Similar Groups": photos that are alternate captures of approximately the
     * same shot.
     *
     * Read-only, like All Photos: it shares the selection with the grid rather than
     * owning one, and Back restores where it was. `order` is the one piece of view
     * state — Aesthetics or Best Shot — and it is a *sort within each group*, never
     * a global ranking and never a recommendation.
     *
     * A group is small (a burst of alternate frames), so the whole list is paginated
     * by group rather than by photo.
     *
     * The view has two modes, and `focusId` is what separates them: empty, it is the
     * list of every group; set, it is the one group a photo belongs to, reached from
     * that photo's context menu. Both render through `buildGroup` and both are sorted
     * by the same control — the second is the first with the list taken away, not a
     * second browser.
     */
    groups: {
      active: false,
      /** Bumped on every open, so a late page is dropped rather than spliced in. */
      generation: 0,
      order: 'aesthetics',
      rows: [],
      /**
       * Server offset of `rows[0]` and of the row after `rows.last`, so the list
       * can grow at **either** end. A window rather than a single page: scrolling
       * pulls in more groups above or below and keeps what is already on screen,
       * which is what makes the strip continuous instead of a run of pages.
       */
      startOffset: 0,
      endOffset: 0,
      total: 0,
      loading: false,
      /** Which end is being filled, for the loading message. */
      loadingAt: '',
      note: '',
      status: null,
      /** The single group on screen; '' for the list of every group. */
      focusId: '',
      /**
       * True when this view was opened for one specific photo rather than for the
       * list — which is *not* the same as `focusId` being set. "This photo has no
       * group" is still an answer about one photo, and it deserves the heading that
       * says so rather than the list's. Kept apart from `focusId` so the two empty
       * states can each own their own message.
       */
      focused: false,
      /** The photo that group was opened for. Marked in the group, and never
       *  selected: "where I came from" and "queued for deletion" are different
       *  states and must not share one. */
      originId: '',
      /** Which view was underneath, so Back returns there rather than always
       *  landing on the grid. Recorded on open because it is a fact about the
       *  moment — the group view is reachable from the grid, from All Photos and
       *  from a group cell in the list, and only the first of those is obvious. */
      returnView: 'grid',
      /** Where the score grid was, so Back is lossless. */
      returnScrollY: 0,
      /** The photo to hand focus back to on the way out, when it is still on
       *  screen. Empty when it has since been deleted or paged away. */
      returnFocusId: '',
      /**
       * The last cell shift-clicked in a strip, so Shift-click selects the range
       * from it. Separate from the grid's own anchor because the two surfaces are
       * independent: a range in one group must not be anchored on a cell the
       * reader last clicked in another, or in the grid underneath.
       */
      anchorIndex: -1,
    },
  };

  /* -------------------------------------------------------------- formatting */

  const fmt = {
    /** Scores are never assumed to be 0…1 and are always shown signed. */
    score(value, digits = 3) {
      if (value === null || value === undefined || !Number.isFinite(Number(value))) return '—';
      const number = Number(value);
      return (number >= 0 ? '+' : '') + number.toFixed(digits);
    },
    count(value) {
      const number = Number(value);
      return (Number.isFinite(number) ? number : 0).toLocaleString();
    },
    date(seconds) {
      if (seconds === null || seconds === undefined) return '—';
      const date = new Date(Number(seconds) * 1000);
      if (Number.isNaN(date.getTime())) return '—';
      return date.toLocaleString(undefined, {
        year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit',
      });
    },
    dateShort(seconds) {
      if (seconds === null || seconds === undefined) return '—';
      const date = new Date(Number(seconds) * 1000);
      if (Number.isNaN(date.getTime())) return '—';
      return date.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
    },
    dimensions(width, height) {
      if (!width || !height) return '—';
      return `${fmt.count(width)} × ${fmt.count(height)}`;
    },
    /**
     * An *estimate of how long a run will take* — the analysis ETA.
     *
     * Words and spaces (`1m 30s`), rounded, and it happily says `45s` for a
     * sub-minute figure. Nothing reads it as a measurement of something real:
     * it is a guess about the future, so the rounded figure is the honest one.
     */
    duration(seconds) {
      if (seconds === null || seconds === undefined || !Number.isFinite(seconds)) return '';
      const total = Math.max(0, Math.round(seconds));
      if (total < 60) return `${total}s`;
      const minutes = Math.floor(total / 60);
      if (minutes < 60) return `${minutes}m ${total % 60}s`;
      return `${Math.floor(minutes / 60)}h ${minutes % 60}m`;
    },
    /**
     * A clip's *length* — `m:ss`, or `h:mm:ss` past an hour.
     *
     * NOT `fmt.duration`, and deliberately a second formatter rather than a mode
     * flag on the first. The two differ in ways that matter: this one is a
     * measurement of a thing that exists (the clip is 3:07 long, and truncating
     * down is what every video player does because rounding *up* would claim a
     * frame the clip does not contain), and it is zero-padded so every badge in
     * a grid is the same width and the digits do not shimmer as you scroll. An
     * ETA that read `0:12` next to a badge that read `12s` for the same twelve
     * seconds would be the worse outcome.
     *
     * Empty string for anything that is not a finite number, so a caller can
     * skip the badge rather than print `0:00` — which would assert that a
     * zero-length video exists, the same lie a stored `duration = 0` would be.
     * Absent is not zero: `duration` is omitted from the row entirely for a
     * still, and a video scanned before this version has no value at all yet.
     */
    mediaDuration(seconds) {
      const number = Number(seconds);
      if (seconds === null || seconds === undefined || !Number.isFinite(number) || number <= 0) return '';
      const total = Math.floor(number);
      const rest = total % 60;
      const minutes = Math.floor(total / 60) % 60;
      const hours = Math.floor(total / 3600);
      const pad = (n) => String(n).padStart(2, '0');
      return hours > 0 ? `${hours}:${pad(minutes)}:${pad(rest)}` : `${minutes}:${pad(rest)}`;
    },
    rate(value) {
      const number = Number(value) || 0;
      if (number <= 0) return 'idle';
      return `${number >= 10 ? Math.round(number) : number.toFixed(1)} photos/sec`;
    },
    plural(count, singular, pluralForm) {
      return count === 1 ? singular : pluralForm;
    },
  };

  /* ---------------------------------------------------------------- transport */

  const api = {
    async get(path) {
      const response = await fetch(path, { cache: 'no-store' });
      if (!response.ok) throw new Error(serverMessage(response, `${response.status} ${response.statusText}`));
      return response.json();
    },
    /** Resolves with the decoded body even on a non-2xx status; never throws. */
    async post(path, body) {
      try {
        const response = await fetch(path, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(body ?? {}),
          cache: 'no-store',
        });
        const payload = await response.json().catch(() => ({}));
        return { ok: response.ok, status: response.status, payload: payload || {} };
      } catch (error) {
        return { ok: false, status: 0, payload: { error: error.message } };
      }
    },
  };

  async function serverMessage(response, fallback) {
    try {
      const payload = await response.json();
      if (payload && typeof payload.error === 'string' && payload.error) return payload.error;
    } catch { /* body was not JSON */ }
    return fallback;
  }

  const thumbURL = (id, size) => `/api/photo/${encodeURIComponent(id)}/thumbnail?size=${size || THUMB_SIZE}`;
  const previewURL = (id) => `/api/photo/${encodeURIComponent(id)}/preview?size=${PREVIEW_SIZE}`;
  /**
   * The streamable bytes of a clip.
   *
   * `encodeURIComponent`, and it is not optional: a `localIdentifier` contains
   * `/`, so an unescaped one arrives split across path segments and the router
   * reassembles it as something else entirely. Same path the thumbnail already
   * takes, for the same reason — one encoding rule for identifiers, not two.
   */
  const videoURL = (id) => `/api/photo/${encodeURIComponent(id)}/video`;

  /**
   * Whether a row describes a video.
   *
   * `mediaType` is *always* on the wire, and this reads it as the closed set it is
   * — 1 is an image, 2 is a video — rather than as "truthy means video" or as a
   * `!== 1` test. Both of those are wrong in the same direction: an unknown value
   * from a future server, or a row whose field the encoder dropped, would be
   * drawn as a `<video>`, and a video-shaped element over a photograph is a worse
   * failure than an absent one. So anything that is not exactly 2 is rendered the
   * way it has always been rendered, and the *duration* is what says whether there
   * is a length to print — never this predicate.
   */
  const isVideoRow = (row) => Boolean(row) && Number(row.mediaType) === MEDIA_TYPE_VIDEO;

  /**
   * What a row *is*, for the tile's tooltip and its accessible name.
   *
   * '' for a still. Naming every photograph "Photo" would put a word in every
   * tooltip in the grid to say nothing, and the grid's whole design is that a
   * tile says as little as it can get away with.
   *
   * A clip says what it is *and* how long it is, because a poster frame is a
   * photograph of one moment and nothing on screen distinguishes it from a
   * still of that moment. When there is no length yet the type is still named
   * and the length is left out, rather than the two being printed together with
   * one of them unknown.
   */
  function mediaSummaryText(row) {
    if (!isVideoRow(row)) return '';
    const duration = fmt.mediaDuration(row.duration);
    return duration ? `Video, ${duration}` : 'Video';
  }

  /* -------------------------------------------------------------------- toast */

  let toastTimer = null;
  function toast(message, kind = 'info') {
    const node = $('toast');
    node.textContent = message;
    node.className = 'toast' + (kind === 'error' ? ' error' : kind === 'warning' ? ' warning' : '');
    node.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { node.hidden = true; }, kind === 'error' ? 9000 : 4800);
  }

  /* ------------------------------------------------------------------- bounds */

  const boundsUsable = () => state.observed.min !== null && state.observed.max !== null;
  const span = () => (boundsUsable() ? state.observed.max - state.observed.min : 0);
  const oneStep = () => (span() > 0 ? span() / SLIDER_TICKS : 0.001);
  const fraction = (value) => (span() > 0 ? (value - state.observed.min) / span() : 0);
  const valueToSlider = (value) => (span() > 0 ? Math.round(fraction(value) * SLIDER_TICKS) : 0);
  /**
   * The end ticks are returned verbatim rather than computed: `min + 1 * span`
   * lands one ulp below `max` for about a quarter of all (min,max) pairs, and
   * the server's bounds are inclusive, so a 1e-16 shortfall would silently
   * drop the single highest-scoring photo from the match.
   */
  const sliderToValue = (tick) => {
    if (tick <= 0) return state.observed.min;
    if (tick >= SLIDER_TICKS) return state.observed.max;
    return state.observed.min + (tick / SLIDER_TICKS) * span();
  };

  function currentFilter() {
    // `album` is part of the filter snapshot exactly as `lo`/`hi` are. Leaving it
    // out would mean "all matching" taken inside an album view silently widened
    // to the whole library when the user then changed the album — the §4.9
    // failure mode, one level up.
    //
    // `media` is here for exactly that reason and it is not optional politeness:
    // the same snapshot is what `/api/selection/preview` resolves and what
    // `/api/delete` re-resolves, so a snapshot missing the media dimension
    // resolves to every photo *and video* in the library. On a grid the user is
    // looking at with Videos filtered out, "Delete 1,204 assets" would be the
    // button they press. The selection is only safe if every dimension that
    // decides membership is one of the things it pins.
    return {
      lo: state.lower,
      hi: state.upper,
      favorites: 'include',
      album: state.album,
      media: state.media,
    };
  }

  function sameFilter(a, b) {
    if (!a || !b) return false;
    const scale = Math.max(1, Math.abs(a.lo), Math.abs(a.hi), Math.abs(b.lo), Math.abs(b.hi));
    const epsilon = scale * 1e-6;
    return Math.abs(a.lo - b.lo) <= epsilon && Math.abs(a.hi - b.hi) <= epsilon &&
      a.favorites === b.favorites &&
      (a.album || 'all') === (b.album || 'all') &&
      // `(x || 'all')` on both sides, like `album`: a snapshot taken before the
      // media filter existed has no `media` key at all, and that is `all`, not a
      // filter that no longer matches. A comparison that read absence as a
      // mismatch would block deletion for a selection that is in fact current.
      (a.media || 'all') === (b.media || 'all');
  }

  /**
   * The singular noun for what the media filter admits, for the panel read-outs.
   *
   * "assets" for `all`, because Photos' assets are now photos *and* videos and
   * the count beside the slider counts both — a read-out that said "photos" over
   * a mixed grid would be wrong on the default view rather than only on a
   * filtered one, which makes it the more important of the three.
   */
  function mediaNoun(selection = state.media) {
    if (selection === 'videos') return 'video';
    if (selection === 'images') return 'photo';
    return 'asset';
  }

  /**
   * The media selection in force, named the way a sentence names it.
   *
   * Beside `albumName`, and for the same reason: the Similar Groups view has
   * both filters applied but shows neither chip, because the control panel that
   * holds them is hidden while it is open. A list narrowed by a filter the
   * reader cannot see is a list they will misread as the whole library.
   */
  function mediaScopeLabel(selection = state.media) {
    if (selection === 'videos') return 'videos only';
    if (selection === 'images') return 'photos only';
    return 'all media';
  }

  /**
   * Adopts the media filter the server *applied*, from a page response's
   * `filter.media` echo.
   *
   * ## Why the echo and not the request
   *
   * The client renders from this field, so if it ever disagreed with the query
   * that was answered the grid would be describing itself wrongly — the chips
   * would say "Videos" over a page of photographs. The server is the only side
   * that knows which set it actually queried, so its answer is what gets shown.
   *
   * An unrecognised echo is *ignored* rather than coerced to `all`. Coercing it
   * would move the control to a filter the server never applied, which is the
   * same lie arriving from the other direction; ignoring it leaves the control
   * and the grid consistent with each other and the mismatch visible, which is
   * the right outcome for what is in practice a version skew between the two.
   */
  function adoptAppliedMedia(echoed) {
    if (typeof echoed !== 'string' || !MEDIA_CHOICES.includes(echoed)) return false;
    if (state.media === echoed) return false;
    state.media = echoed;
    renderMediaBar();
    // The chips moved, and so did the filter a live "all matching" selection was
    // snapshotted under, so the bar has to be told — or it would keep printing a
    // count for a set the server is no longer being asked about.
    updateSelectionBar();
    return true;
  }

  /** Snap the live bounds back onto the real observed extremes. */
  function followObservedBounds() {
    if (!boundsUsable()) return false;
    const moved = state.lower !== state.observed.min || state.upper !== state.observed.max;
    state.lower = state.observed.min;
    state.upper = state.observed.max;
    return moved;
  }

  /** Keep the live bounds legal even when pinned: inside the range, at least one step wide. */
  function clampLiveBounds() {
    if (!boundsUsable()) return false;
    let moved = false;
    let lower = Math.min(Math.max(state.lower, state.observed.min), state.observed.max);
    let upper = Math.max(Math.min(state.upper, state.observed.max), state.observed.min);
    if (upper - lower < oneStep()) {
      if (lower > state.observed.min) lower = Math.max(state.observed.min, upper - oneStep());
      else upper = Math.min(state.observed.max, lower + oneStep());
    }
    if (lower !== state.lower) { state.lower = lower; moved = true; }
    if (upper !== state.upper) { state.upper = upper; moved = true; }
    return moved;
  }

  /**
   * Merge observed extremes reported by the server.
   *
   * `authoritative` is only true for `/api/status` and the SSE snapshot — the
   * single source of truth. The `bounds` echoed by `/api/photos` is used purely
   * as a fallback for the (impossible in practice) case where status has not
   * arrived yet; adopting it unconditionally would make the bounds chase their
   * own query results during analysis and re-issue the query forever.
   */
  function adoptObservedBounds(min, max, authoritative) {
    const nextMin = Number.isFinite(Number(min)) && min !== null ? Number(min) : null;
    const nextMax = Number.isFinite(Number(max)) && max !== null ? Number(max) : null;
    if (!authoritative && state.observed.min !== null && state.observed.max !== null) return false;
    if (nextMin === null || nextMax === null) {
      if (state.observed.min === nextMin && state.observed.max === nextMax) return false;
      state.observed.min = nextMin;
      state.observed.max = nextMax;
      return true;
    }
    if (nextMin === nextMax) {
      // A single score so far: keep a degenerate span rather than dividing by zero.
      state.observed.min = nextMin;
      state.observed.max = nextMax;
      return true;
    }
    const changed = state.observed.min !== nextMin || state.observed.max !== nextMax;
    state.observed.min = Math.min(nextMin, nextMax);
    state.observed.max = Math.max(nextMin, nextMax);
    return changed;
  }

  function syncRangeUI() {
    const usable = boundsUsable() && span() > 0;
    $('dualRange').classList.toggle('disabled', !usable);
    $('lowerRange').disabled = !usable;
    $('upperRange').disabled = !usable;
    $('observedMinLabel').textContent = boundsUsable() ? fmt.score(state.observed.min, 2) : '—';
    $('observedMaxLabel').textContent = boundsUsable() ? fmt.score(state.observed.max, 2) : '—';

    if (!usable) {
      $('rangeFill').style.left = '0px';
      $('rangeFill').style.width = '0px';
      $('lowerReadout').textContent = '—';
      $('upperReadout').textContent = '—';
      $('boundsHint').textContent = boundsUsable()
        ? 'Only one score so far — the range widens as analysis proceeds.'
        : 'No scores yet.';
      return;
    }

    $('lowerRange').value = String(valueToSlider(state.lower));
    $('upperRange').value = String(valueToSlider(state.upper));

    // The two thumbs overlap at the extremes, so whichever handle is above the
    // midpoint is raised; otherwise the lower one would swallow every drag.
    const midpoint = state.observed.min + span() / 2;
    const lowerOnTop = state.lower > midpoint;
    $('lowerRange').style.zIndex = lowerOnTop ? '3' : '1';
    $('upperRange').style.zIndex = lowerOnTop ? '1' : '3';

    // The thumbs are 18px wide and travel inset by 9px at each end of the track.
    const start = fraction(state.lower);
    const end = fraction(state.upper);
    $('rangeFill').style.left = `calc(9px + (100% - 18px) * ${start})`;
    $('rangeFill').style.width = `calc((100% - 18px) * ${Math.max(0, end - start)})`;

    $('lowerReadout').textContent = fmt.score(state.lower, 2);
    $('upperReadout').textContent = fmt.score(state.upper, 2);
    $('boundsHint').textContent = span() === 0
      ? 'Only one score so far — the range widens as analysis proceeds.'
      : '';
  }

  /**
   * Moves one or both bounds, enforcing the invariants the API depends on:
   * inside the observed range, lower ≤ upper, and at least one slider step wide.
   */
  function setBounds(nextLower, nextUpper, { pin = true } = {}) {
    if (!boundsUsable()) return;
    const step = oneStep();
    let lower = nextLower;
    let upper = nextUpper;
    if (lower > upper) [lower, upper] = [upper, lower];
    // Widen against whichever bound the user actually moved, so dragging the
    // lower thumb right never pushes the upper one along with it.
    if (upper - lower < step) {
      if (Math.abs(nextLower - state.lower) >= Math.abs(nextUpper - state.upper)) {
        lower = upper - step;
      } else {
        upper = lower + step;
      }
    }
    state.lower = Math.min(Math.max(lower, state.observed.min), state.observed.max);
    state.upper = Math.min(Math.max(upper, state.observed.min), state.observed.max);
    if (state.upper - state.lower < step) {
      // The clamp collapsed the window (e.g. a hand-typed value outside the data):
      // push the other bound out by one step rather than serving an empty range.
      if (state.upper - state.observed.min >= step) state.lower = state.upper - step;
      else state.upper = state.lower + step;
    }
    if (pin) state.pinned = true;
    syncRangeUI();
  }

  /* --------------------------------------------------------------------- grid */

  function scheduleReload(delay = 200) {
    clearTimeout(state.reloadTimer);
    state.reloadTimer = setTimeout(() => { resetGrid(); }, delay);
  }

  /**
   * Drops every loaded row and starts again from page one.
   *
   * The generation counter is what keeps rapid filter changes honest: a page
   * that was already in flight for the previous filter is discarded when it
   * lands instead of being appended to the fresh grid.
   */
  function resetGrid() {
    state.generation += 1;
    const generation = state.generation;
    state.items = [];
    state.nextCursor = null;
    state.anchorIndex = -1;
    // Album names are keyed by identifier, so they survive a filter change — but
    // only for rows this client has actually seen a page for. Keeping the map
    // means an album filter change does not lose every tile's tags, and stale
    // entries for rows that have since gone are harmless (nothing looks them up).
    // The map is dropped outright only when the identifier space changes, which
    // it cannot do within a session.
    // The grid's tiles are about to be discarded, so the menu's tile goes with
    // them. Focus is deliberately not restored: there is nothing to restore it
    // to, and a grid mid-reload is the wrong place to strand a keyboard user.
    closeTileMenu();
    state.inflightGeneration = -1;
    state.loading = false;
    state.lastGridRefresh = Date.now();
    $('grid').replaceChildren();
    if (state.lightbox.open && state.lightbox.live) closeLightbox();
    updateLoadMore();
    updateSelectionBar();
    return loadPage(null, generation);
  }

  function pageQuery(cursor) {
    const params = new URLSearchParams({
      lo: String(state.lower),
      hi: String(state.upper),
      sort: state.sort,
      favorites: 'include',
      limit: String(PAGE_SIZE),
    });
    // Always sent, including 'all', so the query the client runs is the query the
    // server sees — and so a cursor minted under one album can never be replayed
    // under another (the server binds the token to the filter and refuses).
    //
    // `media` rides the same rule for a sharper reason. The pagination fingerprint
    // folds in every dimension that changes *which rows exist*, and a keyset
    // token issued under `media=images` describes a position inside the photos;
    // replayed under `media=videos` it would be a position in a different set, and
    // the server refusing it (§4.2) is the only thing that keeps page two from
    // silently splicing images and videos together. The client does not get to
    // decide that; it just has to not leave the dimension out.
    params.set('album', state.album);
    params.set('media', state.media);
    if (cursor) params.set('cursor', cursor);
    return params;
  }

  async function loadPage(cursor, generation = state.generation) {
    if (!boundsUsable()) {
      renderEmptyState();
      updateLoadMore();
      return;
    }
    // One in-flight page per generation: the sentinel, the Load-more button and
    // the keyboard can all ask at once and must not triple-fetch.
    if (state.loading && state.inflightGeneration === generation) return;
    state.loading = true;
    state.inflightGeneration = generation;
    try {
      const data = await api.get('/api/photos?' + pageQuery(cursor).toString());
      if (generation !== state.generation) return; // a newer filter owns the grid now
      adoptObservedBounds(data.bounds?.min, data.bounds?.max, false);
      // What the server applied, not what was asked for — see `adoptAppliedMedia`.
      // Read on *every* page rather than only the first, because the echo is
      // also the cheapest notice this client gets that it and the server are on
      // different builds; on a later page it would otherwise go unnoticed.
      adoptAppliedMedia(data.filter && data.filter.media);
      const rows = Array.isArray(data.items) ? data.items : [];
      state.total = Number(data.total) || 0;
      state.nextCursor = data.nextCursor || null;
      // Album names for this page only. Kept in a map keyed by identifier rather
      // than on the rows so the rows stay exactly what the cache holds, and so an
      // absent map entry reads as "no name known" rather than "not in an album".
      absorbAlbumTitles(data.filter && data.filter.albums);
      const offset = state.items.length;
      state.items.push(...rows);
      renderTiles(rows, offset);
      updateCounts();
      updateLoadMore();
      renderEmptyState();
      // IntersectionObserver only reports threshold crossings: if one page was
      // not enough to push the sentinel out of the margin, ask for the next.
      if (state.nextCursor) {
        requestAnimationFrame(() => {
          if (generation === state.generation && !state.loading && sentinelInView()) loadNextPage();
        });
      }
    } catch (error) {
      if (generation !== state.generation) return;
      toast('Could not load photos — ' + error.message, 'error');
    } finally {
      if (state.inflightGeneration === generation) {
        state.loading = false;
        state.inflightGeneration = -1;
      }
    }
  }

  function loadNextPage() {
    if (!state.nextCursor || state.loading) return;
    loadPage(state.nextCursor);
  }

  /* ----------------------------------------------------------------- albums */

  /**
   * Merges the album names a page reported into the per-identifier map.
   *
   * The server only sends names for the rows it just returned, so this replaces
   * exactly those entries and leaves everything else alone — a page that reports
   * nothing does not erase what an earlier page established.
   *
   * A row with no entry is *not* assumed to be in no album: the index may simply
   * not have reached that photo's albums yet. That distinction is why the album
   * chips and the "No album" bucket come from the server's own counts rather than
   * from this map.
   */
  function absorbAlbumTitles(titles) {
    if (!titles || typeof titles !== 'object') return;
    Object.keys(titles).forEach((id) => {
      const entries = Array.isArray(titles[id])
        ? titles[id].filter((a) => a && typeof a.id === 'string').map((a) => ({
          id: a.id,
          title: typeof a.title === 'string' && a.title.trim() ? a.title : '(untitled album)',
        }))
        : [];
      if (entries.length) state.rowAlbums.set(id, entries);
      else state.rowAlbums.delete(id);
    });
  }

  const albumsFor = (id) => state.rowAlbums.get(id) || [];

  /**
   * Fetches the album list and the indexing state behind it.
   *
   * Read-only, and it never touches the grid: an album index finishing must not
   * reset the page the user is standing on. Only `renderAlbumBar` runs here, so
   * §4.12 is untouched — a change to the chip row is not a change to the tiles.
   */
  async function loadAlbums() {
    try {
      const data = await api.get('/api/albums');
      if (!data || typeof data !== 'object') return;
      state.albums = {
        list: Array.isArray(data.albums) ? data.albums.filter((a) => a && a.id) : [],
        unassigned: Number(data.unassigned) || 0,
        indexComplete: data.indexComplete === true,
        indexing: data.indexing === true,
        indexed: Number(data.indexedAlbums) || 0,
        total: Number(data.totalAlbums) || 0,
        smartAlbums: Array.isArray(data.smartAlbums) ? data.smartAlbums.filter((n) => typeof n === 'string') : [],
        smartAlbumsNote: typeof data.smartAlbumsNote === 'string' ? data.smartAlbumsNote : '',
        loaded: true,
        error: typeof data.lastError === 'string' ? data.lastError : '',
      };
      // An album that has been pruned from Photos must not stay selected: the
      // server refuses an unknown album, so keeping it would wedge the grid on an
      // error rather than showing the truth.
      if (state.album !== 'all' && state.album !== 'none'
          && !state.albums.list.some((a) => a.id === state.album)) {
        state.album = 'all';
        scheduleReload(0);
      }
    } catch (error) {
      state.albums = { ...state.albums, error: error.message };
    }
    renderAlbumBar();
  }

  /**
   * The album chips: "All albums", "No album", then the user's own albums.
   *
   * "No album" is a real bucket and always present, because a photo can be in no
   * album at all and those photos would otherwise be unreachable from every album
   * view. It is *not* offered while the index is incomplete: at that point
   * "unassigned" would be a lower bound that keeps growing, and offering it would
   * be offering a number that is about to be wrong.
   */
  function renderAlbumBar() {
    const albums = state.albums;
    const holder = $('albumChips');
    const row = $('albumRow');
    if (!holder || !row) return;

    if (!albums.loaded && !albums.error) { row.hidden = true; return; }
    row.hidden = false;
    holder.replaceChildren();

    const addChip = (label, value, count, title) => {
      const chip = document.createElement('button');
      chip.type = 'button';
      chip.className = 'album-chip';
      chip.dataset.album = value;
      const active = state.album === value;
      chip.classList.toggle('active', active);
      chip.setAttribute('aria-pressed', active ? 'true' : 'false');
      chip.appendChild(document.createTextNode(label));
      if (count !== null && count !== undefined) {
        const badge = document.createElement('span');
        badge.className = 'album-chip-count';
        badge.textContent = fmt.count(count);
        chip.appendChild(badge);
      }
      if (title) chip.title = title;
      // Text and an attribute only — album names come from the user's library and
      // never reach `innerHTML`.
      chip.addEventListener('click', () => selectAlbum(value));
      return chip;
    };

    holder.appendChild(addChip('All albums', 'all', null,
      'Every photo, whatever album it is in'));
    const unassignedReady = albums.indexComplete;
    const unassignedChip = addChip('No album', 'none', unassignedReady ? albums.unassigned : null,
      unassignedReady
        ? 'Photos that are in none of your albums'
        : 'Reading album membership — this count is not final yet');
    unassignedChip.disabled = !unassignedReady;
    // Appended, which it was not: the chip was built, counted, and given its
    // tooltip, and then dropped on the floor — `addChip` returns a node rather
    // than appending it, and this one had no `holder.appendChild`. A bucket that
    // exists on the server (`album=none`), is described in the row's own comment
    // as "always present", and is the only way to reach photos in no album at
    // all was unreachable from the bar.
    holder.appendChild(unassignedChip);
    albums.list.forEach((album) => {
      const name = typeof album.title === 'string' && album.title.trim() ? album.title : '(untitled album)';
      holder.appendChild(addChip(name, album.id, Number(album.count) || 0,
        `${fmt.count(Number(album.count) || 0)} photos PhotoCleaner has scored in “${name}”`));
    });

    // Progress, stated plainly. An incomplete index means the chip list is a
    // partial list and "No album" is a lower bound — saying so beats letting a
    // user conclude their library has no such album.
    const state_ = $('albumIndexState');
    if (albums.error) {
      state_.textContent = 'Albums unavailable — ' + albums.error;
    } else if (!albums.loaded) {
      state_.textContent = 'Reading albums…';
    } else if (albums.indexing) {
      state_.textContent = `Reading albums — ${fmt.count(albums.indexed)} of ${fmt.count(albums.total)}`;
    } else if (!albums.indexComplete) {
      state_.textContent = `${fmt.count(albums.indexed)} of ${fmt.count(albums.total)} albums read`;
    } else {
      state_.textContent = `${fmt.count(albums.list.length)} ${fmt.plural(albums.list.length, 'album', 'albums')}`;
    }

    // Photos' computed collections are named in the *count's* tooltip rather than on
    // a line of their own. The count is where a reader goes when an album they can
    // see in Photos is missing from the chips, so that is where the answer belongs,
    // and a panel that says nothing about them stays one line shorter. The names are
    // capped at six plus a remainder: the sentence answers "is Recents there?", and
    // a tooltip listing twenty-two collections stops being read at all.
    //
    // The same sentence goes in the accessible name, because a `title` is a hover
    // affordance and nothing more — without it a screen reader would pass the count
    // with no mention of what is missing.
    const note = $('albumNote');
    if (albums.error) {
      note.hidden = false;
      note.textContent = 'PhotoCleaner could not read your albums: ' + albums.error;
    } else {
      note.hidden = true;
      note.textContent = '';
    }
    if (!albums.error && albums.smartAlbumsNote) {
      const names = albums.smartAlbums.slice(0, 6).join(', ')
        + (albums.smartAlbums.length > 6 ? ` and ${albums.smartAlbums.length - 6} more` : '');
      const explained = `${albums.smartAlbumsNote} Not offered here: ${names}.`;
      state_.title = explained;
      state_.setAttribute('aria-label', `${state_.textContent}. ${explained}`);
    } else {
      state_.removeAttribute('title');
      state_.removeAttribute('aria-label');
    }
  }

  /**
   * Paints the three media chips: All, Photos, Videos.
   *
   * The markup in `index.html` is deliberately this exact row of `.chip`
   * buttons — the selected state, the hover and the focus ring come free from
   * the class, which is the point. This function only decides which one carries
   * `active`, and it reads `state.media` rather than tracking clicks, so the
   * control cannot disagree with the grid.
   *
   * `aria-pressed` rather than `role="radio"`: the group is announced as a group
   * in the markup and each chip as a toggle button, which is what it is. A radio
   * group would promise arrow-key navigation between the three, and the arrow
   * keys in this window mean "previous/next photo" everywhere else.
   */
  function renderMediaBar() {
    const holder = $('mediaChips');
    if (!holder) return;
    for (const chip of holder.querySelectorAll('[data-media]')) {
      const active = chip.dataset.media === state.media;
      chip.classList.toggle('active', active);
      chip.setAttribute('aria-pressed', active ? 'true' : 'false');
    }
  }

  /**
   * Filters the grid to one media type.
   *
   * Three things happen, and each has a reason that the album filter's identical
   * three reasons do not cover on their own:
   *
   * - **The grid resets.** The keyset cursor names a position inside one result
   *   set, and the media dimension changes which set that is. `scheduleReload` →
   *   `resetGrid` bumps the generation, so a page still in flight for the
   *   previous filter is discarded rather than appended to the new grid.
   * - **The Similar Groups window resets.** Those routes take the media filter
   *   too, and their offsets are the same kind of "position inside one result
   *   set" the grid's cursor is.
   * - **A "matching" selection goes stale.** Handled by `sameFilter` reading
   *   `media`, not by clearing anything: `updateSelectionBar` reports the
   *   mismatch and blocks deletion until the user re-snapshots or clears it
   *   explicitly. An explicit id selection is unaffected by a filter change by
   *   design — those are photographs the reader pointed at, and a filter that
   *   silently emptied a hand-picked selection would be worse than the staleness
   *   it is avoiding.
   *
   * Unlike the album chips, clicking the pressed chip does **not** clear the
   * filter: "All" is a real bucket with its own meaning rather than the absence
   * of one, so there is no "no filter" state left to fall back to. Clicking All
   * is how you get back, and it is one of the three buttons.
   */
  function selectMedia(value) {
    const next = MEDIA_CHOICES.includes(value) ? value : 'all';
    if (state.media === next) return;
    state.media = next;
    renderMediaBar();
    updateSelectionBar();
    if (state.groups.active) resetGroupsWindow();
    scheduleReload(0);
  }

  /**
   * Filters the grid to one album.
   *
   * Always resets the grid: the keyset cursor names a position inside one result
   * set, and the album changes which set that is. `scheduleReload` → `resetGrid`
   * drops `nextCursor` and bumps the generation, so an in-flight page for the
   * previous album is discarded rather than spliced in.
   *
   * The selection is deliberately *not* touched. A live "all matching" selection
   * notices the change through `sameFilter` and becomes stale, which blocks
   * deletion until the user re-snapshots or clears it — the existing mechanism,
   * not a new one. An explicit id selection is unaffected by a filter change by
   * design.
   */
  function selectAlbum(value) {
    const next = value === undefined ? 'all' : value;
    if (state.album === next) {
      // Clicking the active chip clears the filter, which is what "clearable"
      // means without a separate control.
      if (state.album === 'all') return;
      state.album = 'all';
    } else {
      state.album = next;
    }
    renderAlbumBar();
    updateSelectionBar();
    // Similar Groups is filtered by the same album, so it is reloaded here too. The
    // generation is bumped rather than the window merely cleared: a page for the
    // previous album still in flight would otherwise splice itself into the new
    // list, which is the same hazard the grid's own cursor handles.
    if (state.groups.active) resetGroupsWindow();
    scheduleReload(0);
  }

  /**
   * Empties the Similar Groups list so the next load refetches it whole.
   *
   * The offsets are the part that matters: `startOffset`/`endOffset` name a position
   * inside one result set, and the album changes which set that is, exactly as the
   * grid's keyset cursor does. Left in place, a list re-filtered from the top would
   * keep asking for pages past the end of a much shorter list.
   */
  function resetGroupsWindow() {
    const groups = state.groups;
    groups.generation += 1;
    groups.startOffset = 0;
    groups.endOffset = 0;
    groups.total = 0;
    groups.rows = [];
    groups.loading = false;
    groups.note = '';
    syncGroupsHeading();
    $('groupsList').replaceChildren();
    renderGroups();
    return loadGroups('first');
  }

  function sentinelInView() {
    const rect = $('sentinel').getBoundingClientRect();
    return rect.top < window.innerHeight + PAGINATION_MARGIN;
  }

  function updateLoadMore() {
    // The All Photos window is not the score grid's business: a page that lands
    // while the window is open must not reveal "Load more" behind it.
    if (state.all.active) { $('loadMore').hidden = true; return; }
    // Nor is it the Similar Groups view's business: that list pages from its own
    // two sentinels and says so in its own busy row.
    if (state.groups.active) { $('loadMore').hidden = true; return; }
    const more = Boolean(state.nextCursor);
    $('loadMore').hidden = !more;
    $('loadMoreButton').textContent = state.loading ? 'Loading…' : 'Load more';
    $('loadMoreButton').disabled = state.loading || !more;
  }

  /** The score grid's tile context. One object, so `buildTile` allocates nothing. */
  const GRID_VIEW = { list: () => state.items, allPhotos: false, anchor: false };

  function renderTiles(rows, offset) {
    const grid = $('grid');
    const fragment = document.createDocumentFragment();
    rows.forEach((row, index) => {
      fragment.appendChild(buildTile(row, offset + index, GRID_VIEW));
    });
    grid.appendChild(fragment);
  }

  /**
   * One tile, used by both grids.
   *
   * `view.list` returns the live ordered array this tile indexes into, and it is
   * called on every activation rather than captured: the All Photos window is
   * rebuilt each time a page is prepended, so a captured array would hand the
   * lightbox a stale queue. The index is read back from the tile for the same
   * reason — prepending shifts every index below the new rows.
   *
   * `view.allPhotos` marks the second grid (it feeds the lightbox's paging and
   * position line); `view.anchor` marks the one photo the window was opened for.
   */
  function buildTile(row, index, view) {
    const list = view.list;
    const tile = document.createElement('div');
    tile.className = 'tile';
    tile.dataset.id = row.id;
    tile.dataset.index = String(index);
    tile.tabIndex = 0;
    tile.setAttribute('role', 'button');
    // A tile is a photograph now, with no text under it, so this tooltip is
    // where the date and the album live — along with the score, the one figure
    // that is actually drawn, and the media type and length, which are drawn but
    // only as two marks. "Video, 2:07" here and "2:07" on the badge is the
    // tooltip saying what the badge means.
    tile.title = [
      fmt.score(row.score),
      mediaSummaryText(row),
      fmt.date(row.date),
      fmt.dimensions(row.width, row.height),
      albumSummaryText(row.id),
    ].filter(Boolean).join(' · ');
    const liveIndex = () => Number(tile.dataset.index);
    const openThis = () => openLightbox(list(), liveIndex(), '', { allPhotos: view.allPhotos });

    // The image and everything drawn over it share a wrapper, so the score badge
    // and the flags are anchored to the photograph rather than to the card.
    const media = document.createElement('div');
    media.className = 'tile-media';

    // The thumbnail is a video's poster frame from the *same* route a still uses.
    // There is no second image path, and there could not usefully be one:
    // `requestImage` already answers a video with a decoded frame, so a
    // `?poster=1` parameter would buy nothing except a second thing that can be
    // wrong. The tile is also still an `<img>` for the same reason — the lazy
    // load, the decode, the error placeholder and `previewSourceFor`'s query all
    // work on it unchanged.
    const image = document.createElement('img');
    image.className = 'tile-image';
    image.loading = 'lazy';
    image.decoding = 'async';
    image.alt = '';
    image.addEventListener('error', () => {
      image.classList.add('failed');
      if (!media.querySelector('.tile-placeholder')) media.insertBefore(buildPlaceholder(), media.firstChild);
    });
    image.src = thumbURL(row.id);
    media.appendChild(image);

    // A clip's two marks. Both on the photograph rather than in the tile's gutter,
    // because the grid's one rule is that a tile prints as little as it can get
    // away with, and both of these are about *which medium this is* — which is
    // the thing a poster frame cannot say about itself.
    if (isVideoRow(row)) {
      // The length, in the corner opposite the score so the two never compete and
      // so a mixed grid has both facts in the same place on every tile.
      const duration = fmt.mediaDuration(row.duration);
      if (duration) {
        const badge = document.createElement('span');
        badge.className = 'tile-duration';
        badge.textContent = duration;
        // Hidden from the accessibility tree because the tile's own accessible
        // name already says "Video, 2:07" (see `decorateTile`), and a screen
        // reader would otherwise read the length twice from two elements.
        badge.setAttribute('aria-hidden', 'true');
        media.appendChild(badge);
      }
      // The play glyph, centred, and *not* hidden from assistive technology even
      // though it carries no information: it is the one place in the grid where
      // "this is a video" is legible at a glance without reading, which is what
      // stops a contact sheet of frames from being read as a sheet of photographs.
      const play = document.createElement('span');
      play.className = 'tile-play';
      play.setAttribute('aria-hidden', 'true');
      play.textContent = '▶';
      media.appendChild(play);
    }

    // Hover tools. One container so they fade in together and sit side by side.
    const tools = document.createElement('div');
    tools.className = 'tile-tools';

    const inspect = document.createElement('button');
    inspect.className = 'tile-tool tile-inspect';
    inspect.type = 'button';
    inspect.textContent = 'Inspect';
    inspect.title = 'Open the full-size preview';
    inspect.addEventListener('click', (event) => {
      event.stopPropagation();
      openThis();
    });

    const context = document.createElement('button');
    context.className = 'tile-tool tile-context';
    context.type = 'button';
    context.textContent = 'All Photos';
    context.title = 'Show this photo in the context of its series, by date';
    context.addEventListener('click', (event) => {
      event.stopPropagation();
      openAllPhotos(row.id);
    });

    tools.append(inspect, context);
    tile.appendChild(tools);

    const check = document.createElement('div');
    check.className = 'tile-check';
    tile.appendChild(check);

    // The bottom-left corner, as one row: the heart and the score. They are a row
    // rather than two absolutely-positioned marks so the heart's box is always
    // laid out — `.tile-heart` is invisible, not absent — and the score cannot
    // shift sideways when the pointer arrives over a photo.
    const corner = document.createElement('div');
    corner.className = 'tile-corner';

    // A button, and the only favourite mark on the photo: it says what will happen
    // to this photo *and* is how you make it happen, where a glyph you can only
    // reach through a right-click is a fact you cannot act on where you can see it.
    // `decorateTile` fills in the glyph and the labels from the row.
    const heart = document.createElement('button');
    heart.type = 'button';
    heart.className = 'tile-heart';
    attachHeartToggle(heart, row.id);
    corner.appendChild(heart);

    const score = document.createElement('div');
    score.className = 'tile-score';
    score.textContent = fmt.score(row.score);
    corner.appendChild(score);
    media.appendChild(corner);

    tile.appendChild(media);
    decorateTile(tile, row);
    if (view.anchor) markAnchorTile(tile, media);

    tile.addEventListener('click', (event) => onTileClick(row, liveIndex(), event, list));
    tile.addEventListener('dblclick', (event) => {
      event.preventDefault();
      openThis();
    });
    tile.addEventListener('keydown', (event) => {
      // The nested tool buttons activate themselves; letting their Enter bubble
      // in here would open the lightbox twice. `event.target` is the tile itself
      // whenever the tile owns the focus.
      if (event.target !== tile) return;
      if (event.key === 'Enter') { event.preventDefault(); openThis(); }
      // Space previews rather than selects. Enter and Space are the two ways a
      // `role="button"` element is activated, so they do the same thing here: both
      // mean "open this photo". Selection is the click, and a modifier on it.
      // Space used to toggle the selection, which meant the one key that "does
      // something to this photo" was the one key that did not show you the photo.
      else if (event.key === ' ') { event.preventDefault(); togglePreview(list, liveIndex, { allPhotos: view.allPhotos }); }
      else if (event.key === 'ContextMenu' || (event.key === 'F10' && event.shiftKey)) {
        // The ContextMenu key, and its `Shift+F10` spelling, are how the keyboard
        // reaches a context menu on every platform. They are handled here rather
        // than at the document so the menu anchors to *this* tile, and the event
        // is stopped so the document-level Escape handling below cannot also fire.
        event.preventDefault();
        event.stopPropagation();
        openTileMenu(tile, row, null);
      }
      // A tile that owns the focus has handled the key. Without this the
      // document-level lightbox shortcut below would also fire, toggling the
      // lightbox photo as well as the focused one on a single Space press.
      if (event.key === ' ' || event.key === 'Enter') event.stopPropagation();
    });
    // Right-click, and the Ctrl-click that macOS treats as the same gesture.
    // `contextmenu` fires for both, so one listener covers the convention
    // Finder uses. Suppressing the browser's own menu is the point: this menu
    // knows things the native one cannot (which photos the action would touch).
    //
    // `longPress` adds the touch equivalent, because a trackpad-free device has
    // no other way in. It is deliberately a *separate* path: it must not fire
    // for a mouse, and it must cancel the pending synthetic click so holding a
    // finger down does not also toggle the selection.
    attachTileContextMenu(tile, row);
    return tile;
  }

  /** The album names for one photo, for a tooltip — '' when it is in none. */
  function albumSummaryText(id) {
    const entries = albumsFor(id);
    if (!entries.length) return '';
    return `in ${entries.map((album) => album.title).join(', ')}`;
  }

  /**
   * Marks the photo the All Photos window was opened for.
   *
   * Two signals, not one: the accent ring is quick to spot while scrolling, and
   * the label says what the ring means. It goes inside `.tile-media` so it sits
   * on the photo, clear of the score badge in the opposite corner.
   */
  function markAnchorTile(tile, media) {
    tile.classList.add('anchor', 'anchor-pulse');
    const label = document.createElement('span');
    label.className = 'tile-anchor-label';
    label.textContent = 'Selected photo';
    media.appendChild(label);
    // Announced once, then stopped: `prefers-reduced-motion` already collapses
    // the duration, so the event still arrives and the class is always cleared.
    tile.addEventListener('animationend', () => { tile.classList.remove('anchor-pulse'); }, { once: true });
  }

  /**
   * Repaints everything about a tile that depends on shared state: the selection
   * ring, the bitmap check mark and the heart.
   */
  function decorateTile(tile, row) {
    const selected = isSelected(row.id);
    tile.classList.toggle('selected', selected);
    tile.setAttribute('aria-pressed', selected ? 'true' : 'false');
    // The accessible name carries everything the tile no longer prints: the date,
    // the favourite state, and the album. A glyph on the photo is a hint, not the
    // fact — so with the heart as the only visible mark, "protected from deletion"
    // is stated here rather than left to the reader of a lock that no longer exists.
    // It is stated unconditionally because protection is: there is no setting that
    // can take it away.
    const albumSummary = albumsFor(row.id);
    const protectedNow = Boolean(row.favorite);
    // The media type and length go here, in the name, and not only on the marks:
    // a duration badge is a number in a corner and a play glyph is a shape, and
    // neither is a *name*. This is where the rest of what the tile no longer
    // prints already lives — the date, the album, the protection — so it is where
    // a clip's two facts belong too. Omitted entirely for a still rather than
    // saying "Photo": "Photo" on a photograph is a word the reader supplied.
    const media = mediaSummaryText(row);
    tile.setAttribute('aria-label',
      `Score ${fmt.score(row.score)}`
      + `${media ? `, ${media}` : ''}`
      + `, ${fmt.dateShort(row.date)}`
      + `${row.favorite ? ', favorite' : ''}`
      + `${protectedNow ? ', protected from deletion' : ''}`
      + (albumSummary.length ? `, in ${albumSummary.map((a) => a.title).join(', ')}` : ''));
    const check = tile.querySelector('.tile-check');
    if (check) check.textContent = selected ? '✓' : '';

    // The heart, in the corner next to the score and in the same white as the
    // request that made it. The shape says the state, the words say what pressing
    // it will do — and the words are `aria-label` rather than `title` so the
    // control says what it does even when a tooltip is not the thing being read.
    const heart = tile.querySelector('.tile-heart');
    if (heart) decorateHeart(heart, row);
  }

  /**
   * Paints a heart from a row: the glyph, the announced state, and the tooltip.
   *
   * One place for both surfaces, so "the heart means the same thing everywhere" is
   * a fact about the code rather than a coincidence. The heart is the only mark a
   * favourite gets — there used to be a star chip and a lock chip in the tile's
   * gutter as well, saying the same thing twice — so the protection the lock stood
   * for is folded into this sentence, and nothing about a photo is only knowable
   * from the shape of a glyph.
   */
  function decorateHeart(heart, row) {
    const favourite = Boolean(row.favorite);
    heart.textContent = favourite ? '♥' : '♡';
    heart.classList.toggle('is-favorite', favourite);
    heart.setAttribute('aria-pressed', favourite ? 'true' : 'false');
    heart.setAttribute('aria-label', favourite ? 'Remove from Favourites' : 'Make Favourite');
    heart.title = favourite
      ? 'Favorite — protected from deletion. Click to remove.'
      : 'Mark as a favorite in Photos. Favourites are excluded from deletion.';
  }

  /**
   * One clickable album chip.
   *
   * `event.stopPropagation()` because the chip lives *inside* the tile, which is
   * itself a click target: without it, filtering by album would also toggle the
   * photo's selection. Album titles come from the library and only ever reach
   * `textContent` and `title`.
   */
  function buildAlbumTag(album, total) {
    const tag = document.createElement('button');
    tag.type = 'button';
    tag.className = 'album-tag';
    tag.textContent = album.title;
    tag.title = total > 1
      ? `Filter to “${album.title}” · this photo is in ${fmt.count(total)} albums`
      : `Filter to “${album.title}”`;
    tag.addEventListener('click', (event) => {
      event.preventDefault();
      // The chip lives inside the tile, which is itself a click target: without
      // this, filtering by album would also toggle the photo's selection.
      event.stopPropagation();
      // The All Photos window is chronological and deliberately ignores every
      // filter, so an album filter pressed from inside it has to leave it first —
      // otherwise the click would appear to do nothing.
      if (state.all.active) closeAllPhotos();
      // Similar Groups *does* honour the album filter, so the view stays open and
      // `selectAlbum` re-filters the list in place. Leaving it would throw away the
      // group the user was looking at to reach a filter they could equally have
      // applied from the chips.
      selectAlbum(album.id);
    });
    return tag;
  }

  /**
   * True when this Mac can only offer what it already holds.
   *
   * The one setting that decides whether a missing rendition is "in iCloud,
   * downloads are off" or "Photos could not make a picture of this": with downloads
   * on, PhotoKit is allowed to reach for the pixels, and a photo that still cannot
   * be drawn is a different failure from one that was never fetched.
   */
  function localOnly() {
    return Boolean(state.status && state.status.settings && !state.status.settings.downloadFromICloud);
  }

  function buildPlaceholder() {
    const node = document.createElement('div');
    node.className = 'tile-placeholder';
    node.textContent = localOnly() ? 'In iCloud' : 'Unavailable';
    node.title = localOnly()
      ? 'The pixels are stored in iCloud. Enable "Download from iCloud when required" to fetch them.'
      : 'PhotoKit could not produce a thumbnail for this asset.';
    return node;
  }

  /**
   * Makes a heart the toggle the grid tile's is, wherever it is drawn.
   *
   * One function for both surfaces, because "the heart sets the favourite" is a
   * single promise and two implementations of it would drift: the group strip's
   * used to be a `<span>` that only appeared once a photo was *already* a
   * favourite and protection was on, so it could report the flag but never change
   * it. Reading is fine; the tile could set it and the group could not.
   *
   * `rowById` is consulted rather than the row the button was built with: the
   * write is asynchronous, so by the time a second press arrives the row may have
   * been patched, and a press that lands mid-flight must ask for the state that is
   * now on screen rather than the one that started it.
   */
  function attachHeartToggle(heart, id) {
    heart.addEventListener('click', (event) => {
      // The cell is itself a click target — it selects — so without this a press
      // on the heart would select the photo as well as favouriting it.
      event.preventDefault();
      event.stopPropagation();
      const current = rowById(id);
      setFavoriteOnTargets([id], !(current ? current.favorite : false));
    });
    // A double press on the heart is two toggles, not a request to preview.
    heart.addEventListener('dblclick', (event) => event.stopPropagation());
  }

  function refreshAllTiles() {
    $('grid').querySelectorAll('.tile').forEach((tile) => {
      const row = state.items[Number(tile.dataset.index)];
      if (row) decorateTile(tile, row);
    });
    refreshAllPhotosTiles();
    refreshGroups();
    updateSelectionBar();
  }

  /**
   * Repaints group cells: the favourite heart and the selection ring.
   *
   * `state.groups.rows` is the authoritative order and the DOM matches it because
   * `renderGroups` rebuilds the whole list, so a cell's index addresses it directly —
   * the same reason `refreshAllPhotosTiles` can use the DOM order.
   */
  function refreshGroups() {
    if (!state.groups.active) return;
    // Every cell, because this is the whole-list counterpart of the targeted
    // `refreshGroupCellsById`. The per-cell decision lives in `paintGroupCell`, so
    // the two paths cannot disagree about what a favourite looks like.
    $('groupsList').querySelectorAll('.group-cell').forEach(paintGroupCell);
  }

  /** One selection spans both grids, so a change here has to repaint there too. */
  function refreshAllPhotosTiles() {
    if (!state.all.active) return;
    const rows = state.all.rows;
    // Read from the tile's own `data-index`, not from its position in the
    // document. Prepending a page shifts the two apart, and a tile repainted
    // from its neighbour's row is a wrong heart on a real photo.
    $('allPhotosDays').querySelectorAll('.tile').forEach((tile) => {
      const row = rows[Number(tile.dataset.index)];
      if (row) decorateTile(tile, row);
    });
  }

  /* -------------------------------------------------------- tile context menu */

  /**
   * The right-click menu on a tile.
   *
   * Follows the Finder convention rather than inventing one: on macOS a
   * right-click *or* a Ctrl-click opens it, `contextmenu` is the event that
   * covers both, and the browser's own menu is suppressed so every item is one
   * this app can act on.
   *
   * ## Why right-click never touches the selection
   *
   * A context menu acts *on* something; it does not *change* what is selected.
   * Finder is the model: right-clicking outside a selection leaves the selection
   * alone, and right-clicking inside it keeps it. So `openTileMenu` reads the
   * selection and never writes it, and it does not move the shift-click anchor,
   * since that anchor *is* selection state. Selecting is a gesture on the photo
   * itself, and it is one gesture away there.
   *
   * ## Why there is one menu, not one per tile
   *
   * A single reused element makes "only one at a time" and "never stranded"
   * structural rather than something to remember: there is nowhere for a second
   * menu to exist, and `closeTileMenu` is the only way it leaves the screen.
   *
   * ## Why the anchor is not necessarily a tile
   *
   * The same menu is opened on the lightbox photo. That is an `<img>`, which
   * cannot hold focus, so `focusReturn` exists: the menu asks its opener where
   * focus should come back to rather than assuming the anchor can take it.
   */
  const tileMenu = {
    /** What the menu is anchored to and about; null when closed. A grid tile, an
     *  All Photos tile, or the lightbox image. */
    tile: null,
    row: null,
    /** Where focus goes when the menu closes. Defaults to the anchor; the
     *  lightbox names its close button instead. */
    focusReturn: null,
    /** Menu items in DOM order. Kept so the arrow keys and the roving tabindex
     *  never have to query the DOM and risk disagreeing with it. Separators are
     *  in here too and are filtered out by role where it matters. */
    items: [],
    /** Token for the one lookup a menu makes about its photo — see
     *  `resolveSimilarItem`. Bumped by every open and every close. */
    lookup: 0,
  };

  /** Held between the long-press timer firing and the synthetic click arriving. */
  let suppressNextTileClick = false;

  function attachTileContextMenu(tile, row) {
    tile.addEventListener('contextmenu', (event) => {
      // Suppressing the browser's own menu is the whole point: every item here
      // is one this app can act on. `preventDefault` does that, and the bubbling
      // is stopped so an ancestor grid can never open a second menu.
      event.preventDefault();
      event.stopPropagation();
      openTileMenu(tile, row, { x: event.clientX, y: event.clientY });
    });

    // Long-press, for touch: the only way into this menu on a device with no
    // right-click. No dependency and no `touchstart` fallback - Pointer Events
    // already cover mouse, pen and touch, and the `pointerType` guard below
    // keeps this off a mouse entirely, so the timer cannot fire under a right-click.
    let timer = null;
    let origin = null;
    const CANCEL_SLOP = 10;

    const cancel = () => {
      clearTimeout(timer);
      timer = null;
      origin = null;
    };

    tile.addEventListener('pointerdown', (event) => {
      if (event.pointerType !== 'touch') return;
      origin = { x: event.clientX, y: event.clientY };
      clearTimeout(timer);
      // Long enough not to fire while scrolling or tapping, short enough to feel
      // like a menu on release. Matches what iOS and Android both use.
      timer = setTimeout(() => {
        timer = null;
        const point = origin;
        cancel();
        if (!point) return;
        // The browser synthesises a click after a long press, and that click
        // would toggle the selection. Flag it so `onTileClick` swallows it —
        // which is what keeps "long-press to open a menu" free of the side
        // effect right-click has on macOS.
        suppressNextTileClick = true;
        openTileMenu(tile, row, { x: point.x, y: point.y });
      }, 500);
    });
    // A finger that moves is scrolling or a swipe, not a long press.
    tile.addEventListener('pointermove', (event) => {
      if (event.pointerType !== 'touch' || !origin) return;
      if (Math.abs(event.clientX - origin.x) > CANCEL_SLOP ||
          Math.abs(event.clientY - origin.y) > CANCEL_SLOP) cancel();
    });
    tile.addEventListener('pointerup', cancel);
    tile.addEventListener('pointercancel', cancel);
    tile.addEventListener('pointerleave', cancel);
  }

  /**
   * Opens the menu for one photo.
   *
   * `point` is the cursor position for a pointer or a long press, and `null` for
   * the keyboard, where the menu is anchored to the tile instead — the same
   * thing a native menu does when it is opened from the keyboard.
   */
  function openTileMenu(tile, row, point, focusReturn = null) {
    // Re-opening for the same tile while it is already open (a second
    // right-click) re-anchors and re-labels it instead of stacking.
    closeTileMenu();
    tileMenu.tile = tile;
    tileMenu.row = row;
    tileMenu.focusReturn = focusReturn;
    tile.dataset.menuOpen = 'true';

    const menu = $('tileMenu');
    menu.replaceChildren();
    const plan = tileMenuItems();
    const fragment = document.createDocumentFragment();
    for (const spec of plan) fragment.appendChild(buildMenuItem(spec));
    menu.appendChild(fragment);
    tileMenu.items = plan.map((spec) => spec.node);

    $('tileMenuHint').textContent = tileMenuHintText();
    $('tileMenuLayer').hidden = false;
    placeTileMenu(tile, point);
    // The one item whose enabled state the row cannot answer — see
    // `resolveSimilarItem`. Started after the menu is on screen so a slow lookup
    // never delays the menu itself.
    const similar = plan.find((spec) => spec.key === 'similar');
    if (similar) resolveSimilarItem(similar);
    // Focus the menu itself rather than the first item: a menu that takes focus
    // on its first item reads as "an item is already running", and every
    // keystroke would have to start at item two.
    menu.focus({ preventScroll: true });
  }

  /**
   * Greys out "Show Similar Photos" for a photograph that has none.
   *
   * Whether a photo has a similar group is a fact about the grouping pass, not
   * about the row: the grid's rows carry a score, a date and a size, and nothing
   * that names a group. So the item is built live and corrected the moment
   * `GET /api/photo/{id}/similar` answers — two indexed reads, the same lookup the
   * item itself performs when it is chosen, which is why asking early costs nothing
   * that choosing it would not have cost anyway.
   *
   * `tileMenu.lookup` is the token, and it is the rule everything else in this
   * client follows: the menu can be closed and reopened on another photo while this
   * is in flight, and a late answer must not correct the wrong item. A lookup that
   * *fails* leaves the item live rather than grey — an unreachable server is not the
   * same answer as "no similar photos", and the item reports the failure itself.
   */
  async function resolveSimilarItem(spec) {
    const row = tileMenu.row;
    if (!row) return;
    const token = ++tileMenu.lookup;
    let answer;
    try {
      answer = await api.get(`/api/photo/${encodeURIComponent(row.id)}/similar`);
    } catch {
      return;
    }
    if (token !== tileMenu.lookup || !spec.node) return;
    // A definite answer only: no group *and* the analysis has seen this photo.
    if (!answer || answer.analyzed !== true || answer.groupId) return;
    spec.disabled = true;
    spec.node.setAttribute('aria-disabled', 'true');
    const hint = document.createElement('span');
    hint.className = 'menu-hint';
    hint.textContent = 'none found';
    spec.node.appendChild(hint);
  }

  /**
   * Places the layer against the cursor, flipping at the viewport edges.
   *
   * A menu that runs off the right or bottom edge is unreachable — its last
   * items cannot be pointed at, and with the keyboard the arrow key walks
   * somewhere the pointer never was. So the layer is measured *after* it is
   * visible and then nudged back inside, which handles both edges at once.
   *
   * An 8px margin keeps the menu off the exact edge, which is what every native
   * menu does and what makes a menu near the corner still feel deliberate.
   */
  function placeTileMenu(tile, point) {
    const layer = $('tileMenuLayer');
    const margin = 8;
    let x;
    let y;
    if (point) {
      x = point.x;
      y = point.y;
    } else {
      // Keyboard: below the tile's own top-left, the position a native menu
      // uses when the item is activated from the keyboard.
      const rect = tile.getBoundingClientRect();
      x = rect.left;
      y = rect.top;
    }
    // Measured after unhiding, so a long menu flips rather than clipping.
    const width = layer.offsetWidth;
    const height = layer.offsetHeight;
    const maxX = Math.max(margin, window.innerWidth - width - margin);
    const maxY = Math.max(margin, window.innerHeight - height - margin);
    layer.style.left = `${Math.round(Math.min(Math.max(margin, x), maxX))}px`;
    layer.style.top = `${Math.round(Math.min(Math.max(margin, y), maxY))}px`;
  }

  /**
   * The photo menu: the items, in order, for the photo the menu is about.
   *
   * Only actions that act *on the photo* or *on the library*. Selecting, ranging,
   * opening and clearing the selection are each one gesture away on the surface
   * itself — click, ⇧-click, double-click, the bar's own buttons — and a
   * right-click user who wanted to select something would have clicked it. They
   * were also the items most likely to be *wrong*: "Select range" is a run of
   * photos measured from an anchor the user may not know they set, and "Inspect"
   * is the default double-click wearing a second name. What is left is what a
   * right-click is actually for: where this photo goes next, what it is, and what
   * should happen to it.
   *
   * ## One list, every place a photo can be pointed at
   *
   * The score grid, All Photos, a group strip and the lightbox all reach here,
   * and "Show in All Photos" / "Show Similar Photos" / the favourite toggle /
   * Delete mean the same thing in each — so a second menu would be a second set
   * of rules about favourite protection, free to drift from the first. The caller
   * supplies only the row and where to anchor the menu; nothing below reads a
   * queue or an index, because nothing left needs one.
   *
   * ## Enabled state
   *
   * Which photos an action touches is decided once, here, and both the enabled
   * state and the footnote read from it. An item that cannot act is disabled
   * rather than hidden: a greyed-out item reads as "something is wrong" rather
   * than "not applicable".
   */
  function tileMenuItems() {
    const row = tileMenu.row;
    const scored = boundsUsable();
    // Captured now, not read back on activation: an item closes the menu before
    // it runs, and the menu's own fields are cleared by that close. Anything a
    // closure needs has to be bound while the menu is still open.
    const targets = tileMenuTargets();
    // One item, not two, and never greyed: whether "this is already a favourite"
    // is a question with an answer, so the menu answers it rather than showing
    // both possibilities and disabling one. "Any target is a favourite" is the
    // only reading that keeps the item live — with several targets in mixed
    // states it offers the un-favourite, because that is the branch which would
    // otherwise change something.
    const anyFavorite = targets.some(isSelectedFavorite);

    return [
      {
        label: 'Show in All Photos',
        // No scores means no chronological window to anchor on.
        disabled: !scored,
        run: () => openAllPhotos(row.id),
      },
      {
        label: 'Show Similar Photos',
        // Enabled when the menu opens, and greyed out by `resolveSimilarItem` if the
        // photo turns out to have none. The answer is not on the row — it is a fact
        // about a grouping pass that ran in the background — so it is asked for
        // rather than guessed, and only a *definite* "none" greys the item: "analysis
        // has not reached this photo yet" is a different fact, and its page says so.
        key: 'similar',
        disabled: false,
        run: () => showSimilarPhotos(row.id),
      },
      {
        label: 'Open in Photos',
        hint: 'leaves this app',
        // Always offered. The reveal can fail for reasons this client cannot
        // see — Photos absent, a permission, a macOS version that dropped the
        // link — and each of those has a message worth showing rather than an
        // item that silently does not exist.
        disabled: false,
        run: () => {
          toast('Asking Photos to open that photo…', 'info');
          revealInPhotos(row);
        },
      },
      { separator: true },
      {
        // The toggle. Two items with one greyed out meant the reader had to work
        // out which half of the pair applied, and a disabled item on a destructive
        // action reads as "something is wrong" rather than "not applicable".
        label: anyFavorite ? 'Remove from Favourites' : 'Favourite',
        hint: targets.length > 1 ? `${fmt.count(targets.length)} selected` : '',
        disabled: false,
        run: () => setFavoriteOnTargets(targets, !anyFavorite),
      },
      { separator: true },
      {
        // "Delete", and it means it. The label cannot also carry the scope, so
        // the *hint* does: the count it will destroy, which is what tells a delete
        // of a whole selection apart from a delete of one photo. There is nothing
        // held back to take out again, so there is no second item here: what the
        // server did is reported once, in the toast.
        label: 'Delete',
        hint: `${fmt.count(targets.length)} ${fmt.plural(targets.length, mediaNoun(), `${mediaNoun()}s`)}`,
        disabled: false,
        run: () => deletePhotos({ mode: 'ids', ids: targets }),
      },
    ];
  }

  /** True when this identifier is a favourite, as far as the loaded rows know. */
  function isSelectedFavorite(id) {
    const row = rowById(id);
    return Boolean(row && row.favorite);
  }

  /**
   * The row this client knows for an identifier, from any surface that holds one.
   *
   * The favourite flags live on the rows already in memory, and the grids are the
   * only place that knows about them, so this is how "is anything here already a
   * favourite" is answered without asking the server on every right-click.
   *
   * The group strips are searched too, because a heart in a strip is now a control
   * and has to read the flag back the same way a tile's does. Without that a photo
   * that is only in a group would answer "not a favourite" however many times it
   * was pressed, and the heart would set the flag it already had.
   */
  function rowById(id) {
    return state.items.find((row) => row.id === id)
      || state.all.rows.find((row) => row.id === id)
      || groupRowById(id);
  }

  /** The group member row for an identifier, if a strip on screen holds it. */
  function groupRowById(id) {
    for (const group of state.groups.rows) {
      const row = groupItems(group).find((item) => item.id === id);
      if (row) return groupMemberRow(row);
    }
    return null;
  }

  function buildMenuItem(spec) {
    if (spec.separator) {
      const separator = document.createElement('div');
      separator.className = 'menu-separator';
      separator.setAttribute('role', 'separator');
      // Recorded like an item so the item list stays one parallel array; a
      // separator has no `menuitem` role, so the keyboard helpers skip it.
      spec.node = separator;
      return separator;
    }
    const item = document.createElement('button');
    item.type = 'button';
    item.className = 'menu-item';
    item.setAttribute('role', 'menuitem');
    // Roving tabindex: exactly one item is in the tab order at a time, so Tab
    // leaves the menu instead of walking its items.
    item.tabIndex = -1;
    if (spec.disabled) item.setAttribute('aria-disabled', 'true');
    item.textContent = spec.label;
    if (spec.hint) {
      const hint = document.createElement('span');
      hint.className = 'menu-hint';
      hint.textContent = spec.hint;
      item.appendChild(hint);
    }
    item.addEventListener('click', (event) => {
      event.stopPropagation();
      if (spec.disabled) return;
      // Close first, then act: an action that opens the lightbox or the All
      // Photos window takes focus for itself, and a menu left open underneath
      // it would be stranded behind an overlay.
      closeTileMenu();
      spec.run();
    });
    spec.node = item;
    return item;
  }

  /**
   * The footnote: exactly which photos the items will act on.
   *
   * A menu whose scope is invisible is the one way a context menu can surprise
   * someone, so the scope is stated rather than implied — including the case
   * where it is narrower than the selection bar suggests.
   */
  function tileMenuHintText() {
    const inSelection = isSelected(tileMenu.row.id);
    const count = tileMenuTargets().length;
    if (state.selection.mode === 'matching' && selectionHasContent()) {
      return 'Affects this photo only. Deleting "all matching" is deliberately not '
        + 'reachable from a tile menu — use the Delete button in the bar for that.';
    }
    if (count > 1) {
      return `Affects all ${fmt.count(count)} selected ${fmt.plural(count, mediaNoun(), `${mediaNoun()}s`)}. `
        + 'Open in Photos always opens one photo — the one you clicked.';
    }
    if (selectionHasContent() && !inSelection) {
      return `Affects this photo alone. It is not among your ${fmt.count(selectionSize())} selected.`;
    }
    return 'Affects this photo only.';
  }

  /** How many photos the current selection resolves to. */
  function selectionSize() {
    const selection = state.selection;
    if (selection.mode === 'matching') return selection.resolved;
    return selection.ids.size;
  }

  /**
   * Which photos the items in the currently open menu will act on.
   *
   * The clicked photo when it is outside the selection — acting on a selection
   * the user did not click into would be a surprise — and the whole selection
   * when the clicked photo is part of it.
   *
   * A "all matching" selection is deliberately *not* reachable from here. It is
   * a filter, not an enumerable set: the client does not know its members, so
   * anything that named it would be asking the server to destroy a set the user
   * never looked at. The footnote says so, and the bar's Delete button remains
   * the one route to it.
   */
  function tileMenuTargets() {
    const row = tileMenu.row;
    if (!row) return [];
    const selection = state.selection;
    if (selection.mode !== 'ids' || selection.ids.size === 0) return [row.id];
    if (!isSelected(row.id)) return [row.id];
    return [...selection.ids];
  }

  /**
   * Adds or removes every photo between the shift-click anchor and `index`.
   *
   * Extracted from the shift-click handler so the grid's ⇧-click and a group
   * cell's are the *same* operation rather than two that could drift. `list` is
   * the caller's live accessor: the All Photos window prepends pages, so a
   * captured array would index a window that has moved.
   */
  function selectRangeTo(index, list, anchor = gridAnchor()) {
    const from = anchor.get();
    if (from < 0 || from === index) return;
    const [low, high] = [from, index].sort((a, b) => a - b);
    // The list is read once. A range can be long, and a list that changed under
    // the loop — a page landing, a strip being rebuilt — would shift every index
    // after the change and select the wrong span.
    const rows = list() || [];
    for (let i = low; i <= high; i += 1) {
      const item = rows[i];
      if (!item) continue;
      if (state.selection.mode === 'matching') state.selection.excluded.add(item.id);
      else state.selection.ids.add(item.id);
    }
    anchor.set(index);
    refreshAllTiles();
    refreshSelectionPreview();
  }

  /**
   * Closes the menu and returns focus to the tile it came from.
   *
   * Focus goes back to the tile *every* time, including when an item is being
   * activated. That is not politeness, it is how the next step gets its own
   * focus right: `openLightbox` remembers `document.activeElement` as the element
   * to return to when it closes, so leaving focus on a menu that is about to be
   * hidden would make the lightbox return to nothing. The tile is where the user
   * came from, so it is the right answer either way.
   *
   * A tile that has since been removed gets nothing: focusing a detached element
   * silently drops focus on the body, and a grid mid-reload is the wrong place
   * to strand a keyboard user anyway.
   *
   * `focusReturn` is read *before* the state is cleared, and it is what an anchor
   * that cannot hold focus names instead: the lightbox's photo is an `<img>`, so
   * its menu hands focus to the lightbox's own close button.
   */
  function closeTileMenu() {
    const layer = $('tileMenuLayer');
    const tile = tileMenu.tile;
    const focusTarget = tileMenu.focusReturn || tile;
    if (tile) delete tile.dataset.menuOpen;
    tileMenu.tile = null;
    tileMenu.row = null;
    tileMenu.focusReturn = null;
    tileMenu.items = [];
    // Retires the lookup this menu started: a menu that is closing — or one being
    // replaced by a right-click on another photo — must not be corrected by an
    // answer about the photo it used to be about.
    tileMenu.lookup += 1;
    layer.hidden = true;
    $('tileMenu').replaceChildren();
    $('tileMenuHint').textContent = '';
    if (focusTarget && focusTarget.isConnected) focusTarget.focus({ preventScroll: true });
  }

  const tileMenuIsOpen = () => !$('tileMenuLayer').hidden;

  /**
   * The items a keyboard can land on.
   *
   * Separators are in `tileMenu.items` for ordering but are not focusable, and a
 * disabled item is visible and skipped. Filtering on the role rather than on
   * position means a new decorative child cannot accidentally become a
   * keyboard stop.
   */
  function navigableMenuItems() {
    return tileMenu.items.filter((item) => item.getAttribute('role') === 'menuitem'
      && item.getAttribute('aria-disabled') !== 'true');
  }

  /**
   * Moves focus within the menu, wrapping at both ends.
   *
   * `ArrowUp`/`ArrowDown` are the menu keys on macOS and Windows both; `Home`
   * and `End` are what every native menu answers to, so they work here too.
   */
  function moveTileMenuFocus(delta) {
    const items = navigableMenuItems();
    if (items.length === 0) return;
    const current = items.indexOf(document.activeElement);
    let next = current;
    if (delta === 'first') next = 0;
    else if (delta === 'last') next = items.length - 1;
    else if (current === -1) next = delta > 0 ? 0 : items.length - 1;
    else next = (current + delta + items.length) % items.length;
    items.forEach((item) => { item.tabIndex = -1; });
    items[next].tabIndex = 0;
    items[next].focus();
  }

  /**
   * Hands one photo to Photos.app.
   *
   * Deliberately one photo per invocation. Revealing is per-photo by design on
   * the server, and a selection of five thousand would mean five thousand
   * cross-process hand-offs that hang both apps; the *clicked* photo is what
   * gets revealed, which is also the one the user pointed at.
   *
   * The server's `mechanism` is passed through rather than summarised, because
   * the difference between "Photos was asked to open this photo" and "Photos
   * only opened" is exactly what the user needs to know before they go looking.
   */
  async function revealInPhotos(row) {
    const { ok, payload } = await api.post('/api/photos/reveal', { id: row.id });
    if (!ok) {
      toast(`Could not open in Photos — ${errorText(payload, 'the server refused the request')}`, 'error');
      return;
    }
    // The server's own wording, because it is the only side that knows which
    // mechanism worked. `asset_link` is a request Photos may or may not honour;
    // anything else means Photos is open but not pointing at this photo, and
    // saying so is better than a bare "done".
    const exact = payload.mechanism === 'asset_link' && Number(payload.opened) === 1;
    const message = typeof payload.message === 'string' && payload.message
      ? payload.message
      : 'Photos was opened.';
    toast(exact ? `${message} It may not be selected yet — Photos decides.` : message,
      exact ? 'info' : 'warning');
  }

  /**
   * Sets or clears the favourite flag on the menu's targets.
   *
   * Favouriting is a *write* to the user's library: it syncs to their other
   * devices, and it is the flag deletion protection is decided from. It is a
   * toggle rather than a dialog, and the result is reported from what PhotoKit
   * confirms rather than from what was asked — so an undo is one more press.
   *
   * The grid is not rebuilt optimistically. `PhotoRow` objects are shared
   * between both grids, so patching them in place repaints everywhere at once and
   * keeps the scroll position the user is standing on.
   */
  async function setFavoriteOnTargets(ids, favorite) {
    if (!ids.length) return;
    // No confirmation either way, and deliberately so. The heart is a toggle: one
    // press sets, the next clears, and a dialog in the middle of a toggle is a
    // dialog on half the presses of an ordinary control. Nothing is destroyed here
    // either — the flag comes back by pressing the heart again.
    const { ok: accepted, payload } = await api.post('/api/favorites', { ids, favorite });
    if (!accepted) {
      toast(`Could not change the favourite flag — ${errorText(payload, 'the server refused the request')}`, 'error');
      return;
    }
    const confirmed = Number(payload.confirmed) || 0;
    const errors = Array.isArray(payload.errors) ? payload.errors.filter(Boolean) : [];
    const applied = applyFavoriteState(ids, favorite, confirmed > 0 || errors.length === 0);
    // The lightbox prints the flag on its own button — "♥ Favourite — protected"
    // versus "♡ Make favourite" — and that button is one of the ways the change
    // was *made*. Favouriting from here would otherwise leave it reading the old
    // state until the photo was navigated away from, which reads as the click
    // having failed. Repainted only when this photo is the one on screen.
    if (applied.includes(state.lightbox.queue[state.lightbox.index]?.id)) renderLightbox();
    // A toast only when the heart on screen is *not* the answer. Success says
    // nothing the filled-in glyph has not already said — it has turned, and it
    // turned because the press worked — so announcing it is a badge for an event
    // the interface is showing already. Failure is the other matter: there the
    // heart is unchanged or half-changed, which is exactly when the user cannot
    // tell from the picture alone that PhotoKit refused.
    if (errors.length > 0) {
      toast(`Photos refused part of the change — ${errors[0]}`, 'error');
    } else if (confirmed === 0) {
      toast('Photos did not confirm any of those photos.', 'warning');
    }
    refreshSelectionPreview();
  }

  /**
 * Records a confirmed favourite change on the loaded rows and repaints only what
 * changed.
 *
 * ## Why not `refreshAllTiles`
 *
 * That is the right tool when a change can touch anything — a selection toggle, a
 * filter reset — but it is the wrong tool for a flag on a
 * handful of photos. It walks every tile in the score grid and the All Photos
 * window, and every cell of every open group, and `decorateTile` rewrites each
 * one's accessible name. On a grid holding thousands of loaded tiles, favouriting
 * one photo repainted the entire interface to change one heart, which is a visible
 * hitch on a long scroll.
 *
 * So the affected tiles are looked up by their own `data-id` and repainted on
 * their own. Everything that reads the flag — the heart, the accessible name — is
 * inside `decorateTile`, so there is one place that knows how a favourite looks
 * and this only decides *which* tiles ask it to redraw.
 *
 * The selection bar is still refreshed, because its protected-favourite count does
 * depend on this flag. It is one element rather than a grid, so it costs nothing
 * next to what was saved.
 *
 * @return the ids that were actually found on screen, so a caller can narrow
 *         anything else it owns — the lightbox button, for one.
 */
  function applyFavoriteState(ids, favorite, confirmed) {
    if (!confirmed) return [];
    const wanted = new Set(ids);
    const patch = (rows) => rows.forEach((row) => {
      if (wanted.has(row.id)) row.favorite = favorite;
    });
    patch(state.items);
    patch(state.all.rows);
    // The group strips hold their own copies of the flag, so they are patched too.
    // Without this a heart pressed inside a strip would write the change to Photos
    // and leave the strip's own row — and therefore the glyph — reading the old
    // state, so a second press would ask for the change it had just made.
    for (const group of state.groups.rows) patch(groupItems(group));
    refreshTilesById(wanted);
    updateSelectionBar();
    return ids;
  }

  /**
   * Repaints the tiles and group cells for a set of identifiers, and nothing else.
   *
   * Lookup is by `data-id`, never by position. The All Photos window prepends pages
   * and renumbers every index below them, so an index-based repaint would silently
   * restyle the wrong photo — the same reason the menu reads its index from the DOM.
   */
  function refreshTilesById(ids) {
    if (!ids || ids.size === 0) return;
    // Both grids address their rows by the index the tile carries, which is the only
    // thing they can both agree on now that the All Photos document order and its
    // array order have diverged.
    for (const tile of $('grid').querySelectorAll('.tile')) {
      if (ids.has(tile.dataset.id)) decorateTile(tile, state.items[Number(tile.dataset.index)]);
    }
    const allRows = state.all.rows;
    $('allPhotosDays').querySelectorAll('.tile').forEach((tile) => {
      if (ids.has(tile.dataset.id)) decorateTile(tile, allRows[Number(tile.dataset.index)]);
    });
    refreshGroupCellsById(ids);
  }

  /**
   * The group-strip half of `refreshTilesById`.
   *
   * A group cell is not a grid tile and does not go through `decorateTile`, so the
   * heart and the selection ring are applied here from one source of truth. The
   * per-cell work is shared with `refreshGroups` so the two cannot drift.
   */
  function refreshGroupCellsById(ids) {
    if (!state.groups.active) return;
    for (const cell of $('groupsList').querySelectorAll('.group-cell')) {
      if (ids.has(cell.dataset.id)) paintGroupCell(cell);
    }
  }

  /** The one place a group cell's marks are decided. */
  function paintGroupCell(cell) {
    const card = cell.closest('.group-card');
    if (!card) return;
    const group = state.groups.rows.find((row) => row.id === card.dataset.id);
    const row = group && groupItems(group)[Number(cell.dataset.index)];
    if (!row) return;
    // The selection ring, because clicking a cell now selects it. Without this a
    // click would look like it did nothing at all until the bar's count moved, and
    // a selection you cannot see is not a selection.
    const selected = isSelected(row.id);
    cell.classList.toggle('selected', selected);
    cell.setAttribute('aria-pressed', selected ? 'true' : 'false');
    const heart = cell.querySelector('.group-heart');
    // Repainted, never added or removed: the heart is a control now, so it is in
    // the cell from the start and a photo that is not a favourite shows it as an
    // outline rather than having no heart at all. An earlier version removed the
    // node outright, which meant the group strip could not set the flag from the
    // photo — the very thing the heart is there to do.
    if (heart) decorateHeart(heart, row);
  }

  /* -------------------------------------------------------------- selection */

  function onTileClick(row, index, event, list) {
    // The synthetic click after a touch long-press. Swallowed here so holding a
    // finger on a tile opens the menu and leaves the selection alone, exactly
    // as a right-click does.
    if (suppressNextTileClick) {
      suppressNextTileClick = false;
      event.preventDefault();
      event.stopPropagation();
      return;
    }
    if (event.shiftKey && state.anchorIndex >= 0 && index !== state.anchorIndex) {
      // Delegated to the same helper the menu's "Select range" item calls, so the
      // keyboard path and the menu cannot drift apart. In matching mode the range
      // is a range of *exclusions*; in ids mode a range of additions. Either way
      // it never silently grows "all matching".
      selectRangeTo(index, list);
      return;
    }
    state.anchorIndex = index;
    toggleSelection(row.id);
  }

  function toggleSelection(id) {
    const selection = state.selection;
    if (selection.mode === 'matching') {
      if (selection.excluded.has(id)) selection.excluded.delete(id);
      else selection.excluded.add(id);
    } else if (selection.ids.has(id)) {
      selection.ids.delete(id);
    } else {
      selection.ids.add(id);
    }
    refreshAllTiles();
    refreshSelectionPreview();
  }

  function isSelected(id) {
    const selection = state.selection;
    if (selection.mode === 'matching') return !selection.excluded.has(id);
    return selection.ids.has(id);
  }

  function selectionHasContent() {
    const selection = state.selection;
    if (selection.mode === 'matching') return Boolean(selection.filter);
    return selection.ids.size > 0;
  }

  function selectionSpec() {
    const selection = state.selection;
    if (selection.mode === 'matching' && selection.filter) {
      return { mode: 'matching', filter: { ...selection.filter }, exclude: [...selection.excluded] };
    }
    return { mode: 'ids', ids: [...selection.ids] };
  }

  /** True when the live filter has drifted away from a snapshotted "all matching". */
  function selectionStale() {
    const selection = state.selection;
    return selection.mode === 'matching' && Boolean(selection.filter) && !sameFilter(selection.filter, currentFilter());
  }

  /**
   * The count shown in the bar is always the server's own answer from
   * `/api/selection/preview` — the client never guesses how many photos a
   * filter resolves to, because favourite protection and unparsed identifiers
   * are decided server-side.
   *
   * The same response carries `confirmToken`, the fingerprint of the set the
   * server resolved, and it is kept on the selection because the deletion sends
   * it back. That is what makes the count a promise rather than an estimate: if
   * the library resolves to something else by the time Delete is pressed, the
   * server refuses instead of destroying a set nobody was shown.
   */
  /** Forgets what the server last resolved for a selection, leaving the set itself. */
  function clearResolved(selection) {
    selection.resolved = 0;
    selection.protectedFavorites = 0;
    selection.unknownIdentifiers = 0;
    selection.truncated = false;
    selection.confirmToken = '';
  }

  function refreshSelectionPreview() {
    clearTimeout(state.previewTimer);
    const token = ++state.previewToken;
    state.previewTimer = setTimeout(async () => {
      const selection = state.selection;
      const spec = selectionSpec();
      if (spec.mode === 'ids' && spec.ids.length === 0) {
        clearResolved(selection);
        updateSelectionBar();
        return;
      }
      const { ok, payload } = await api.post('/api/selection/preview', spec);
      if (token !== state.previewToken) return; // a newer selection won
      if (!ok) {
        // A failed resolution counts as no resolution. Leaving the previous
        // selection's numbers in place would leave the Delete button armed over a
        // set whose count nobody has confirmed, and would carry the old
        // fingerprint into the next deletion — which the server would refuse, so
        // the press would fail rather than delete, but with a count on the button
        // that belonged to a selection the reader has already moved on from.
        clearResolved(selection);
        updateSelectionBar();
        toast('Could not resolve the selection — ' + errorText(payload, 'the server refused'), 'error');
        return;
      }
      selection.resolved = Number(payload.resolved) || 0;
      selection.protectedFavorites = Number(payload.protectedFavorites) || 0;
      selection.unknownIdentifiers = Number(payload.unknownIdentifiers) || 0;
      selection.truncated = payload.truncated === true;
      selection.confirmToken = typeof payload.confirmToken === 'string' ? payload.confirmToken : '';
      updateSelectionBar();
    }, SELECTION_PREVIEW_DEBOUNCE_MS);
  }

  function errorText(payload, fallback) {
    if (payload && typeof payload.error === 'string' && payload.error) return payload.error;
    return fallback;
  }

  function updateSelectionBar() {
    const selection = state.selection;
    const summary = $('selectionSummary');
    const stale = selectionStale();
    summary.replaceChildren();

    const emphasize = (count) => {
      const strong = document.createElement('span');
      strong.className = 'emphasis';
      strong.textContent = fmt.count(count);
      return strong;
    };

    if (stale) {
      summary.appendChild(document.createTextNode('Selection is out of date'));
      summary.appendChild(document.createTextNode(' — the filter changed after you selected every match. Nothing has changed about what would be deleted until you say so.'));
      $('clearSelection').disabled = false;
      $('selectAllMatching').textContent = 'Update selection to current filter';
      $('selectAllMatching').disabled = false;
      $('selectionHint').textContent = 'Deletion is blocked: the saved filter is no longer the filter on screen.';
      // The Delete button's state is owned entirely by `updateDeleteButton`,
      // which knows about the selection and about whether a deletion is in
      // flight. Calling it here rather than setting `disabled` by hand is what
      // keeps one function the only writer of that property.
      updateDeleteButton();
      return;
    }

    $('selectAllMatching').textContent = selection.mode === 'matching'
      ? 'Select all matching again'
      : 'Select all matching';
    $('selectAllMatching').disabled = !boundsUsable();

    // What the selection actually holds, named by the media filter in force.
    // A set snapshotted under "Photos" can only be photos, so saying "asset"
    // there would be the safe-but-vague choice; but on the default mixed view it
    // would be a falsehood in the other direction, so the noun follows the filter.
    const noun = mediaNoun();
    if (selection.mode === 'matching') {
      summary.appendChild(document.createTextNode(selection.truncated ? 'Up to ' : 'All '));
      summary.appendChild(emphasize(selection.resolved));
      summary.appendChild(document.createTextNode(
        ` ${fmt.plural(selection.resolved, `${noun} matches`, `${noun}s match`)} the saved filter`));
      // "Up to" rather than "All" when the server capped the resolution: the count
      // is then a ceiling, and the sentence has to read as one.
      $('selectionHint').textContent = selection.truncated
        ? `More ${noun}s match than PhotoCleaner will resolve at once`
          + ' · Click one to exclude it'
        : `Click a ${noun} to exclude it · This covers every match, not just the loaded page`;
    } else if (selection.ids.size > 0) {
      summary.appendChild(emphasize(selection.ids.size));
      summary.appendChild(document.createTextNode(
        ` ${fmt.plural(selection.ids.size, noun, `${noun}s`)} selected`));
      $('selectionHint').textContent = 'Click to select · Shift-click for a range · ⌫ or Delete deletes the selection';
    } else {
      summary.appendChild(document.createTextNode('Nothing selected'));
      $('selectionHint').textContent = 'Click to select · Shift-click for a range · ⌫ or Delete deletes the selection';
    }

    // The two reasons the button's count can be lower than the bar's, stated where
    // the bar is: one is a setting the reader can see and turn off, and the other
    // is a photo that has left the library since the page that named it was
    // loaded. Neither is left for the reader to reconcile on their own.
    const shortfalls = [];
    if (selection.protectedFavorites > 0) {
      shortfalls.push(`${fmt.count(selection.protectedFavorites)} protected `
        + `${fmt.plural(selection.protectedFavorites, 'favorite', 'favorites')} excluded`);
    }
    if (selection.unknownIdentifiers > 0) {
      shortfalls.push(`${fmt.count(selection.unknownIdentifiers)} no longer in `
        + 'PhotoCleaner');
    }
    if (shortfalls.length) {
      const note = document.createElement('span');
      note.className = 'muted';
      note.style.marginLeft = '10px';
      note.textContent = `· ${shortfalls.join(' · ')}`;
      summary.appendChild(note);
    }

    // The Delete button destroys whatever is selected, so its state is a function
    // of the selection and of whether a deletion is already in flight.
    updateDeleteButton();
    $('clearSelection').disabled = !selectionHasContent();
  }

  /**
   * Snapshots the live filter into the selection.
   *
   * This is also the "update selection to current filter" action when the
   * selection has gone stale, which is why it re-reads `currentFilter()` every
   * time rather than reusing a stored copy. It is the *only* path that can put
   * the selection back in sync, so "all matching" can never drift silently.
   */
  function selectAllMatching() {
    const selection = state.selection;
    selection.mode = 'matching';
    selection.filter = currentFilter();
    selection.ids = new Set();
    selection.excluded = new Set();
    clearResolved(selection);
    state.previewToken += 1; // abandon any preview still in flight for the old selection
    clearTimeout(state.previewTimer);
    refreshAllTiles();
    refreshSelectionPreview();
  }

  function clearSelection() {
    state.selection = emptySelection();
    refreshAllTiles();
    updateSelectionBar();
  }

  /* --------------------------------------------------------------- delete UI */

  /** Returns focus to whatever opened the overlay, so the keyboard user is not
   *  dumped back at the top of the document. */
  function restoreFocus() {
    const previous = state.returnFocus;
    state.returnFocus = null;
    if (previous && typeof previous.focus === 'function') previous.focus();
  }

  /** Keeps Tab inside an open overlay instead of walking into the page behind it. */
  function trapTab(container, event) {
    if (event.key !== 'Tab') return;
    const focusable = container.querySelectorAll('button, input, select, textarea, [href], [tabindex]')
      .filter((node) => !node.disabled && node.tabIndex !== -1 && !node.hidden);
    if (focusable.length === 0) { event.preventDefault(); return; }
    const first = focusable[0];
    const last = focusable[focusable.length - 1];
    const active = document.activeElement;
    if (!container.contains(active)) { event.preventDefault(); first.focus(); return; }
    if (event.shiftKey && active === first) { event.preventDefault(); last.focus(); }
    else if (!event.shiftKey && active === last) { event.preventDefault(); first.focus(); }
  }

  /** The human name for an album wire value: a title, or the bucket's own name. */
  function albumName(value) {
    if (value === 'none') return 'no album';
    if (value === 'all') return 'all albums';
    const found = state.albums.list.find((a) => a.id === value);
    return found ? (found.title || '(untitled album)') : 'an album PhotoCleaner has not read';
  }

/* --------------------------------------------------------------- deletion */

  /**
   * Whether the selection may be destroyed right now.
   *
   * One predicate, read by both the button's label and the action behind it, so
   * the three can never disagree: what the button says it will destroy, what it
   * lets you press, and what the keyboard does are the same question asked once.
   *
   * `resolved > 0` is the load-bearing clause. The count comes from the server,
   * so until that answer has landed the client does not know how many photos a
   * press would destroy — and a deletion of unknown size is the one this button
   * refuses rather than guesses at, exactly as it would if the server could not
   * resolve the selection at all.
   */
  function canDeleteSelection() {
    return !state.deleting
      && !selectionStale()
      && selectionHasContent()
      && state.selection.resolved > 0;
  }

  /**
   * Repaints the Delete button.
   *
   * One state, because there is only one step: the button destroys the selection
   * now. The count on it is the server's own answer from
   * `/api/selection/preview`, because it is the last thing read before an
   * irreversible act and it must not be a number this client guessed. Favourites
   * held back by protection are already out of it, so "Delete 12 photos" means
   * twelve photos go.
   */
  function updateDeleteButton() {
    const button = $('deleteButton');
    if (state.deleting) {
      button.disabled = true;
      button.textContent = 'Deleting…';
      button.title = 'Sending the deletion to Photos.';
      return;
    }
    const count = state.selection.resolved;
    const live = canDeleteSelection();
    button.disabled = !live;
    // The noun follows the media filter, because this button is about to delete
    // whatever the selection resolved to — and on the default mixed view that can
    // be clips as well as photos. "Delete 4 photos" over a set that includes two
    // videos is a miscount of what is about to be destroyed.
    const noun = mediaNoun();
    button.textContent = live
      ? `Delete ${fmt.count(count)} ${fmt.plural(count, noun, `${noun}s`)}`
      : 'Delete';
    button.title = selectionStale()
      ? 'Blocked: the saved filter is no longer the filter on screen.'
      : 'Delete the selection through Photos. This cannot be undone.';
  }

  /**
   * Destroys whatever is selected, carrying the fingerprint the preview produced.
   *
   * This is the one path that offers a `confirmToken`, and it is the one where it
   * earns its keep: the bar is where a large count is printed, and the token is
   * what makes that count binding. If the library resolves to something else by
   * the time the button is pressed, the server refuses rather than destroying a
   * set nobody was shown.
   */
  function deleteSelection() {
    if (!canDeleteSelection()) return;
    const spec = selectionSpec();
    if (state.selection.confirmToken) spec.confirmToken = state.selection.confirmToken;
    deletePhotos(spec);
  }

  /**
   * The one and only call to `/api/delete`.
   *
   * Reached from the Delete button, from ⌫, from a tile menu's item and from the
   * lightbox. None of them asks for a confirmation: each is a named control
   * carrying the count of what it destroys, so the irreversible act is the thing
   * the user pressed rather than a further step they have to find. The guard
   * against destroying a *different* set than the one agreed is the server's, in
   * `confirmToken`, where it can actually be enforced.
   *
   * Nothing is removed optimistically — the grid is reloaded after the server has
   * said what it did, so what is on screen is what Photos holds.
   */
  async function deletePhotos(spec) {
    if (state.deleting) return;
    if (!spec || (spec.mode === 'ids' && (!spec.ids || spec.ids.length === 0))) return;
    state.deleting = true;
    updateDeleteButton();

    const { ok, payload } = await api.post('/api/delete', spec);
    state.deleting = false;

    const report = payload || {};
    const deleted = Number(report.deleted) || 0;
    const missing = Number(report.missing) || 0;
    const protectedFavorites = Number(report.protectedFavorites) || 0;
    const errors = Array.isArray(report.errors) ? report.errors.filter(Boolean) : [];
    // A refused request carries a sentence rather than a report, and a 409 — the
    // fingerprint no longer matching — is the one worth naming exactly, because it
    // means the library moved between the count that was read and the click.
    const reason = errors.length
      ? errors.slice(0, 3).join('; ') + (errors.length > 3 ? ` (+${errors.length - 3} more)` : '')
      : errorText(report, 'the server refused the request');

    if (deleted === 0) {
      toast(`Nothing was deleted — ${reason}`, 'error');
      // The selection is left exactly as it was and re-resolved, so the number on
      // the button becomes the server's current answer instead of the one the
      // refusal was about, and the user can decide again on a fresh count.
      refreshSelectionPreview();
      updateDeleteButton();
      return;
    }

    // Past tense: this reports what is *gone*, and "assets" reads as bureaucratic in
    // a sentence about a deletion the user just chose. The singular is the noun the
    // filter gives us minus its plural, so "photos" → "photo", "assets" → "asset".
    const past = mediaNoun().replace(/s$/, '');
    let message = `Deleted ${fmt.count(deleted)} ${fmt.plural(deleted, past, `${past}s`)} through Photos.`;
    if (missing > 0) message += ` ${fmt.count(missing)} ${fmt.plural(missing, 'was', 'were')} already gone.`;
    if (protectedFavorites > 0) {
      message += ` ${fmt.count(protectedFavorites)} protected ${fmt.plural(protectedFavorites, 'favorite', 'favorites')} kept.`;
    }
    // The filter matched more than one resolution returns, so the number just
    // reported is how many were destroyed and not how many there were. Saying so
    // is the difference between a count and a claim.
    if (report.truncated === true) {
      message += ' More photos matched than PhotoCleaner resolves at once, so this was a subset.';
    }
    // One toast, not two: the element holds a single line, and a second call
    // would replace the count with a sentence and lose the count.
    toast(message, (errors.length || !ok) ? 'warning' : 'info');

    // Only now is the grid allowed to change: nothing above this line touched it.
    clearSelection();
    closeLightbox();
    // The window is rebuilt around its anchor, not thrown away: the photos the
    // user just destroyed were part of the series they were looking at.
    if (state.all.active) await reopenAllPhotosAfterDelete(spec);
    // The group strip is not the grid, so `resetGrid` below never touches it — a
    // member destroyed from a group's own menu would otherwise stay on screen,
    // still selectable and still offering a Delete for a photo that is gone. The
    // whole window is re-read rather than the cell patched out, because a group
    // whose members have all been deleted is itself gone.
    if (state.groups.active) await resetGroupsWindow();
    await resetGrid();
    await refreshStatus();
  }

  /* -------------------------------------------------------------- all photos */

  /**
   * Photos.app's "All Photos", scoped to what PhotoCleaner can honestly show:
   * every photo it has *scored*, in reverse-chronological order, grouped by day.
   * The aesthetics score takes no part in the ordering — the point is to see a
   * photo among its neighbours, not to rank them — so the query is bounded by
   * the observed extremes only, never by the score slider or the album filter.
   *
   * Assets PhotoCleaner has never scored have no `creation_date`-ordered row in
   * the cache's page query at all, so they are absent here; the bar says how
   * many of the library's photos those are rather than quietly implying the
   * window is the whole library.
   */
  async function openAllPhotos(id) {
    const all = state.all;
    if (!boundsUsable()) {
      toast('PhotoCleaner has not scored anything yet, so there is no timeline to show.', 'warning');
      return false;
    }
    // The score grid is about to be hidden, so a menu anchored to a tile in it
    // would be left floating over a view it no longer belongs to.
    closeTileMenu();
    // Same reasoning one level down: a group cell's menu goes with the group view,
    // or it would be left pointing at a photo the user can no longer see. The
    // group view is reachable from here now that "Show Similar Photos" exists.
    //
    // `leave: true` because this *replaces* the group view rather than unwinding
    // it. Left to unwind, `closeGroups` would do the right thing for Back — return
    // to the group list — which is the wrong thing here: it would keep the group
    // view active and on screen underneath the window now being opened, and both
    // `state.groups.active` and `state.all.active` would be true at once.
    if (state.groups.active) closeGroups({ leave: true });
    // Captured before anything is hidden: the grid's DOM is untouched while the
    // window is open, so this offset is still exactly right on the way back.
    all.returnScrollY = window.scrollY;
    all.returnFocusId = id;
    all.active = true;
    const generation = ++all.generation;
    all.anchorId = id;
    all.anchorRow = null;
    all.anchorIndex = -1;
    all.rows = [];
    all.groups = new Map();
    all.olderCursor = null;
    all.newerCursor = null;
    all.olderEnd = false;
    all.newerEnd = false;
    all.total = 0;
    all.loadingOlder = false;
    all.loadingNewer = false;
    all.note = 'Loading the photos around this one…';

    $('controlPanel').hidden = true;
    $('grid').hidden = true;
    $('emptyState').hidden = true;
    $('sentinel').hidden = true;
    $('loadMore').hidden = true;
    $('allPhotosBar').hidden = false;
    $('allPhotosView').hidden = false;
    $('allPhotosDays').replaceChildren();
    $('selectionHint').textContent =
      'Same selection as the grid · Shift-click for a range · ⌫ deletes the selection · Esc goes back';
    window.scrollTo(0, 0);
    renderAllPhotosBar();
    renderAllPhotosStatus();

    try {
      const params = new URLSearchParams({ id, limit: String(ALL_PHOTOS_PAGE) });
      const data = await api.get('/api/timeline/around?' + params.toString());
      if (generation !== all.generation || !all.active) return false;
      if (!data || !data.anchor || !data.anchor.id) { closeAllPhotos(); return false; }
      all.anchorRow = data.anchor;
      all.total = Number(data.total) || 0;
      const older = (Array.isArray(data.older && data.older.items) ? data.older.items : []).filter(Boolean);
      const newer = (Array.isArray(data.newer && data.newer.items) ? data.newer.items : []).filter(Boolean);
      all.olderCursor = (data.older && data.older.nextCursor) || null;
      all.newerCursor = (data.newer && data.newer.nextCursor) || null;
      all.olderEnd = all.olderCursor === null;
      all.newerEnd = all.newerCursor === null;
      // The server pages *ascending* from the anchor for the newer side, because
      // that is the keyset direction; display order is the other way round.
      const newerForDisplay = newer.slice().reverse();
      all.rows = [...newerForDisplay, data.anchor, ...older];
      all.anchorIndex = newerForDisplay.length;
      all.note = '';
      renderAllPhotosRows(entriesFrom(all.rows, 0));
      renderAllPhotosBar();
      renderAllPhotosStatus();
      scrollAllPhotosIntoView(all.anchorIndex, { block: 'center' });
      fillAllPhotosMargin(generation);
      return true;
    } catch (error) {
      if (generation !== all.generation) return false;
      closeAllPhotos();
      toast('Could not open All Photos — ' + error.message, 'error');
      return false;
    }
  }

  /**
   * Leaves the window and puts the grid back exactly as it was.
   *
   * Losing the user's place in a 53,000-photo grid is the worst thing this
   * feature could do, so this restores the scroll offset *and* the focus, and
   * never clears the grid's DOM in the first place — the offset it returns to is
   * therefore still valid rather than approximated.
   */
  function closeAllPhotos() {
    const all = state.all;
    if (!all.active) return;
    closeLightbox();
    // The window is about to be torn down, so a menu anchored to one of its
    // tiles goes with it.
    closeTileMenu();
    all.active = false;
    all.generation += 1; // abandon any page still in flight
    all.rows = [];
    all.groups = new Map();
    all.anchorRow = null;
    all.note = '';
    $('allPhotosView').hidden = true;
    $('allPhotosDays').replaceChildren();
    $('controlPanel').hidden = false;
    $('grid').hidden = false;
    $('sentinel').hidden = false;
    renderEmptyState();
    updateLoadMore();
    updateSelectionBar();
    // Force the grid back into flow before scrolling: `scrollTo` is clamped to
    // the current document height, which is only correct once the layout is done.
    void $('grid').offsetHeight;
    const target = all.returnScrollY;
    window.scrollTo(0, target);
    requestAnimationFrame(() => {
      // Focus first, with scrolling suppressed, then place the scroll — the other
      // order lets `focus()` win and undo the restore.
      const tile = $('grid').querySelector(`.tile[data-id="${CSS.escape(all.returnFocusId)}"]`);
      if (tile) tile.focus({ preventScroll: true });
      window.scrollTo(0, state.all.returnScrollY);
    });
  }

  /**
   * Fetches one more page of the window, in one direction.
   *
   * The cursor is the server's own opaque keyset token, taken from the page
   * before it — the client never constructs one, so it cannot get the sort
   * semantics wrong. Returns how many rows were added, so the lightbox can
   * correct its index after a prepend.
   */
  async function loadAllPhotosPage(direction, { keepScroll = true } = {}) {
    const all = state.all;
    const generation = all.generation;
    const flag = direction === 'older' ? 'loadingOlder' : 'loadingNewer';
    const cursor = direction === 'older' ? all.olderCursor : all.newerCursor;
    if (!all.active || all[flag] || !cursor) return 0;
    all[flag] = true;
    renderAllPhotosStatus();
    try {
      const params = new URLSearchParams({ direction, cursor, limit: String(ALL_PHOTOS_PAGE) });
      const data = await api.get('/api/timeline/page?' + params.toString());
      if (generation !== all.generation || !all.active) return 0;
      const rows = (Array.isArray(data.items) ? data.items : []).filter((row) => row && row.id);
      const next = data.nextCursor || null;
      if (direction === 'older') {
        all.olderCursor = next;
        all.olderEnd = next === null;
      } else {
        all.newerCursor = next;
        all.newerEnd = next === null;
      }
      all.total = Number(data.total) || all.total;
      if (!rows.length) return 0;
      const atTop = direction === 'newer';
      const base = atTop ? 0 : all.rows.length;
      // A newer page arrives ascending from the anchor; display order is newest
      // first, so it is reversed before anything is spliced in.
      const ordered = atTop ? rows.slice().reverse() : rows;
      all.rows = atTop ? [...ordered, ...all.rows] : [...all.rows, ...ordered];
      all.anchorIndex = atTop ? all.anchorIndex + ordered.length : all.anchorIndex;
      if (atTop) state.lightbox.queue = all.rows;
      renderAllPhotosRows(entriesFrom(ordered, base), { top: atTop, keepScroll });
      renderAllPhotosBar();
      return ordered.length;
    } catch (error) {
      if (generation === all.generation) toast('Could not load more photos — ' + error.message, 'error');
      return 0;
    } finally {
      if (generation === all.generation) {
        all[flag] = false;
        renderAllPhotosStatus();
      }
    }
  }

  /**
   * ← and → inside the window.
   *
   * Older is "next" (index + 1) because the window runs newest first, so it
   * walks towards the index end; at either end it fetches another page, which
   * for the newer side shifts every index down by the number of rows added.
   */
  async function navigateAllPhotosLightbox(delta) {
    const lightbox = state.lightbox;
    if (!lightbox.open || !lightbox.allPhotos) return;
    let index = lightbox.index;
    // Bounded: a stalled fetch must not spin here.
    for (let attempts = 0; index + delta < 0 || index + delta >= lightbox.queue.length; attempts += 1) {
      if (attempts >= 5) { toast('Could not load more photos — try again in a moment.', 'error'); return; }
      const older = index + delta >= lightbox.queue.length;
      const added = await loadAllPhotosPage(older ? 'older' : 'newer', { keepScroll: false });
      if (state.lightbox !== lightbox || !lightbox.open) return; // closed while loading
      if (added === 0) {
        toast(older
          ? 'That is the oldest photo PhotoCleaner has scored.'
          : 'That is the newest photo PhotoCleaner has scored.');
        return;
      }
      if (!older) index -= added;
    }
    lightbox.queue = state.all.rows;
    const next = index + delta;
    if (next < 0 || next >= lightbox.queue.length) { renderLightbox(); return; }
    lightbox.index = next;
    renderLightbox();
    scrollAllPhotosIntoView(lightbox.index);
  }

  /* ------------------------------------------------- all photos: presentation */

  const entriesFrom = (rows, base) => rows.map((row, offset) => ({ row, index: base + offset }));

  /**
   * Splits a run of rows into calendar days and splices them into the window.
   *
   * A page boundary can land inside a day — a burst of shots spans pages — so a
   * group is looked up by its key and reused instead of being closed and
   * reopened, which would otherwise render one day twice with two headings.
   */
  function renderAllPhotosRows(entries, { top = false, keepScroll = true } = {}) {
    const host = $('allPhotosDays');
    const groups = state.all.groups;
    // Prepending pushes everything down; remember the height so the photo the
    // user is looking at can be put back under the cursor afterwards.
    const heightBefore = document.documentElement.scrollHeight;
    const scrollBefore = window.scrollY;

    for (const bucket of bucketByDay(entries)) {
      let group = groups.get(bucket.key);
      if (!group) {
        group = buildDayGroup(bucket.label);
        groups.set(bucket.key, group);
        if (top) host.prepend(group.section);
        else host.appendChild(group.section);
      }
      const fragment = document.createDocumentFragment();
      for (const entry of bucket.entries) {
        fragment.appendChild(buildTile(entry.row, entry.index, {
          list: () => state.all.rows,
          allPhotos: true,
          anchor: entry.row.id === state.all.anchorId,
        }));
      }
      if (top) group.grid.insertBefore(fragment, group.grid.firstChild);
      else group.grid.appendChild(fragment);
    }

    // A prepend shifts every window index below it, and the tiles already on
    // screen were built against the old ones. They are restamped by *the shift*,
    // not by their position in the document.
    //
    // It used to be restamped by document position, which is the same number only
    // while the DOM holds every row in the window. Restamping by position would
    // quietly relabel every photo above the splice with its neighbour's index.
    if (top) {
      const shift = entries.length;
      if (shift > 0) {
        $('allPhotosDays').querySelectorAll('.tile').forEach((tile) => {
          tile.dataset.index = String(Number(tile.dataset.index) + shift);
        });
      }
    }

    if (top && keepScroll) {
      const delta = document.documentElement.scrollHeight - heightBefore;
      if (delta) window.scrollTo(0, scrollBefore + delta);
    }
  }

  function buildDayGroup(label) {
    const section = document.createElement('section');
    section.className = 'day';
    const heading = document.createElement('h2');
    heading.className = 'day-heading';
    heading.textContent = label;
    const grid = document.createElement('div');
    grid.className = 'grid';
    section.append(heading, grid);
    return { section, grid };
  }

  /** Groups consecutive rows by calendar day, preserving display order. */
  function bucketByDay(entries) {
    const buckets = [];
    let current = null;
    for (const entry of entries) {
      const heading = dayHeading(entry.row.date);
      if (!current || current.key !== heading.key) {
        current = { key: heading.key, label: heading.label, entries: [] };
        buckets.push(current);
      }
      current.entries.push(entry);
    }
    return buckets;
  }

  /**
   * Photos.app-style heading for one calendar day.
   *
   * The unit steps up as the dates get older, which is what makes a decade of
   * photographs readable: today, yesterday, a named weekday inside this year,
   * and a plain month once the year itself is what distinguishes one group from
   * the next.
   */
  function dayHeading(seconds) {
    const undated = { key: 'undated', label: 'Date unknown' };
    if (seconds === null || seconds === undefined) return undated;
    const date = new Date(Number(seconds) * 1000);
    if (Number.isNaN(date.getTime())) return undated;
    const now = new Date();
    const midnight = (value) => new Date(value.getFullYear(), value.getMonth(), value.getDate()).getTime();
    const days = Math.round((midnight(now) - midnight(date)) / 86_400_000);
    if (date.getFullYear() === now.getFullYear()) {
      const key = `${date.getFullYear()}-${date.getMonth() + 1}-${date.getDate()}`;
      if (days === 0) return { key, label: 'Today' };
      if (days === 1) return { key, label: 'Yesterday' };
      return { key, label: date.toLocaleDateString(undefined, { weekday: 'long', day: 'numeric', month: 'long' }) };
    }
    return {
      key: `${date.getFullYear()}-${date.getMonth() + 1}`,
      label: date.toLocaleDateString(undefined, { month: 'long', year: 'numeric' }),
    };
  }

  function scrollAllPhotosIntoView(index, options = { block: 'center' }) {
    if (!state.all.active || !Number.isFinite(index) || index < 0) return;
    const tile = $('allPhotosDays').querySelector(`.tile[data-index="${index}"]`);
    if (tile) tile.scrollIntoView(options);
  }

  function renderAllPhotosBar() {
    const all = state.all;
    const parts = [];
    if (all.anchorRow) parts.push(`around ${fmt.date(all.anchorRow.date)}`);
    parts.push(`${fmt.count(all.rows.length)} loaded of ${fmt.count(all.total)} scored`);
    const analysis = state.status ? state.status.analysis : null;
    // Say plainly what the window does *not* contain: photos PhotoCleaner has
    // never scored are not in the chronological ordering at all.
    if (analysis) parts.push(`${fmt.count(analysis.analyzed)} of ${fmt.count(analysis.total)} library photos scored`);
    $('allPhotosMeta').textContent = parts.join(' · ');
  }

  /** Status line and the two end-of-timeline markers. */
  function renderAllPhotosStatus() {
    const all = state.all;
    $('allPhotosNewerEnd').hidden = !all.newerEnd;
    $('allPhotosOlderEnd').hidden = !all.olderEnd;
    const newerText = all.loadingNewer ? 'Loading newer photos…' : (all.rows.length ? '' : all.note);
    const olderText = all.loadingOlder ? 'Loading older photos…' : '';
    $('allPhotosNewerNote').textContent = newerText;
    $('allPhotosNewerNote').hidden = !all.active || !newerText;
    $('allPhotosOlderNote').textContent = olderText;
    $('allPhotosOlderNote').hidden = !all.active || !olderText;
  }

  /** True when the All Photos *bottom* sentinel is near enough below to fill. */
  function allPhotosBottomInView() {
    return $('allPhotosOlderSentinel').getBoundingClientRect().top < window.innerHeight + ALL_PHOTOS_MARGIN;
  }

  /** True when the All Photos *top* sentinel is near enough above to fill. */
  function allPhotosTopInView() {
    return $('allPhotosNewerSentinel').getBoundingClientRect().bottom > -ALL_PHOTOS_MARGIN;
  }

  /**
   * A window that opens onto a small viewport can need more than one page per
   * side. One extra round each way after the first page lands, bounded by the
   * cursors so it cannot loop.
   */
  function fillAllPhotosMargin(generation) {
    requestAnimationFrame(() => {
      if (generation !== state.all.generation || !state.all.active) return;
      if (allPhotosBottomInView()) loadAllPhotosPage('older');
      if (allPhotosTopInView()) loadAllPhotosPage('newer');
    });
  }

  /**
   * A deletion invalidates the window: those photos are gone from Photos, and
   * the anchor may be one of them. Re-open so the user is not left looking at
   * ghosts — but keep them *in* the view, because being thrown back to the top
   * of the grid is the failure this feature exists to avoid.
   */
  async function reopenAllPhotosAfterDelete(spec) {
    const all = state.all;
    const asked = new Set(spec.mode === 'ids' ? spec.ids || [] : []);
    let anchorId = all.anchorId;
    if (!anchorId || asked.has(anchorId)) {
      // The anchor itself went, so fall back to a loaded row that was not part of
      // the deletion: the server has no row for it any more.
      const survivor = all.rows.find((row) => !asked.has(row.id));
      anchorId = survivor ? survivor.id : '';
    }
    if (anchorId && await openAllPhotos(anchorId)) return;
    toast('That photo is no longer in PhotoCleaner — back to the grid.', 'warning');
    closeAllPhotos();
  }

  /* ------------------------------------------------- preview open/close travel */

  /**
   * The photograph travels between its tile and the preview instead of appearing.
   *
   * Photos does this, and the reason is not decoration. A grid of thumbnails to a
   * single large image and back changes the light on the screen by most of its
   * range in one frame, and the eye reads that as a flash — which a fast Space
   * toggle turns into a flicker. Growing the photo while the backdrop dims gives
   * the eye something continuous to follow, and closing plays the same motion
   * backwards so the two ends match.
   *
   * What travels is a copy of the image already on screen, never the preview
   * itself: the preview is a 2048px JPEG that has not been requested yet, and
   * animating toward a bitmap that does not exist would mean animating the absence
   * of one. So the thumbnail makes the trip, and the two cross-fade once the real
   * bitmap has decoded underneath it.
   */

  /** Travel time. Mirrored by `.preview-ghost`'s transition in the stylesheet. */
  const PREVIEW_TRAVEL_MS = 300;
  /** The thumbnail handing over to the real preview: one cross-fade, this long. */
  const PREVIEW_HANDOFF_MS = 120;
  /**
   * A bound on waiting for a *clip*. A still is not on a timer at all: its own
   * walk through the renditions of it reports when there is a picture on the stage
   * (see `renderLightboxStill`), and one that is still coming down from iCloud
   * leaves the local rendition the grid was already drawing in place rather than an
   * empty stage holding a photograph that may never arrive.
   */
  const PREVIEW_DECODE_GRACE_MS = 2500;

  const previewTravel = {
    ghost: null,
    timers: [],
    source: null,
    /** The photograph the travelling copy flew from — see `renderLightbox`. */
    rowId: null,
    aspect: 0,
    travelled: false,
    decoded: false,
    settled: false,
  };

  const previewSoon = (fn, ms) => { previewTravel.timers.push(setTimeout(fn, ms)); };

  function previewClearTimers() {
    for (const timer of previewTravel.timers) clearTimeout(timer);
    previewTravel.timers = [];
  }

  /**
   * Takes the travelling photograph off the screen and stops everything waiting on
   * it.
   *
   * Both halves of a travel go through here, so a preview closed while it was still
   * arriving cannot leave a half-finished copy of itself floating over the grid
   * with an overlay fading in behind it — and neither can start while another is
   * still in flight.
   */
  function previewDropGhost() {
    previewClearTimers();
    if (previewTravel.ghost) previewTravel.ghost.remove();
    previewTravel.ghost = null;
    previewTravel.rowId = null;
    $('lightbox').classList.remove('lightbox-entering');
  }

  /**
   * Forgets where the last travel was, so the next one starts from nothing.
   *
   * The shape goes with the tile it was measured from: they are one piece of
   * information, and a shape left behind from a photograph that is no longer the one
   * on screen would quietly mis-frame the next travel.
   */
  function previewForget() {
    previewTravel.source = null;
    previewTravel.aspect = 0;
  }

  /**
   * The photograph on screen for this id, wherever it is: the score grid, the All
   * Photos window, or a group strip.
   *
   * Looked up from the id rather than handed down by the call sites, because five
   * different gestures open a preview — click, double click, Enter, Space, the
   * Inspect button — and every one of them would have to be trusted to pass the
   * right element along.
   *
   * Every copy is asked, not just the first: the score grid and the All Photos
   * window both hold their own tiles for a photo they have in common, and only one
   * of the two is on screen, so the first match in the document is the wrong one
   * half the time. A tile whose thumbnail failed, or one that lazy-loading has not
   * filled in yet, has no pixels to fly; those fall back to a plain fade rather
   * than a travel from an empty rectangle.
   */
  function previewSourceFor(id) {
    if (!id) return null;
    const copies = document.querySelectorAll(`[data-id="${CSS.escape(String(id))}"] img`);
    for (const image of copies) {
      if (!image.complete || !image.naturalWidth) continue;
      if (!image.getBoundingClientRect().width) continue; // on screen nowhere
      return image;
    }
    return null;
  }

  /**
   * The photograph's shape, which is what has to be right for a travel to land
   * square.
   *
   * The row knows the real dimensions; the thumbnail's own are the fallback for a
   * group response, which carries a score and a date and no size at all. A photo
   * that is neither is not given one — an assumed shape would zoom the picture into
   * a rectangle it never had.
   */
  function previewAspect(row, source) {
    const width = (row && row.width) || (source && source.naturalWidth);
    const height = (row && row.height) || (source && source.naturalHeight);
    return width && height ? width / height : 0;
  }

  /**
   * Where the photograph will sit once it has decoded: the box a photo of this
   * shape gets inside the stage, which is a fixed-size box in the stylesheet.
   *
   * Knowing this before the image arrives is the whole trick. The stage is pinned
   * to a height in the stylesheet precisely so that this is answerable while the
   * fetch is still in flight — and it is measured again on the way out, so a window
   * resized while the preview was open does not send the photograph back to a
   * rectangle that has since moved.
   */
  function previewTargetRect(aspect) {
    const stage = $('lightboxStage').getBoundingClientRect();
    if (!aspect || !stage.width || !stage.height) return null;
    let width = stage.width;
    let height = width / aspect;
    if (height > stage.height) {
      height = stage.height;
      width = height * aspect;
    }
    return {
      x: stage.left + (stage.width - width) / 2,
      y: stage.top + (stage.height - height) / 2,
      width,
      height,
    };
  }

  /**
   * The rectangle the travel starts from — or ends at, when the preview is closing.
   *
   * A grid that moved while the preview was open (a page landed in a live queue,
   * the All Photos window re-indexed) can leave the tile off screen entirely.
   * Flying to an off-screen rectangle reads as the photo leaving the window
   * altogether, so the travel ends at a small box in the middle instead: it still
   * shrinks, it just has nowhere to land.
   */
  function previewTileRect(source) {
    if (!source || !source.isConnected) return null;
    const tile = source.getBoundingClientRect();
    if (!tile.width || !tile.height) return null;
    const offscreen = tile.bottom < 0 || tile.top > window.innerHeight
      || tile.right < 0 || tile.left > window.innerWidth;
    if (offscreen) {
      const side = 96;
      return { x: window.innerWidth / 2 - side / 2, y: window.innerHeight / 2 - side / 2, width: side, height: side };
    }
    return { x: tile.left, y: tile.top, width: tile.width, height: tile.height };
  }

  /**
   * The transform that puts a photograph-sized box over its tile.
   *
   * One uniform scale about the centre, and the centre is the part that has to be
   * right: the tile crops this same photo to `cover` a square and the preview fits
   * all of it, so the two agree on the visible width and differ in how much of the
   * frame is on screen. Matching width rather than area keeps the photograph the
   * shape the user was just looking at, which is most of what makes the motion read
   * as one photo moving rather than one photo becoming another.
   */
  function previewTransform(target, tile, aspect) {
    const visible = tile.width >= tile.height * aspect ? tile.width : tile.height * aspect;
    const scale = target.width ? visible / target.width : 1;
    const dx = tile.x + tile.width / 2 - target.x - target.width / 2;
    const dy = tile.y + tile.height / 2 - target.y - target.height / 2;
    return `translate(${dx}px, ${dy}px) scale(${scale})`;
  }

  /** A copy of the photograph at its final size, to be transformed into place. */
  function previewGhost(target, bitmap) {
    const ghost = document.createElement('img');
    ghost.className = 'preview-ghost';
    // Purely a copy of something already on screen: announcing it would read the
    // photo out twice, and it is gone within a third of a second either way.
    ghost.setAttribute('aria-hidden', 'true');
    ghost.alt = '';
    ghost.src = bitmap;
    ghost.style.left = `${target.x}px`;
    ghost.style.top = `${target.y}px`;
    ghost.style.width = `${target.width}px`;
    ghost.style.height = `${target.height}px`;
    return ghost;
  }

  /**
   * Releases a ghost from its start pose.
   *
   * The start pose is held in inline styles and clearing them is what starts the
   * transition, so the element has to be *read* in between (hence `offsetWidth`):
   * without that flush the browser has only ever computed the destination, and a
   * transition with no previous value to come from does not run.
   */
  function previewRelease(ghost) {
    void ghost.offsetWidth;
    ghost.style.opacity = '';
    ghost.style.filter = '';
    ghost.style.transform = '';
  }

  function prefersReducedMotion() {
    return typeof window.matchMedia === 'function'
      && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  }

  /**
   * Starts the travel out of the tile and into the preview.
   *
   * Returns without doing anything when there is nothing to fly from, when there is
   * no layout to measure, or when the user has asked for less motion. Every caller
   * must work without it: a preview is a preview whether or not it animates.
   */
  function startPreviewTravel(row) {
    previewDropGhost();
    previewTravel.travelled = false;
    previewTravel.decoded = false;
    previewTravel.settled = false;
    previewTravel.rowId = row.id;
    const source = previewSourceFor(row.id);
    previewTravel.aspect = previewAspect(row, source);
    previewTravel.source = source;
    // Measured and checked before anything else is set up: with no tile and no stage
    // there is nowhere to fly to, and every caller has to work without the animation.
    const target = source ? previewTargetRect(previewTravel.aspect) : null;
    if (!target || prefersReducedMotion()) return;
    const tile = previewTileRect(source);
    if (!tile) return;
    const ghost = previewGhost(target, source.currentSrc || source.src);
    // Invisible until the release, so the thumbnail cannot arrive a frame late into
    // a photograph that is already a third of the way across the screen.
    ghost.style.opacity = '0';
    // The bloom the user asked for: the thumbnail is 256px of a 2048px photograph,
    // so it is lifted and briefly over-bright on the way out, which hides the
    // resolution it is going to lose.
    ghost.style.filter = 'brightness(1.28)';
    ghost.style.transform = previewTransform(target, tile, previewTravel.aspect);
    $('lightbox').classList.add('lightbox-entering');
    document.body.appendChild(ghost);
    previewTravel.ghost = ghost;
    previewRelease(ghost);
    previewSoon(() => { previewTravel.travelled = true; settlePreviewTravel(); }, PREVIEW_TRAVEL_MS);
    previewClipWhenDecoded();
  }

  /**
   * A clip is the one case that waits for something a still's own walk cannot
   * report.
   *
   * A photograph calls `previewMediaReady` the moment a rendition of it is on the
   * stage — that is `renderLightboxStill`'s job, and it knows because it is the
   * thing that put it there. A clip has no such walk: what arrives is metadata for
   * a media element, and waiting for that rather than for a bitmap is not a
   * downgrade. The travelling copy is a still of the poster frame, so the thing
   * arriving on top of it is a video of the same frame at the same size, and
   * holding the still until the clip can play would hold a frame that is already
   * visible for however long the export takes. `loadedmetadata` is also bounded by
   * `preload="metadata"` rather than by the reader having pressed play, so it
   * arrives without a byte of the body being downloaded.
   */
  function previewClipWhenDecoded() {
    const row = currentLightboxRow();
    if (!isVideoRow(row)) return;
    const video = $('lightboxVideo');
    const ready = () => previewMediaReady();
    video.addEventListener('loadedmetadata', ready, { once: true });
    video.addEventListener('error', ready, { once: true });
    previewSoon(ready, PREVIEW_DECODE_GRACE_MS);
  }

  /**
   * The stage has a picture in it — or has run out of ways to get one.
   *
   * Half of what the open travel waits for; the other half is the travel itself
   * finishing. A fallback calls this too, and deliberately: a travelling copy must
   * not be left floating over a stage that has finished arriving, whatever it
   * arrived at.
   */
  function previewMediaReady() {
    previewTravel.decoded = true;
    settlePreviewTravel();
  }

  /**
   * The hand-over: the travelling thumbnail fades out as the real preview fades in.
   *
   * Both have to have happened first — the travel finished *and* the bitmap
   * decoded. Cross-fading mid-flight would put the sharp photograph at full size
   * with a blurred copy of itself still sliding down into the grid over it.
   */
  function settlePreviewTravel() {
    if (previewTravel.settled || !previewTravel.travelled || !previewTravel.decoded) return;
    previewTravel.settled = true;
    previewClearTimers();
    const ghost = previewTravel.ghost;
    previewTravel.ghost = null;
    $('lightbox').classList.remove('lightbox-entering');
    if (!ghost) return;
    // The transition is shortened rather than replaced: `transform` has already
    // arrived, and only the fade is left to do.
    ghost.style.transition = `opacity ${PREVIEW_HANDOFF_MS}ms linear`;
    ghost.style.opacity = '0';
    previewSoon(() => ghost.remove(), PREVIEW_HANDOFF_MS + 40);
  }

  /**
   * The same travel backwards, from the preview down into the tile.
   *
   * Runs from the bitmap that is actually on screen rather than from the tile's
   * thumbnail, because this is the direction where the difference is visible: a
   * 256px copy shrinking away from a sharp photograph is a resolution drop the eye
   * catches, and there is no reason to spend it.
   *
   * Returns whether the travel is running, which is the caller’s signal that the
   * overlay must stay on screen until it lands.
   */
  function startPreviewReturn() {
    const source = previewTravel.source;
    // Measured again rather than remembered: the overlay is still on screen here, so
    // this is the live stage, and where the travel started from may have moved under
    // a window that was resized while the preview was open.
    const target = previewTargetRect(previewTravel.aspect);
    // The tile and its shape are read *before* this clear — afterwards there is
    // nothing left to travel to.
    previewDropGhost();
    previewForget();
    if (!source || !target || prefersReducedMotion()) return false;
    const tile = previewTileRect(source);
    if (!tile) return false;
    const image = $('lightboxImage');
    // The fallback is not only for a missing bitmap: for a clip `#lightboxImage`
    // is *always* empty, because the stage is showing a `<video>`. So a clip's
    // return flight flies its poster frame — which is exactly the frame the
    // travelling copy was showing on the way out, and the one the tile draws.
    const ghost = previewGhost(target, image.naturalWidth
      ? (image.currentSrc || image.src)
      : (source.currentSrc || source.src));
    document.body.appendChild(ghost);
    previewTravel.ghost = ghost;
    ghost.classList.add('preview-ghost-return');
    void ghost.offsetWidth;
    ghost.style.opacity = '0';
    ghost.style.transform = previewTransform(target, tile, previewTravel.aspect);
    previewSoon(() => ghost.remove(), PREVIEW_TRAVEL_MS + 40);
    return true;
  }

  /* ---------------------------------------------------------------- lightbox */

  /**
   * `options.allPhotos` marks a lightbox opened from the chronological window,
   * which pages in both directions and reports its own position. The default
   * (`queue === state.items`) is the score grid, whose queue grows at one end.
   */
  function openLightbox(queue, index, label, options = {}) {
    if (!queue || !queue[index]) return;
    // Entering the lightbox from the context menu must not leave the menu
    // stranded underneath it: the overlay would swallow every dismissal
    // (outside click, Escape) and the menu would reappear when it closed.
    closeTileMenu();
    const wasOpen = state.lightbox.open;
    if (!wasOpen) state.returnFocus = document.activeElement;
    state.lightbox = {
      open: true,
      queue,
      index,
      live: queue === state.items,
      allPhotos: Boolean(options.allPhotos),
      /** Marks a lightbox opened from Similar Groups, whose queue is one group. */
      groups: Boolean(options.groups),
      label: label || '',
    };
    $('lightbox').hidden = false;
    // Measured here so the backdrop has a computed `opacity: 0` to fade up from.
    // Unhiding and opening in the same tick leaves the browser with no previous
    // style to transition from, and the overlay would still arrive in one frame.
    void $('lightbox').offsetWidth;
    $('lightbox').classList.add('is-open');
    if (!wasOpen) $('lightboxClose').focus();
    renderLightbox();
    // Arriving is the only half that travels *from* the grid. Moving between photos
    // inside an open preview has no tile to fly from, and re-running the travel
    // would make every arrow key look like the whole window had been rebuilt.
    if (!wasOpen) startPreviewTravel(currentLightboxRow());
  }

  /**
   * Space and Enter on a tile or a group cell: show the photo, or put it away.
   *
   * A toggle, not "open", because the key has to mean the same thing wherever it is
   * pressed — on the grid, on a group cell, and inside the preview itself. Closing
   * from inside is handled by the lightbox's own Space handler; this is the half
   * that has to notice the preview is *already showing this photo* and put it away
   * instead of re-opening it on top of itself.
   *
   * The queue and index are passed as accessors because both can move between the
   * keypress and the open — a page can land, and the All Photos window re-indexes
   * on every prepend — and a queue captured at the call site would then open the
   * wrong photo. Read here, at the moment of use.
   */
  function togglePreview(queue, index, options = {}) {
    const rows = queue();
    const at = index();
    if (!rows || !rows[at]) return;
    const live = state.lightbox;
    // Already showing this photo, in this window: quit. Anything else — a
    // different photo, or the same photo in a different window — is a move, not a
    // quit, because the two windows are genuinely different places.
    if (live.open && live.queue === rows && live.index === at) return closeLightbox();
    openLightbox(rows, at, options.label || '', options);
  }

  function closeLightbox() {
    if (!state.lightbox.open) return;
    const index = state.lightbox.index;
    const wasAllPhotos = state.lightbox.allPhotos;
    // Before the travel, and instantly: the photograph leaves at fit, and a
    // shrinking animation underneath the copy flying back to the tile would be two
    // motions of one photo at once.
    zoomReset(false);
    lightboxZoom.rowId = null;
    state.lightbox = { open: false, queue: [], index: -1, live: false, allPhotos: false, groups: false, label: '' };
    // The state above is already closed, so the keyboard, the grid underneath and
    // Escape all behave as though the preview is gone while it is still visibly on
    // its way out. Only the pixels are still finishing — and the way back out takes
    // over from anything still arriving, so the two halves of the round trip cannot
    // both be holding the screen at once.
    const returning = startPreviewReturn();
    $('lightbox').classList.remove('is-open');
    if (returning) previewSoon(() => hideLightbox(), PREVIEW_TRAVEL_MS);
    else hideLightbox();
    // Closing in the All Photos window leaves the photo just inspected on
    // screen, which is where the user expects to carry on from.
    if (wasAllPhotos) scrollAllPhotosIntoView(index);
  }

  /**
   * Stops and empties whatever the stage is currently showing.
   *
   * Called at the top of every `renderLightbox` and from `hideLightbox`, so it
   * runs on paging, on repainting for a favourite toggle, and on close — three
   * separate ways for a clip to be left playing underneath something else, and
   * all three have to go through here rather than each remembering.
   *
   * `pause()` before the source is dropped, because removing `src` from a playing
   * element does not reliably stop it: the media stack may be mid-buffer, and the
   * sound continues over whatever replaced the clip. Then the attributes are
   * *removed* rather than assigned empty strings, so there is no URL left to
   * resolve and the decoder and the open connection to the export both go.
   *
   * `load()` afterwards is what tells the element it has no resource, which is
   * the step that actually tears the media stack down. Guarded because jsdom does
   * not implement it — see docs/WEB-UI-TESTS.md, which is the file that names
   * what the jsdom harness cannot do.
   */
  function teardownLightboxMedia() {
    const video = $('lightboxVideo');
    if (!video) return;
    // Nothing to release is the common case, and it is worth saying so: this runs
    // from `hideLightbox` on every close, and a reader paging photographs never
    // loads a clip at all. Pausing and reloading an element that was never given a
    // source is a media-stack round trip for nothing — and on a machine with a few
    // hundred photos in the queue it is a few hundred wasted ones.
    //
    // It is also the case jsdom cannot do at all: `HTMLMediaElement.pause` and
    // `.load` are reported as "not implemented" rather than throwing, so calling
    // them unguarded fills a jsdom run with errors about a code path that never had
    // anything to release. See docs/WEB-UI-TESTS.md.
    // Read *before* removing, or the test is on the post-removal state and the
    // guards would never fire.
    const hadSource = video.hasAttribute('src');
    const hadPoster = video.hasAttribute('poster');
    if (hadSource) {
      try { video.pause(); } catch { /* nothing decoded yet */ }
    }
    video.removeAttribute('src');
    video.removeAttribute('poster');
    video.onerror = null;
    // `load()` only when there was something to unload, for the same reason. It is
    // the step that actually tears down the decoder and the open request to the
    // export; removing `src` alone does not reliably do it.
    if (hadSource || hadPoster) {
      try { video.load(); } catch { /* no media stack */ }
    }
  }

  /**
   * Takes the overlay off the screen and drops the decoded preview, so a large
   * JPEG is not held alive by a closed view.
   *
   * On the way in this is the last statement of the travel, not the first: a
   * `display: none` halfway through would cut the photograph off where it stood.
   *
   * `teardownLightboxMedia` rather than `hidden = true`: a closed lightbox with
   * a paused-but-attached clip still holds that clip's decoder and its half-open
   * export request for the rest of the session, and the next open would race a
   * resource the previous one still holds.
   */
  function hideLightbox() {
    $('lightbox').hidden = true;
    teardownLightboxMedia();
    const image = $('lightboxImage');
    image.onload = null;
    image.onerror = null;
    image.src = '';
    // Whatever the still was still waiting for belongs to a preview that is no
    // longer open: the token retires its walk, and the photograph it belonged to is
    // forgotten so the next open arms a fresh one rather than trusting a stale one.
    releaseLightboxStill();
    restoreFocus();
  }

  function currentLightboxRow() {
    const lightbox = state.lightbox;
    return lightbox.open ? lightbox.queue[lightbox.index] || null : null;
  }

  /** Resolves once no page fetch is in flight, so navigation is not racing the loader. */
  async function waitForIdlePage(attempts = 6) {
    for (let i = 0; i < attempts && state.loading; i += 1) {
      await new Promise((resolve) => setTimeout(resolve, 40));
    }
  }

  async function navigateLightbox(delta) {
    const lightbox = state.lightbox;
    if (!lightbox.open) return;
    // The chronological window pages both ways, so it has its own walk.
    if (lightbox.allPhotos) { await navigateAllPhotosLightbox(delta); return; }
    let next = lightbox.index + delta;
    // A group is a closed set that arrived whole: there is nothing to page in, and
    // "End of the review queue" would be the wrong message for it. The arrows are
    // already disabled at the ends, so this only fires if the group shrank
    // underneath an open lightbox.
    const closed = () => lightbox.groups || !lightbox.live;
    // Bounded: a stalled or wedged page fetch must not spin here forever.
    let attempts = 0;
    for (;;) {
      if (next < 0) return;
      if (next < lightbox.queue.length) break;
      if (closed()) {
        if (lightbox.groups) renderLightbox();
        else toast('End of the review queue.');
        return;
      }
      if (!state.nextCursor) { toast('That is the last photo matching the current filter.'); return; }
      if (attempts >= 5) { toast('Could not load more photos — use “Load more” and try again.'); return; }
      attempts += 1;
      await waitForIdlePage();
      if (state.lightbox !== lightbox || !lightbox.open) return; // closed while loading
      if (!state.nextCursor) { toast('That is the last photo matching the current filter.'); return; }
      await loadPage(state.nextCursor);
      // The page shifted nothing if it was empty; re-walking from the same place
      // is what notices, rather than trusting the fetch to have advanced us.
      next = lightbox.index + delta;
    }
    lightbox.index = next;
    renderLightbox();
  }

  /**
   * The still on the stage, and the walk it is taking through the renditions of it.
   *
   * `token` retires every callback of an earlier render. A preview request outlives
   * the photograph it was made for — paging on while a 2048px JPEG is still coming
   * down from iCloud leaves a response in flight for something that is no longer on
   * screen — and the walk installed by the render that is current is the only one
   * allowed to move the element. `rowId` is the same idea pointed the other way: a
   * repaint of the *same* photograph, which is what hearting it from the preview is,
   * must not restart the walk and throw the request behind it away. `givenUp`
   * outlives such a repaint, so the fallback sentence is restored rather than
   * re-earned by a second walk.
   */
  const lightboxStill = { token: 0, rowId: null, givenUp: false };

  /**
   * Retires the walk: nothing it has in flight may touch the stage again.
   *
   * Called when the stage changes hands — to a clip, or out of the lightbox — so a
   * rendition still arriving for the photograph before it cannot paint itself over
   * the thing now being shown.
   */
  function releaseLightboxStill() {
    lightboxStill.token += 1;
    lightboxStill.rowId = null;
    lightboxStill.givenUp = false;
  }

  /**
   * The renditions of a still that this Mac already holds, sharpest first.
   *
   * The grid tile's own bitmap when there is one — decoded, on screen and in the
   * browser's cache, so painting it costs a repaint and no request at all — and the
   * largest local thumbnails otherwise. Local by construction rather than by hope:
   * the thumbnail route passes `allowNetwork: false`, so no rung here can start an
   * iCloud download. A tile whose own request has already failed is skipped rather
   * than asked again.
   */
  function localStillLadder(row) {
    const tile = previewSourceFor(row.id);
    const held = tile && !tile.classList.contains('failed') ? tile.currentSrc : '';
    const thumbnails = [thumbURL(row.id, 512), thumbURL(row.id, 256)];
    return held ? [held, ...thumbnails] : thumbnails;
  }

  /**
   * What the stage says when neither the original nor a local rendition could be
   * produced.
   *
   * It names the one cause the reader can act on, and it is the distinction the
   * grid's placeholder already makes: downloads are off, so the pixels in iCloud
   * are out of reach, or Photos holds the asset but cannot make a picture of it.
   * The two surfaces disagreeing about why a photograph is missing is worse than
   * either wording.
   */
  function noPreviewText() {
    return localOnly()
      ? 'Preview unavailable — the original is stored in iCloud, and downloads are off.'
      : 'Preview unavailable — Photos could not produce this photo.';
  }

  /**
   * Renders a still: what this Mac has, then the original, and only then the
   * sentence that says it has neither.
   *
   * The preview route asks PhotoKit for the *original*, which with "Download from
   * iCloud when required" on is a request that waits for pixels to come down —
   * seconds for a photograph this Mac once held, and longer for one it never has.
   * The grid tile beside it has been drawing a local rendition the whole time, so
   * the preview starts from the bitmap the reader is already looking at and
   * sharpens in place when the original lands.
   *
   * That ordering is what keeps two failures from reading as a broken app. A
   * preview that arrives *late* used to be preceded by an empty stage, because the
   * travelling thumbnail was taken away on a timer whether or not anything replaced
   * it; and one that never arrives left the stage empty for good, with the arrows
   * looking as though they did nothing because every page looked like the same
   * blank rectangle. Both are the same missing step: there was already a rendition
   * on this Mac, and the only thing that had ever asked for it was the grid.
   *
   * A repaint of the same photograph returns early rather than walking again — see
   * `lightboxStill`.
   */
  function renderLightboxStill(row) {
    if (lightboxStill.rowId === row.id && !lightboxStill.givenUp) return;
    lightboxStill.rowId = row.id;
    lightboxStill.givenUp = false;

    const image = $('lightboxImage');
    const fallback = $('lightboxFallback');
    const token = (lightboxStill.token += 1);
    const live = () => token === lightboxStill.token;

    const ladder = localStillLadder(row);
    const sources = [...ladder, previewURL(row.id)];
    let step = 0;
    // The local rendition on the stage, so that the original's failure has
    // something to fall back to. Cleared once it is restored, so a rendition that
    // fails a second time ends the walk instead of starting it over.
    let painted = null;

    image.onload = () => {
      if (!live()) return;
      // On the stage only once it has pixels. An `<img>` between one failed request
      // and the next paints its `alt` — a line of "Photo scored 0.42" across the
      // stage, which is a worse answer than nothing at all.
      image.hidden = false;
      fallback.hidden = true;
      if (step < ladder.length) painted = sources[step];
      // A picture is on the stage, whichever rung produced it, and that is what the
      // open travel waits for before handing the screen over from its copy.
      previewMediaReady();
      // A local rendition is a step, not the destination: the original is what a
      // preview is for, and it is asked for as soon as there is something on the
      // stage for it to arrive in front of. The `src` it replaces is what stays
      // painted while it is fetched.
      if (step < ladder.length) { step = ladder.length; image.src = sources[step]; }
    };

    image.onerror = () => {
      if (!live()) return;
      image.hidden = true;
      step += 1;
      if (step < sources.length) { image.src = sources[step]; return; }
      // Past the original, the local rendition that was already on the stage is the
      // answer rather than an empty stage. It comes back out of the browser's cache,
      // so the same `src` re-decodes rather than waits.
      if (painted) { const source = painted; painted = null; image.src = source; return; }
      fallback.hidden = false;
      fallback.textContent = noPreviewText();
      lightboxStill.givenUp = true;
      previewMediaReady();
    };

    image.src = sources[0];
  }

  function renderLightbox() {
    const row = currentLightboxRow();
    if (!row) return;
    const lightbox = state.lightbox;

    // A travelling copy belongs to the photograph it flew from, and paging has to
    // take it along: the overlay class that hides the real preview behind it is set
    // for that one flight, so a copy left over a photo that is no longer selected
    // would hide the new one for as long as the old travel had left to run.
    if (previewTravel.ghost && previewTravel.rowId !== row.id) previewDropGhost();

    // Zoom belongs to the photograph as well, and a new one starts fitted: carrying
    // a magnified rect onto the next photo would show a corner of it with nothing on
    // screen to say why. Instant, because the reader did not ask for this change —
    // it is paging, not a zoom step. A *repaint* of the same photo (hearting it from
    // the preview) keeps whatever zoom the reader set.
    if (lightboxZoom.rowId !== row.id) zoomReset(false);
    lightboxZoom.rowId = row.id;

    const image = $('lightboxImage');
    const video = $('lightboxVideo');
    const fallback = $('lightboxFallback');
    fallback.hidden = true;

    // Exactly one of the two elements is on the stage at a time.
    //
    // For a clip the teardown is conditional on the clip being a *different* one,
    // and that condition is the whole of the pause-on-page requirement. `pause()`
    // before the source is dropped, because removing `src` from a playing element
    // does not reliably stop it: the media stack may be mid-buffer and the sound
    // continues over whatever replaced the clip. Then the attributes are *removed*
    // rather than assigned empty strings, so there is no URL left to resolve and
    // the decoder and its open connection to the export both go.
    //
    // Conditional rather than unconditional, and deliberately so: `renderLightbox`
    // is also the repaint path for a favourite toggle applied from the lightbox,
    // and a version that tore the player down on every render would interrupt
    // playback because the reader hearted the clip they were watching. Paging is
    // the event that changes the clip; repainting is not.
    //
    // Compared against the element's own `src` rather than a remembered id, so the
    // check cannot drift from what is actually loaded: there is no second field to
    // keep in step, and the test is the question that matters — "is this a
    // different clip from the one this element is playing?"
    const wantedVideo = videoURL(row.id);
    const showingAnother = video.getAttribute('src') !== wantedVideo;
    if (showingAnother) teardownLightboxMedia();

    if (isVideoRow(row)) {
      image.hidden = true;
      // The still walk is retired rather than just covered: a rendition still
      // arriving for the photograph before this one must not paint itself back
      // over the clip that owns the stage now.
      releaseLightboxStill();
      image.onload = null;
      image.onerror = null;
      video.hidden = false;
      video.controls = true;
      // `preload="metadata"` and no `autoplay` — set once in the markup and restated
      // here because this is the only place the element is configured, and an
      // attribute set from JS is not obviously the same as one set in HTML.
      // Autoplay is the one thing this client must never do: a grid of clips that
      // starts talking the moment you page through it is not a photo cleaner, and
      // nothing about opening a preview is a request to play anything.
      video.preload = 'metadata';
      video.autoplay = false;
      // The poster is the same preview route a still uses, so the first frame is
      // a decoded PhotoKit rendition rather than the 256px tile, and the clip is
      // recognisable before it has loaded. `poster` rather than a `<video>` child,
      // which nothing supports.
      video.poster = previewURL(row.id);
      // Reassigned unconditionally, unlike `src` above, and for the same reason as
      // the still's: a poster is a picture, so setting it again is a no-op for the
      // clip and repainting the metadata must not leave the frame from the last
      // clip on screen.
      if (showingAnother) video.src = wantedVideo;
      video.setAttribute('aria-label', `Video, scored ${fmt.score(row.score)}`);
      video.title = `${mediaSummaryText(row)} · ${fmt.date(row.date)}`;
      // A clip whose export cannot be produced — the original is iCloud-only and
      // downloads are off, or Photos has no video resource — raises `error`, and
      // the same fallback line the still uses is the honest answer. Not hidden:
      // a black rectangle with a broken player in it tells the reader nothing.
      video.onerror = () => {
        video.hidden = true;
        fallback.hidden = false;
        fallback.textContent = 'This clip could not be loaded — its original may be stored in iCloud only.';
      };
    } else {
      // A still after a clip: the player goes first, or the clip's audio survives
      // the page change. `teardownLightboxMedia` above has already run for this
      // case, because a still never equals a clip's `src`.
      video.hidden = true;
      image.alt = `Photo scored ${fmt.score(row.score)}`;
      renderLightboxStill(row);
    }

    $('lightboxScore').textContent = fmt.score(row.score);
    $('lightboxDate').textContent = fmt.date(row.date);
    // A group response carries no dimensions, so this renders "—" rather than
    // inventing a size PhotoCleaner has not read for that photo.
    $('lightboxDimensions').textContent = fmt.dimensions(row.width, row.height);
    // Length, for a clip only. Hidden rather than showing "—" beside a
    // photograph, because a row that is present and empty reads as a value
    // PhotoCleaner failed to read rather than as one that does not apply. And a
    // clip whose length has not been scanned prints nothing at all — the same
    // reason the tile's badge is conditional.
    const length = fmt.mediaDuration(row.duration);
    $('lightboxDurationRow').hidden = !(isVideoRow(row) && length);
    $('lightboxDuration').textContent = length;
    $('lightboxFavorite').textContent = row.favorite ? 'Yes' : 'No';
    // One photo and one label, because there is no second state to toggle
    // between: this destroys the photo on the spot, which is what a button in a
    // preview of a single photo has always meant everywhere else.
    $('lightboxDelete').textContent = 'Delete';
    $('lightboxDelete').title = 'Delete this photo through Photos. This cannot be undone.';
    $('lightboxDelete').disabled = state.deleting;

    // The favourite toggle. Its label says what a favourite *does*, because that
    // is the only protection this tool has: a favourite is excluded from every
    // bulk deletion, always.
    const favoriteButton = $('lightboxFavoriteToggle');
    favoriteButton.textContent = row.favorite ? '♥ Favourite — protected' : '♡ Make favourite';
    favoriteButton.setAttribute('aria-pressed', row.favorite ? 'true' : 'false');
    favoriteButton.classList.toggle('is-favorite', Boolean(row.favorite));
    favoriteButton.title = row.favorite
      ? 'A favourite, so it is excluded from deletion. Click to remove the favourite flag.'
      : 'Mark as a favourite in Photos. Favourites are excluded from deletion.';

    // Every album this photo is in, as clickable chips. A photo in none says so
    // explicitly rather than showing a dash that reads as "not loaded yet".
    const albumsHost = $('lightboxAlbums');
    const entries = albumsFor(row.id);
    albumsHost.replaceChildren();
    if (entries.length === 0) {
      const none = document.createElement('span');
      none.className = 'album-none';
      none.textContent = state.albums.loaded ? 'In no album' : 'Album membership not read yet';
      albumsHost.appendChild(none);
    } else {
      entries.forEach((album) => albumsHost.appendChild(buildAlbumTag(album, entries.length)));
    }

    const position = `${lightbox.index + 1} of ${fmt.count(lightbox.queue.length)}`;
    if (lightbox.groups) {
      // A group is a closed set — it cannot be paged — so both arrows go dead at the
      // ends and the position line says which ranking is in effect, because the same
      // photos in a different order are a different answer.
      $('lightboxPosition').textContent =
        `${position} · ${lightbox.label || 'Aesthetics'} order within this group`;
      $('lightboxPrev').disabled = lightbox.index === 0;
      $('lightboxNext').disabled = lightbox.index >= lightbox.queue.length - 1;
      return;
    }
    if (lightbox.allPhotos) {
      $('lightboxPosition').textContent =
        `${position} loaded · All Photos, newest first · ${fmt.count(state.all.total)} in the library`;
      // Both arrows stay live: either end of the window can still be extended.
      $('lightboxPrev').disabled = false;
      $('lightboxNext').disabled = false;
      return;
    }
    $('lightboxPosition').textContent = lightbox.label
      ? `${lightbox.label} · ${position}`
      : `${position} loaded · ${fmt.count(state.total)} matching`;
    $('lightboxPrev').disabled = lightbox.index === 0;
    $('lightboxNext').disabled = !lightbox.live && lightbox.index >= lightbox.queue.length - 1;
  }

  /* ------------------------------------------------------------- lightbox zoom */

  /**
   * How far in the photograph can be magnified, and the state of that magnification.
   *
   * Zoom is a transform on the still and on nothing else — the panel, the overlay
   * and the keyboard model do not move with it, because the point of zooming is to
   * look at the photograph and not at a magnified interface. `scale` is bounded
   * below at 1, which is *fit*: the whole frame inside the stage's pinned box (§8).
   *
   * `dragged` is the one piece of this the click handler needs: the stage's click
   * pages to the next photograph, and a drag of a zoomed photo that ended in a
   * click must not be read as "show me the next one".
   */
  const ZOOM_MAX = 8;
  /** The keys that magnify the photograph: `+` and `=` (the same physical key), `-`, and `0` for fit. */
  const ZOOM_KEYS = new Set(['+', '=', '-', '_', '0']);
  /** The settle: how long a key step or a return to fit takes. Gestures do not use it. */
  const ZOOM_SETTLE_MS = 160;
  /** How long after the last wheel event a gesture is considered over. */
  const ZOOM_GESTURE_MS = 140;
  /**
   * How far down one gesture has to scroll, at fit, to put the preview away.
   *
   * Accumulated over a gesture rather than read from one event, because a trackpad
   * reports a deliberate swipe as a stream of small deltas and a preview that closed
   * on any one of them would close on an accident. 120 px is past a nudge and well
   * inside a swipe.
   */
  const ZOOM_LEAVE_PX = 120;
  const lightboxZoom = { rowId: null, scale: 1, x: 0, y: 0, pan: null, dragged: false, leaving: 0, timer: 0 };

  /** The stage's untransformed box, or null where there is no layout to measure. */
  function zoomBox() {
    const stage = $('lightboxStage');
    const rect = stage ? stage.getBoundingClientRect() : null;
    return rect && rect.width && rect.height
      ? { left: rect.left, top: rect.top, width: rect.width, height: rect.height }
      : null;
  }

  /**
   * The shape of what is on the stage.
   *
   * The row's own dimensions first: they are what the cache read, and they are
   * there before a single byte of any rendition has arrived — which is the state a
   * zoom can be asked for in, since the local rendition is up within a frame.
   */
  function zoomAspect() {
    const row = currentLightboxRow();
    const image = $('lightboxImage');
    const width = (row && row.width) || image.naturalWidth;
    const height = (row && row.height) || image.naturalHeight;
    return width && height ? width / height : 0;
  }

  /** The rect the still's pixels occupy inside the element: `object-fit: contain`. */
  function zoomFitted(box, aspect) {
    if (!aspect) return { width: box.width, height: box.height };
    const width = Math.min(box.width, box.height * aspect);
    return { width, height: width / aspect };
  }

  /**
   * Where the photograph may be, clamped so that panning can never lose it.
   *
   * The clamp is on the *photograph*, not on the element that holds it. The still is
   * `object-fit: contain` in a stage-sized box, so the pixels being magnified are
   * the fitted rect in the middle of it, and that is the rect that must not slide
   * off the stage: an axis where the magnified photograph is wider than the stage
   * keeps it covering the stage edge to edge, and an axis where it is still
   * narrower centres it — which is what makes a portrait photo stay centred
   * horizontally however far it is zoomed.
   */
  function zoomClamp(box, aspect, scale, x, y) {
    const fitted = zoomFitted(box, aspect);
    const halfWidth = fitted.width * scale / 2;
    const halfHeight = fitted.height * scale / 2;
    const centreX = box.width * scale / 2 + x;
    const centreY = box.height * scale / 2 + y;
    const heldX = halfWidth * 2 >= box.width
      ? Math.min(Math.max(centreX, box.width - halfWidth), halfWidth)
      : box.width / 2;
    const heldY = halfHeight * 2 >= box.height
      ? Math.min(Math.max(centreY, box.height - halfHeight), halfHeight)
      : box.height / 2;
    return { scale, x: heldX - box.width * scale / 2, y: heldY - box.height * scale / 2 };
  }

  /** Puts the current zoom on the element, clamped, and flags the stage for the cursor. */
  function zoomApply() {
    const box = zoomBox();
    const image = $('lightboxImage');
    if (!box) return;
    const placed = zoomClamp(box, zoomAspect(), lightboxZoom.scale, lightboxZoom.x, lightboxZoom.y);
    lightboxZoom.scale = placed.scale;
    lightboxZoom.x = placed.x;
    lightboxZoom.y = placed.y;
    image.style.transform = `translate(${placed.x}px, ${placed.y}px) scale(${placed.scale})`;
    $('lightboxStage').classList.toggle('is-zoomed', placed.scale > 1);
  }

  /**
   * Animates the transform, or does not.
   *
   * A gesture must not: a transition on every wheel tick trails the fingers by its
   * own duration and turns a pinch into a smear. A step the *reader* took — a key,
   * a return to fit — must: it is one change with no gesture behind it, and
   * arriving instantly reads as a jump cut.
   */
  function zoomTransition(ms) {
    const image = $('lightboxImage');
    image.style.transition = ms && !prefersReducedMotion() ? `transform ${ms}ms ease-out` : 'none';
  }

  /**
   * Scales to `scale` about a point on the screen, keeping that point still.
   *
   * The anchor is the whole of what makes a pinch feel attached to the fingers: the
   * point of the photograph under the pointer is the point that stays under it, at
   * every step, which is also what lets a reader reach a corner of a photo without
   * a pan — zoom *at* it. `point` is in client coordinates, and the centre of the
   * stage is used when there is none (the keyboard's steps).
   */
  function zoomTo(scale, point) {
    const box = zoomBox();
    const next = Math.min(Math.max(scale, 1), ZOOM_MAX);
    const previous = lightboxZoom.scale;
    if (!box) { lightboxZoom.scale = next; return; }
    const anchor = point || { x: box.left + box.width / 2, y: box.top + box.height / 2 };
    // Where the anchor sits in the element's own untouched coordinates: the point
    // that has to still be under `anchor` once the scale has changed.
    const localX = (anchor.x - box.left - lightboxZoom.x) / previous;
    const localY = (anchor.y - box.top - lightboxZoom.y) / previous;
    lightboxZoom.scale = next;
    lightboxZoom.x += localX * (previous - next);
    lightboxZoom.y += localY * (previous - next);
    zoomApply();
  }

  /**
   * Back to fit.
   *
   * Animated when the reader asked for it, instant when the photograph is on its
   * way out: a shrinking animation would play underneath the travelling copy going
   * the other way, which is two motions of one photograph at once.
   */
  function zoomReset(animated = false) {
    lightboxZoom.scale = 1;
    lightboxZoom.x = 0;
    lightboxZoom.y = 0;
    lightboxZoom.pan = null;
    lightboxZoom.dragged = false;
    lightboxZoom.leaving = 0;
    zoomTransition(animated && !prefersReducedMotion() ? ZOOM_SETTLE_MS : 0);
    $('lightboxImage').style.transform = 'translate(0px, 0px) scale(1)';
    $('lightboxStage').classList.toggle('is-zoomed', false);
  }

  /** True while the stage is showing a photograph — the only thing that zooms. */
  function zoomHasPhotograph() {
    const row = currentLightboxRow();
    return Boolean(row) && !isVideoRow(row);
  }

  /**
   * The wheel over the stage: a pinch magnifies, a scroll moves, and a scroll down
   * that has nothing to move puts the preview away.
   *
   * Three gestures, and one wheel event to tell them apart.
   *
   * - **A pinch** arrives as a wheel with `ctrlKey` — that is the platform's own
   *   encoding of the gesture, and a mouse, which has no pinch at all, gets the same
   *   modifier from ⌘-scroll. Either spelling means one thing: magnify, about the
   *   pointer.
   * - **A two-finger scroll** (or a mouse wheel) is a wheel with neither modifier,
   *   and it *moves* the photograph in the direction it names: scrolling down looks
   *   further down the photo, scrolling right looks further right. That only means
   *   anything once the photograph is magnified, because at fit there is nowhere to
   *   go — which is what makes the third reading possible.
   * - **A scroll down at fit** has no photograph left to move, so it is the one
   *   gesture left for it to mean: leave the preview. Scroll *up* at fit does
   *   nothing; the magnifying gesture is the pinch, and a scroll that silently zoomed
   *   would be a second meaning for the same motion.
   *
   * `preventDefault` is not politeness in any of the three: without it a scroll over
   * the preview scrolls the *grid* behind the overlay, and a pinch zooms the browser
   * rather than the photograph.
   */
  function zoomWheel(event) {
    if (!currentLightboxRow()) return;
    event.preventDefault();

    if (event.ctrlKey || event.metaKey) {
      // A clip's transport owns its own gestures, and there is nothing on it to
      // magnify.
      if (!zoomHasPhotograph()) return;
      const factor = Math.exp(-event.deltaY / 100);
      zoomTransition(0);
      zoomTo(lightboxZoom.scale * factor, { x: event.clientX, y: event.clientY });
      zoomGestureOver();
      return;
    }

    if (!zoomHasPhotograph() || lightboxZoom.scale <= 1) {
      // Nowhere to pan to, so a downward scroll is a swipe to leave. Upward deltas
      // are taken back off the total rather than resetting it, so a gesture that
      // wanders down and up again counts what it kept.
      lightboxZoom.leaving = Math.max(0, lightboxZoom.leaving + event.deltaY);
      zoomGestureOver();
      if (lightboxZoom.leaving >= ZOOM_LEAVE_PX) {
        lightboxZoom.leaving = 0;
        closeLightbox();
      }
      return;
    }

    // Magnified: the scroll moves the photograph, by the same direction word the pan
    // cursor promises. The clamp keeps it on the stage.
    zoomTransition(0);
    lightboxZoom.x -= event.deltaX;
    lightboxZoom.y -= event.deltaY;
    zoomApply();
    zoomGestureOver();
  }

  /**
   * The end of a wheel gesture, once the deltas stop.
   *
   * Two things were suspended for the duration: the transition (a gesture tracks the
   * fingers rather than trailing them by its own duration) and the swipe that leaves
   * the preview (a slow drift of separate scrolls must never add up to one gesture's
   * worth of exit).
   */
  function zoomGestureOver() {
    clearTimeout(lightboxZoom.timer);
    lightboxZoom.timer = setTimeout(() => {
      zoomTransition(ZOOM_SETTLE_MS);
      lightboxZoom.leaving = 0;
    }, ZOOM_GESTURE_MS);
  }

  /** `+`/`-` about the centre, `0` back to fit. */
  function zoomKey(key) {
    if (!zoomHasPhotograph()) return;
    if (key === '0') { zoomReset(true); return; }
    const step = key === '+' || key === '=' ? 1.4 : 1 / 1.4;
    zoomTransition(ZOOM_SETTLE_MS);
    zoomTo(lightboxZoom.scale * step, null);
  }

  /**
   * Dragging a magnified photograph, which is the only way to reach what the clamp
   * has pushed out of the frame.
   *
   * Only while magnified, only with the primary button, and only when the gesture
   * starts on the photograph: at fit there is nothing to pan to, the right button
   * belongs to the context menu, and a press on the stage's own chrome is not a
   * press on the photo.
   */
  function zoomPanStart(event) {
    if (!zoomHasPhotograph() || lightboxZoom.scale <= 1) return;
    if (event.button !== 0 || event.target !== $('lightboxImage')) return;
    lightboxZoom.pan = { id: event.pointerId, x: event.clientX, y: event.clientY, moved: 0 };
    lightboxZoom.dragged = false;
    zoomTransition(0);
    // Claimed so the drag survives the pointer leaving the stage, and so the
    // photograph does not start the browser's own image drag instead.
    if (event.target.setPointerCapture) event.target.setPointerCapture(event.pointerId);
    event.preventDefault();
  }

  function zoomPanMove(event) {
    const pan = lightboxZoom.pan;
    if (!pan || pan.id !== event.pointerId) return;
    pan.moved += Math.abs(event.clientX - pan.x) + Math.abs(event.clientY - pan.y);
    lightboxZoom.x += event.clientX - pan.x;
    lightboxZoom.y += event.clientY - pan.y;
    pan.x = event.clientX;
    pan.y = event.clientY;
    zoomApply();
    event.preventDefault();
  }

  function zoomPanEnd(event) {
    const pan = lightboxZoom.pan;
    if (!pan || pan.id !== event.pointerId) return;
    // A hand that moved is a hand that panned, and the click that follows it is the
    // end of the drag rather than a request for the next photograph.
    lightboxZoom.dragged = pan.moved > 3;
    lightboxZoom.pan = null;
    if (event.target.releasePointerCapture && event.target.hasPointerCapture?.(event.pointerId)) {
      event.target.releasePointerCapture(event.pointerId);
    }
  }

  /* ------------------------------------------------------------------ status */

  function applyStatus(status) {
    if (!status || typeof status !== 'object') return;
    state.status = status;
    const analysis = status.analysis || {};
    const score = status.score || {};

    const authorized = AUTHORIZED_PHASES.includes(status.authorization);
    $('authorizationBanner').hidden = authorized;
    if (!authorized) {
      const messages = {
        denied: 'Access was denied.',
        restricted: 'Access is restricted by system policy.',
        notDetermined: 'PhotoCleaner has not been granted access yet.',
        unknown: 'The authorization state is unknown.',
      };
      $('authorizationDetail').textContent = messages[status.authorization] || '';
    }

    syncSettings(status.settings);
    updateCounts();

    const wasUsable = boundsUsable();
    const boundsChanged = adoptObservedBounds(score.min, score.max, true);
    // The very first scores of a run (or of a rescan that wiped them) turn the
    // slider from dead to live; that needs a page immediately, not on the next
    // throttled tick, or the user is left looking at an empty grid.
    if (boundsUsable() && !wasUsable) state.needsFirstPage = true;
    let boundsMoved = false;
    if (!state.pinned) {
      boundsMoved = followObservedBounds();
      syncRangeUI();
    } else {
      // Keep the slider honest about new extremes without moving the handles.
      boundsMoved = clampLiveBounds();
      syncRangeUI();
    }

    renderProgress(status);

    const analyzedChanged = Number(analysis.analyzed) !== state.lastAnalyzed;
    state.lastAnalyzed = Number(analysis.analyzed) || 0;
    // Photos can also be added or removed on another device, which moves the
    // library total without moving any counter this grid cares about.
    const libraryTotal = Number((status.library || {}).total) || 0;
    const libraryChanged = libraryTotal !== state.lastLibraryTotal;
    state.lastLibraryTotal = libraryTotal;

    if (state.needsFirstPage) {
      state.needsFirstPage = false;
      state.firstLoadDone = true;
      state.lastGridRefresh = 0; // the very first page is never throttled
      resetGrid();
    } else if (!state.firstLoadDone) {
      if (boundsUsable()) resetGrid().then(() => { state.firstLoadDone = true; });
    } else if (boundsChanged || boundsMoved || analyzedChanged || libraryChanged) {
      maybeAutoRefresh();
    }

    // Analysis completing changes what grouping can see, since FeaturePrints are
    // cached alongside scores. This view refreshes on that and on nothing else —
    // the score slider does not concern it. The album filter does, but it is
    // applied by `selectAlbum` at the moment it changes, not by polling here.
    if (state.groups.active && analyzedChanged && !state.groups.status) {
      state.groups.status = null;
      loadGroups('first');
    }

    // The protected-favourite count is authoritative from the server, and it moves
    // whenever the favourite flag does — including from the tile menu and the
    // lightbox, without a reload.
    renderEmptyState();
    updateSelectionBar();
  }

  /** Reflects server-side settings without fighting the user mid-click. */
  function syncSettings(settings) {
    if (!settings) return;
    const first = state.serverSettings === null;
    const changed = !first && (
      state.serverSettings.downloadFromICloud !== settings.downloadFromICloud ||
      state.serverSettings.concurrency !== settings.concurrency
    );
    state.serverSettings = { ...settings };
    if (first || changed) {
      if (document.activeElement !== $('icloudDownloads')) $('icloudDownloads').checked = settings.downloadFromICloud === true;
      if (!first) {
        // "protected" badges and the authoritative count both depend on this.
        refreshAllTiles();
        refreshSelectionPreview();
      }
    }
  }

  /**
   * §4.12. Progress, counts and bounds are always updated; the *grid* is only
   * refreshed when the user is looking at it, has nothing selected, and has the
   * lightbox closed — and at most once every three seconds.
   *
   * The All Photos window is exempt, deliberately: it is anchored on one photo
   * and its whole purpose is a stable view of that neighbourhood, so a reset
   * would throw away the anchor and the scroll position the user is standing on.
   * New photos arriving at the top of the library are not what they came for.
   * Counts and bounds still update underneath it, and the window's own totals
   * come from its queries.
   */
  /**
   * A rebuild publishes a `groups` frame when it finishes, so the view refreshes
   * then rather than polling for the rest of the session.
   *
   * Only the status line and the cards are touched — never the scroll position and
   * never the selection — because a rebuild changes what the groups *are*, not what
   * the user has chosen.
   */
  function applyGroupStatus(status) {
    if (!status || typeof status !== 'object' || !state.groups.active) return;
    const before = state.groups.status;
    state.groups.status = status;
    if (before && before.building && !status.building) {
      // A pass finished: the stored groups have been replaced, so the window is
      // stale. Both ends are reset, because every offset now addresses different
      // groups — keeping them would splice old groups into a new list.
      state.groups.startOffset = 0;
      state.groups.endOffset = 0;
      state.groups.rows = [];
      loadGroups('first');
      return;
    }
    renderGroups();
  }

  function maybeAutoRefresh() {
    if (state.all.active) return;
    if (state.groups.active) return;
    if (selectionHasContent()) return;
    if (state.lightbox.open) return;
    if (state.loading) return;
    if (window.scrollY > AUTO_REFRESH_SCROLL_LIMIT) return;
    if (Date.now() - state.lastGridRefresh < AUTO_REFRESH_MS) return;
    state.lastGridRefresh = Date.now();
    resetGrid();
  }

  /**
   * The analysis read-out in the title bar.
   *
   * The bar and the percentage are always visible while a run is going; the
   * running commentary is one click away, because the header has to stay one line
   * tall for the bars and day headings that stack underneath it.
   */
  function renderProgress(status) {
    const analysis = status.analysis || {};
    const panel = $('analysisStatus');
    const phase = analysis.phase;
    const bar = $('progressBar');
    // Whether this frame is the *transition* into a stopped run. Status frames
    // keep arriving for as long as anything is happening, and the detail opens
    // itself once — on the transition — so a user who has dismissed it is not
    // fought by the next unrelated frame.
    const enteringFailed = phase === 'failed' && panel.dataset.phase !== 'failed';
    panel.dataset.phase = phase;

    if (phase === 'up_to_date' || phase === 'unauthorized') {
      // Nothing to report and nothing to expand. Closing the detail as well is
      // what stops a stale popover from surviving the end of a run.
      panel.hidden = true;
      panel.classList.remove('is-failed');
      setAnalysisDetail('');
      return;
    }
    panel.hidden = false;
    const fill = $('progressFill');

    if (phase === 'starting' || phase === 'scanning') {
      // No determinate value to report: say so rather than implying a number.
      bar.removeAttribute('aria-valuenow');
    }

    if (phase === 'starting') {
      $('phaseLabel').textContent = 'Starting';
      $('progressPercent').textContent = '';
      fill.classList.add('indeterminate');
      setAnalysisDetail('Opening the Photos library…');
      return;
    }

    if (phase === 'scanning') {
      $('phaseLabel').textContent = 'Reading Photos library';
      $('progressPercent').textContent = '';
      fill.classList.add('indeterminate');
      const found = Number(analysis.scanned) || 0;
      setAnalysisDetail(`${fmt.count(found)} photos found`);
      return;
    }

    fill.classList.remove('indeterminate');

    if (phase === 'failed') {
      $('phaseLabel').textContent = 'Analysis stopped';
      $('progressPercent').textContent = '';
      const stopped = percentWidth(analysis.percent);
      fill.style.width = `${stopped}%`;
      bar.setAttribute('aria-valuenow', stopped.toFixed(1));
      // The reason a run stopped is the one thing here the user must not have to
      // ask for, so it opens itself — once — and the read-out is marked as a
      // failure.
      panel.classList.add('is-failed');
      setAnalysisDetail(analysis.lastError || 'An unexpected error stopped the analysis.');
      if (enteringFailed) showAnalysisDetail(true);
      return;
    }

    panel.classList.remove('is-failed');
    $('phaseLabel').textContent = 'Analyzing library';
    const percent = percentWidth(analysis.percent);
    $('progressPercent').textContent = `${percent.toFixed(percent >= 99.5 ? 1 : 0)}%`;
    fill.style.width = `${percent}%`;
    bar.setAttribute('aria-valuenow', percent.toFixed(1));

    const parts = [
      `${fmt.count(analysis.analyzed)} / ${fmt.count(analysis.total)} analyzed`,
      fmt.rate(analysis.rate),
    ];
    // etaSeconds is null unless a rate has been measured; never invent one.
    if (analysis.etaSeconds) parts.push(`ETA ${fmt.duration(analysis.etaSeconds)}`);
    if (analysis.failed > 0) parts.push(`${fmt.count(analysis.failed)} failed`);
    if (analysis.unavailable > 0) parts.push(`${fmt.count(analysis.unavailable)} not on this Mac`);
    // Only the text. A run in progress leaves the popover exactly where the user
    // put it — status frames arrive several times a second, so re-deciding the
    // open state here would either flicker or close it under the user's finger.
    setAnalysisDetail(parts.join(' · '));
  }

  /** The analysis popover's text, mirrored as the read-out's tooltip. */
  function setAnalysisDetail(text) {
    const detail = $('analysisDetail');
    detail.textContent = text || '';
    // The same sentence as a tooltip, so hovering answers the question without a
    // click. An empty one means there is nothing to report: the run is over, so
    // the popover closes rather than leaving an empty box over the grid.
    $('analysisToggle').title = detail.textContent || 'Show analysis detail';
    if (!detail.textContent) showAnalysisDetail(false);
  }

  /**
   * The one place the analysis popover's open state is decided: the click, the
   * failed phase and the end of a run all come through here.
   */
  function showAnalysisDetail(open) {
    $('analysisDetail').hidden = !open;
    $('analysisToggle').setAttribute('aria-expanded', open ? 'true' : 'false');
  }

  function percentWidth(value) {
    const number = Number(value);
    if (!Number.isFinite(number)) return 0;
    return Math.min(100, Math.max(0, number * 100));
  }

  function updateCounts() {
    $('matchCount').textContent = fmt.count(state.total);
    // "matching photos" / "matching videos" / "matching assets", from the filter
    // in force. The noun has to track `state.media` because the count does: on the
    // default `all` the number spans both media types, and a read-out that said
    // "photos" there would be wrong on the view most readers use rather than only
    // on a filtered one.
    $('matchCountNoun').textContent = fmt.plural(state.total, mediaNoun(), `${mediaNoun()}s`);
    if (!state.status) return;
    const analysis = state.status.analysis || {};
    const library = state.status.library || {};
    $('analyzedCount').textContent = fmt.count(analysis.analyzed);
    $('totalCount').textContent = fmt.count(analysis.total);
    $('headerTotal').textContent = fmt.count(library.total);
    $('headerAnalyzed').textContent = fmt.count(analysis.analyzed);

    // "assets", not "photos": `library.total` counts clips as well, and this is the
    // view most readers are on, so a "photos" label here would be wrong by default
    // rather than only under a filter.
    $('headerTotalLabel').textContent = 'assets';
    // Clips broken out, and only when there are any. The count comes from the
    // server: inferring it as `total - images` could not distinguish "this library
    // has no videos" from "this build has not scanned them yet", and offering a
    // Videos filter that quietly returns nothing is worse than not offering it.
    const videos = Number(library.videos) || 0;
    $('headerVideosWrap').hidden = videos === 0;
    if (videos > 0) $('headerVideos').textContent = fmt.count(videos);

    const problems = [];
    if (analysis.failed > 0) problems.push(`${fmt.count(analysis.failed)} failed`);
    if (analysis.unavailable > 0) problems.push(`${fmt.count(analysis.unavailable)} not on this Mac`);
    $('problemCounts').textContent = problems.join(' · ');
    $('problemSeparator').hidden = problems.length === 0;
  }

  function renderEmptyState() {
    const node = $('emptyState');
    let title = '';
    let detail = '';

    // The All Photos window has its own status line; this one belongs to the
    // grid, which is hidden while the window is open.
    if (state.all.active) { node.hidden = true; node.replaceChildren(); return; }

    // Anything on screen wins over any message: the empty state explains a blank
    // grid, never overlays a populated one.
    if (state.items.length > 0) {
      node.hidden = true;
      node.replaceChildren();
      return;
    }
    const status = state.status;
    const analysis = status ? status.analysis || {} : {};
    if (status && !AUTHORIZED_PHASES.includes(status.authorization)) {
      title = 'Photos access is required';
      detail = 'Grant PhotoCleaner access in System Settings › Privacy & Security › Photos, then relaunch.';
    } else if (!boundsUsable()) {
      title = 'Scoring your library';
      detail = 'PhotoCleaner scores every photo and clip with Apple’s on-device aesthetics model — '
        + 'one frame for a photograph, three for a video. Nothing is shown until the first scores exist, '
        + 'which takes a minute or two for a large library.';
    } else if (state.total === 0) {
      // The filter, named: "nothing here" has to say *which* nothing, or a Videos
      // filter that happens to match nothing reads as a library with no videos in
      // it. Three separate facts produce this one screen — no scores, nothing in
      // range, or a library of nothing but audio — and only the first is
      // recoverable by widening.
      if (state.media === 'videos') {
        title = 'No videos match this score range';
        detail = 'Widen the range, or choose “All” or “Photos” — PhotoCleaner can only show videos it has scored.';
      } else if (state.media === 'images') {
        title = 'No photos match this score range';
        detail = 'Widen the range, or choose “All” — PhotoCleaner can only show photos it has scored.';
      } else {
        title = 'No photos or videos match this score range';
        detail = 'Widen the range, or press “Reset” to follow the lowest and highest scores in the library.';
      }
    }

    if (!title) { node.hidden = true; node.replaceChildren(); return; }
    node.hidden = false;
    node.replaceChildren();
    const heading = document.createElement('h2');
    heading.textContent = title;
    const paragraphNode = document.createElement('p');
    paragraphNode.textContent = detail;
    node.append(heading, paragraphNode);
  }

  async function refreshStatus() {
    try {
      applyStatus(await api.get('/api/status'));
      $('connectionDot').classList.remove('offline');
    } catch {
      $('connectionDot').classList.add('offline');
    }
  }

  /* --------------------------------------------------------------------- SSE */

  function connectEvents() {
    const source = new EventSource('/api/events');
    source.addEventListener('open', () => $('connectionDot').classList.remove('offline'));
    source.addEventListener('status', (event) => {
      $('connectionDot').classList.remove('offline');
      let payload = null;
      try { payload = JSON.parse(event.data); } catch { return; } // ignore a malformed frame
      applyStatus(payload);
    });
    // A rebuild publishes when it finishes, so the group view refreshes on that
    // event rather than polling for the rest of the session. Ignored while the
    // view is closed — `applyGroupStatus` checks that itself, so a pass running in
    // the background cannot mutate state the user is not looking at.
    source.addEventListener('groups', (event) => {
      let payload = null;
      try { payload = JSON.parse(event.data); } catch { return; } // ignore a malformed frame
      applyGroupStatus(payload);
    });
    // EventSource reconnects on its own; a single dot update is all that is
    // needed — no listeners are re-registered and no grid state is rebuilt.
    source.addEventListener('error', () => $('connectionDot').classList.add('offline'));
  }

  /* ------------------------------------------------------------------ wiring */

  function wireControls() {
    /* --- the title bar --- */

    // Analysis detail. One popover, anchored in the header, dismissed by every way
    // a popover is dismissed — a second click, Escape, or a click anywhere else.
    // Each dismissal is here because each is a gesture a user will actually make,
    // and a missed one is a stale figure floating over the grid.
    $('analysisToggle').addEventListener('click', () => {
      showAnalysisDetail($('analysisDetail').hidden);
    });
    document.addEventListener('click', (event) => {
      const detail = $('analysisDetail');
      if (detail.hidden) return;
      if (detail.contains(event.target) || $('analysisToggle').contains(event.target)) return;
      showAnalysisDetail(false);
    });
    document.addEventListener('keydown', (event) => {
      if (event.key === 'Escape' && !$('analysisDetail').hidden) {
        showAnalysisDetail(false);
        $('analysisToggle').focus({ preventScroll: true });
      }
    });

    $('lowerRange').addEventListener('input', (event) => {
      const value = sliderToValue(Number(event.target.value));
      setBounds(value, state.upper);
      scheduleReload();
    });
    $('upperRange').addEventListener('input', (event) => {
      const value = sliderToValue(Number(event.target.value));
      setBounds(state.lower, value);
      scheduleReload();
    });
    // Un-pins: from here on the bounds track the observed min/max again, so this is
    // also the only way to hand control back to the data.
    $('resetBounds').addEventListener('click', () => {
      state.pinned = false;
      followObservedBounds();
      syncRangeUI();
      updateSelectionBar();
      scheduleReload(0);
    });

    document.querySelectorAll('.chip[data-sort]').forEach((chip) => {
      chip.addEventListener('click', () => {
        if (state.sort === chip.dataset.sort) return;
        state.sort = chip.dataset.sort;
        document.querySelectorAll('.chip[data-sort]').forEach((other) => other.classList.toggle('active', other === chip));
        scheduleReload(0);
      });
    });

    // The media filter. No clear-on-second-click, unlike the album chips: "All"
    // is one of the three buckets rather than the absence of a filter, so there
    // is no fourth state to fall back to and a click on the pressed chip is
    // simply a click on the chip it already names. The pressed state is painted
    // from `state.media` and not from the click, because the server's echo writes
    // that field too — see `adoptAppliedMedia`.
    for (const chip of document.querySelectorAll('[data-media]')) {
      chip.addEventListener('click', () => selectMedia(chip.dataset.media));
    }

    $('icloudDownloads').addEventListener('change', async (event) => {
      const enabled = event.target.checked;
      const { ok, payload } = await api.post('/api/settings', { downloadFromICloud: enabled });
      if (ok && payload && payload.settings) applyStatus(payload);
      else { event.target.checked = !enabled; toast('Could not change the setting — ' + errorText(payload, 'the server refused'), 'error'); return; }
      toast(enabled
        ? 'Photos stored only in iCloud will now be downloaded for analysis. Thumbnails still never reach iCloud.'
        : 'iCloud downloads are off — assets that live only in iCloud are skipped.');
    });

    $('rescanButton').addEventListener('click', async () => {
      await api.post('/api/library/rescan', {});
      toast('Rescanning the Photos library…');
    });

    // Album membership is read in the background, one album at a time, and the
    // first request is what starts it. Polled only while a pass is actually
    // running, so an idle library issues no album requests at all — the same
    // discipline §4.12 requires of the grid.
    $('albumReindex').addEventListener('click', async () => {
      await api.post('/api/albums/index', {});
      toast('Reading your albums…');
      loadAlbums();
    });

    $('retryButton').addEventListener('click', async () => {
      await api.post('/api/analysis/retry', {});
      toast('Re-queueing failed and unavailable assets…');
    });

    $('selectAllMatching').addEventListener('click', () => selectAllMatching());
    $('clearSelection').addEventListener('click', () => clearSelection());
    // One button, one meaning: it destroys the selection now. There is no modifier
    // to hold and no second step to reach, because the count it carries is the
    // server's own and the server refuses the deletion if that count no longer
    // holds — the safety lives where it can be enforced, not in a chord.
    $('deleteButton').addEventListener('click', () => deleteSelection());

    $('loadMoreButton').addEventListener('click', () => loadNextPage());

    $('lightboxClose').addEventListener('click', () => closeLightbox());
    $('lightboxPrev').addEventListener('click', () => navigateLightbox(-1));
    $('lightboxNext').addEventListener('click', () => navigateLightbox(1));
    $('lightboxStage').addEventListener('click', (event) => {
      // The end of a drag, not a click on the photograph: a reader who panned a
      // magnified photo would otherwise be paged to the next one by letting go.
      const dragged = lightboxZoom.dragged;
      lightboxZoom.dragged = false;
      if (dragged) return;
      // The still, and only the still. Clicking a clip's picture is a click on a
      // transport — the reader is aiming at the play button, the scrub bar or the
      // volume, and paging the overlay out from under that would be the exact
      // "it kept playing under the next photo" bug the queue reindexing comments
      // describe, arrived at from the other end.
      if (event.target === $('lightboxImage')) navigateLightbox(1);
    });
    // Zoom lives on the stage rather than on the photograph, because the still is
    // `object-fit: contain` inside a stage-sized box (see the stylesheet): a gesture
    // that lands on the letterbox beside a panorama is still a gesture on the
    // photograph, and the events that bubble from either element arrive here.
    $('lightboxStage').addEventListener('wheel', zoomWheel, { passive: false });
    $('lightboxStage').addEventListener('pointerdown', zoomPanStart);
    $('lightboxStage').addEventListener('pointermove', zoomPanMove);
    $('lightboxStage').addEventListener('pointerup', zoomPanEnd);
    $('lightboxStage').addEventListener('pointercancel', zoomPanEnd);
    $('lightboxOpenInPhotos').addEventListener('click', () => {
      const row = currentLightboxRow();
      if (!row) return;
      // The same function the menu's "Open in Photos" calls, including the toast
      // that goes out before the hand-off: the answer is Photos' own, and it
      // arrives after the app has already come to the front.
      toast('Asking Photos to open that photo…', 'info');
      revealInPhotos(row);
    });
    // Right-click on the inspected photo. Suppressing the browser's own menu is
    // scoped to the two elements the photo is actually drawn in — the chrome
    // around them keeps the native menu, because "Copy Image Address" on a
    // PhotoCleaner thumbnail is a reasonable thing for someone to want and this
    // app has nothing to do with it. What replaces it is the same PhotoCleaner
    // menu a grid tile gets.
    //
    // One listener on the stage rather than one per element, because the element
    // changes: a clip is a `<video>` and a still is an `<img>`, and a pair of
    // listeners would be a pair of places for the menu to stop working when the
    // media type does. `event.target` is the check that keeps the scoping, and it
    // is the *same* check the still has always had — the menu has to keep working
    // when the photo is a `<video>`, so the filter is "is this the media
    // element", not "is this an image".
    $('lightboxStage').addEventListener('contextmenu', (event) => {
      const stage = $('lightboxStage');
      if (event.target !== $('lightboxImage') && event.target !== $('lightboxVideo')) return;
      const row = currentLightboxRow();
      if (!row) return;
      event.preventDefault();
      event.stopPropagation();
      openTileMenu(event.target, row, { x: event.clientX, y: event.clientY },
                   // The media element is not a control the menu should hand focus
                   // back to — a `<video>` with `controls` can hold focus, and
                   // returning it there would leave focus on an element that is
                   // about to be hidden or torn down. So the menu names the button
                   // that closes the lightbox, as it did when the photo could not
                   // hold focus at all.
                   $('lightboxClose'));
    });
    // Favouriting from the lightbox goes through the same code path as the tile
    // menu's item — one implementation of a library write, with one confirmation
    // and one report.
    $('lightboxFavoriteToggle').addEventListener('click', () => {
      const row = currentLightboxRow();
      if (row) setFavoriteOnTargets([row.id], !row.favorite);
    });
    $('lightboxDelete').addEventListener('click', () => {
      const row = currentLightboxRow();
      if (!row) return;
      deletePhotos({ mode: 'ids', ids: [row.id] });
    });

    $('allPhotosBack').addEventListener('click', () => closeAllPhotos());
    $('allPhotosToAnchor').addEventListener('click', () => {
      const index = state.all.anchorIndex;
      scrollAllPhotosIntoView(index);
      const tile = $('allPhotosDays').querySelector(`.tile[data-index="${index}"]`);
      if (tile) tile.focus({ preventScroll: true });
    });

    // --- context menu dismissal ---
    //
    // One capture-phase listener for every way the menu can go away, because a
    // dismissal missed in one place is a menu floating over the grid with no way
    // to dismiss it. Each case is here because each is a case a user will
    // actually perform while the menu is open.

    // Outside click. Capture phase, so it wins over any tile's own handler: a
    // right-click on another tile opens its menu *after* this closes the old
    // one, which is the correct order and needs no special-casing.
    document.addEventListener('pointerdown', (event) => {
      if (!tileMenuIsOpen()) return;
      if ($('tileMenuLayer').contains(event.target)) return;
      closeTileMenu();
    }, true);

    // Scroll. The menu is positioned against the viewport, so scrolling the page
    // or the All Photos window out from under it would leave it pointing at
    // nothing. Capture phase again: a scroll inside the menu itself is one of
    // the ways to reach an item that did not fit, and `contains` lets it through.
    const scrollListener = (event) => {
      if (!tileMenuIsOpen()) return;
      if (event.target === $('tileMenuLayer') || $('tileMenuLayer').contains(event.target)) return;
      closeTileMenu();
    };
    window.addEventListener('scroll', scrollListener, { capture: true, passive: true });

    // Resize. A menu placed for the old viewport can now be off-screen, and its
    // flip calculation is only valid for the size it was measured in.
    window.addEventListener('resize', () => closeTileMenu());

    // Tile removal. Deleting, filtering or scrolling in a new page can remove
    // the tile the menu belongs to; `isConnected` is the check, so a menu whose
    // photo has gone closes rather than acting on a detached row.
    if (typeof MutationObserver === 'function') {
      const removalObserver = new MutationObserver(() => {
        if (!tileMenuIsOpen()) return;
        const tile = tileMenu.tile;
        if (!tile || !tile.isConnected) closeTileMenu();
      });
      // Every place a photo in this app can be pointed at, because every one of
      // them can rebuild its contents underneath an open menu: the score grid and
      // the All Photos window on a new page or a deletion, and the group list on a
      // reload — which a rebuild finishing or a sort change triggers with no click
      // from the user to dismiss the menu first.
      removalObserver.observe($('grid'), { childList: true });
      removalObserver.observe($('allPhotosDays'), { childList: true, subtree: true });
      removalObserver.observe($('groupsList'), { childList: true, subtree: true });
    }

    document.addEventListener('keydown', (event) => {
      // Tab is handled first, and only while an overlay owns the screen, so
      // focus can never wander into the controls behind the lightbox. The context
      // menu is an overlay too, and it is checked first because it is the
      // innermost one: Tab should leave the menu, not the page behind it.
      const overlay = state.lightbox.open ? $('lightbox')
        : (tileMenuIsOpen() ? $('tileMenuLayer') : null);
      if (event.key === 'Tab' && overlay) {
        if (tileMenuIsOpen()) { closeTileMenu(); event.preventDefault(); return; }
        trapTab(overlay, event);
        return;
      }

      // Menu keys, handled here because the menu's own listener cannot see
      // Escape once focus has left its items.
      if (tileMenuIsOpen()) {
        if (event.key === 'Escape') {
          event.preventDefault();
          closeTileMenu();
          return;
        }
        if (event.key === 'ArrowDown') { event.preventDefault(); moveTileMenuFocus(1); return; }
        if (event.key === 'ArrowUp') { event.preventDefault(); moveTileMenuFocus(-1); return; }
        if (event.key === 'Home') { event.preventDefault(); moveTileMenuFocus('first'); return; }
        if (event.key === 'End') { event.preventDefault(); moveTileMenuFocus('last'); return; }
        // Anything else belongs to the page again: the menu is dismissed so a
        // shortcut typed past it reaches the grid, exactly as it would in
        // Finder once the menu is gone.
        if (event.key !== 'Enter' && event.key !== ' ') closeTileMenu();
        return;
      }

      // Delete and Backspace destroy the selection — with or without a modifier,
      // because on a Mac keyboard the "delete" key *is* Backspace, and ⌘⌫ is the
      // same gesture spelled with the wrong arrow. There is no ⌥⌫ variant and no
      // ⌘Z: a deletion goes to Recently Deleted, and the way back from there is
      // Photos, not this app.
      if (event.key === 'Delete' || event.key === 'Backspace') {
        const target = event.target;
        // A text field's own editing wins: Backspace in the album filter has to
        // delete a character, not a photo.
        if (target instanceof HTMLElement && (/^(INPUT|SELECT|TEXTAREA)$/.test(target.tagName) || target.isContentEditable)) return;
        if (state.deleting) return;
        // In the preview the visible photo is the target, matching that view's own
        // button; everywhere else it is the selection.
        if (state.lightbox.open) {
          const row = currentLightboxRow();
          if (!row) return;
          event.preventDefault();
          deletePhotos({ mode: 'ids', ids: [row.id] });
          return;
        }
        if (!selectionHasContent()) return;
        event.preventDefault();
        deleteSelection();
        return;
      }

      if (event.key !== 'Escape' && event.key !== 'ArrowLeft' && event.key !== 'ArrowRight'
          && event.key !== ' ' && !ZOOM_KEYS.has(event.key)) return;
      const target = event.target;
      if (target instanceof HTMLElement && /^(INPUT|SELECT|TEXTAREA)$/.test(target.tagName)) return;
      // A clip's own transport keeps the keys it owns, or paging with → would seek
      // the clip and move the overlay at the same time. Escape still closes from
      // anywhere, because it is the one key with no meaning inside a `<video>`.
      // `buildTile`'s keydown is untouched: this is the *document* handler, and a
      // tile's Space/Enter contract is unchanged by either line.
      const onClipControls = state.lightbox.open
        && target instanceof HTMLElement
        && target.closest('#lightboxVideo') !== null;
      if (event.key === 'Escape') {
        // Lightbox first, then whichever secondary view is open: the same "one level
        // back per press" rule the rest of the interface already follows.
        if (state.lightbox.open) { closeLightbox(); return; }
        if (state.all.active) closeAllPhotos();
        if (state.groups.active) closeGroups();
        return;
      }
      if (onClipControls) return;
      if (!state.lightbox.open) return;
      if (ZOOM_KEYS.has(event.key)) {
        // Bare keys only: ⌘+ and ⌘- are the *browser's* page zoom, and claiming
        // them here would take a control away from the reader rather than add one.
        if (event.metaKey || event.ctrlKey) return;
        event.preventDefault();
        zoomKey(event.key);
        return;
      }
      if (event.key === 'ArrowLeft') { event.preventDefault(); navigateLightbox(-1); }
      else if (event.key === 'ArrowRight') { event.preventDefault(); navigateLightbox(1); }
      else if (event.key === ' ') {
        event.preventDefault();
        // Space is the preview toggle, so inside the preview it quits. Opening
        // and closing on the same key is what makes it a toggle rather than two
        // shortcuts: the key does the same thing wherever you press it, which is
        // the whole point of a toggle. (Unless the key went to the clip's own
        // transport, which is what `onClipControls` above is about — Space is
        // play/pause on a `<video>`, and closing the window under it would be
        // paging away from a clip the reader is trying to watch.)
        closeLightbox();
      }
    });

    // Primary pagination trigger; the Load-more button remains as the manual
    // fallback for when the observer is unavailable or unhelpful.
    if (typeof IntersectionObserver === 'function') {
      const observer = new IntersectionObserver((entries) => {
        if (entries.some((entry) => entry.isIntersecting)) loadNextPage();
      }, { rootMargin: `${PAGINATION_MARGIN}px 0px` });
      observer.observe($('sentinel'));

      // The All Photos window pages in both directions, so it needs a sentinel at
      // each end rather than one at the bottom. Both observers are permanent —
      // the elements never leave the document, only their container's `hidden`
      // does — and each callback checks that the window is actually open.
      const allPhotosObserver = (which) => new IntersectionObserver((entries) => {
        if (state.all.active && entries.some((entry) => entry.isIntersecting)) loadAllPhotosPage(which);
      }, { rootMargin: `${ALL_PHOTOS_MARGIN}px 0px` });
      allPhotosObserver('older').observe($('allPhotosOlderSentinel'));
      allPhotosObserver('newer').observe($('allPhotosNewerSentinel'));

      // The Similar Groups list scrolls continuously in **both** directions, so it
      // needs a sentinel at each end too. One bottom sentinel can only ever grow
      // the list forwards, which left the group just examined unreachable without
      // reopening the view. `rootMargin` is generous so the fetch begins before the
      // edge is reached and the strip does not visibly stall there.
      const groupsObserver = (which) => new IntersectionObserver((entries) => {
        if (!state.groups.active || state.groups.focused) return;
        if (!entries.some((entry) => entry.isIntersecting)) return;
        const edges = groupsEdges();
        // Asking at an end that has nothing is how a scroll listener ends up in a
        // fetch loop: the sentinel stays visible, so every intersection fires again.
        if (which === 'top' && !edges.top) return;
        if (which === 'bottom' && !edges.bottom) return;
        loadGroups(which);
      }, { rootMargin: `${PAGINATION_MARGIN}px 0px` });
      groupsObserver('top').observe($('groupsSentinelTop'));
      groupsObserver('bottom').observe($('groupsSentinelBottom'));
    }

    // Similar Groups: open, back, rebuild, and the two within-group orders.
    $('groupsButton').addEventListener('click', () => openGroups());
    $('groupsBack').addEventListener('click', () => closeGroups());
    $('groupsRebuild').addEventListener('click', () => rebuildGroups());
    for (const chip of document.querySelectorAll('[data-group-order]')) {
      chip.addEventListener('click', () => setGroupOrder(chip.dataset.groupOrder));
    }
  }

  /**
 * Re-reads the grouping status without touching the list on screen.
 *
 * Separate from `loadGroups` because the two have different jobs during a pass:
 * the list is mid-replacement and must not be paged, but the *status* still has to
 * be polled so the view can say "still grouping" instead of falling back to an
 * empty state that claims there are no groups.
 *
 * `/api/groups` is the only route that reports it, so the cheapest honest way to
 * read the status is to ask for a page of one and discard the rows.
 */
  async function loadGroupsStatus() {
    if (state.groups.loading) return;
    state.groups.loading = true;
    const generation = state.groups.generation;
    updateGroupsBusy();
    try {
      // `album` and `media` are sent even though the rows are discarded: the status has
      // to come from the same result set the list is showing, and both an album
      // this instance has not read and a media value it does not recognise are a
      // 400 rather than a silently unfiltered answer.
      const params = new URLSearchParams({
        order: state.groups.order, limit: '1', offset: '0',
        album: state.album, media: state.media,
      });
      const data = await api.get('/api/groups?' + params.toString());
      if (generation !== state.groups.generation || !state.groups.active) return;
      state.groups.status = data.status || null;
      renderGroups();
    } catch {
      // A failed status poll is not worth reporting: the pass is still running and
      // the next tick will try again. Losing one sample of "still grouping" costs a
      // few seconds of wording; surfacing an error would suggest something broke.
    } finally {
      if (generation === state.groups.generation) {
        state.groups.loading = false;
        updateGroupsBusy();
      }
    }
  }

  /** Polls the album list only while an index pass is actually running. */
  let albumPollTimer = null;
  function scheduleAlbumPoll() {
    clearTimeout(albumPollTimer);
    if (!state.albums.indexing) return;
    albumPollTimer = setTimeout(async () => {
      await loadAlbums();
      scheduleAlbumPoll();
    }, ALBUM_POLL_MS);
  }

  /* ---------------------------------------------------------- similar groups */

  /**
   * Opens the Similar Groups view — the list of every group, or one of them.
   *
   * Strictly a read view: it issues GETs, shares the selection with the score
   * grid rather than owning one, and Back restores the view it replaced exactly
   * where it was. The two within-group orders are a *sort*, never a filter and
   * never a recommendation — nothing here can select or delete anything on the
   * user's behalf.
   *
   * `options.groupId` is what "Show Similar Photos" resolves to. It does not open
   * a second browser: it opens *this* one with the list taken away, so the header,
   * the sort control, the group card and Back are the same code either way.
   * `options.originId` is the photo it was opened for; it is marked on arrival and
   * never moved to the front, because reordering to suit the way the user arrived
   * would defeat the sort they asked for.
   *
   * ## Why the return context is recorded, not assumed
   *
   * "Back to the grid" was the only possible answer while this view was reachable
   * from one place. It is not from anywhere else: it is now also reachable from a
   * tile in All Photos and from a cell in the group list, and answering "the grid"
   * to either of those throws away the place the user was standing. All Photos
   * costs nothing to return to because its rows and its DOM are left untouched
   * while this view is open — Back unhides the window rather than re-fetching
   * sixty photos around the same anchor.
   */
  async function openGroups(options = {}) {
    const groupId = typeof options.groupId === 'string' ? options.groupId : '';
    // Already showing the list, and no group named: the button the user pressed is
    // asking for what is on screen.
    if (state.groups.active && !groupId) return;
    // Reached from inside the group view itself — a cell in the list. Back then
    // belongs to the list, and the place to come back to is where it was, so the
    // context is replaced rather than stacked.
    captureGroupsReturn(options.originId, state.groups.active);

    if (state.lightbox.open) closeLightbox();
    // A menu anchored to a photo in a view that is about to be hidden would be
    // left pointing at nothing.
    closeTileMenu();
    // All Photos' own chrome is hidden too when that is where we came from, or the
    // two views would be stacked on top of each other.
    if (state.groups.returnView === 'allPhotos') {
      $('allPhotosBar').hidden = true;
      $('allPhotosView').hidden = true;
    }
    state.all.active = false;

    state.groups.active = true;
    state.groups.generation += 1;
    // A view opened for a photo is focused even when no group was found for it:
    // "no similar photos" is still an answer about that one photo, and it belongs
    // under the heading that says so rather than the list's.
    state.groups.focused = Boolean(options.originId) || Boolean(groupId);
    state.groups.focusId = groupId;
    state.groups.originId = groupId ? (options.originId || '') : '';
    state.groups.rows = [];
    state.groups.startOffset = 0;
    state.groups.endOffset = 0;
    state.groups.total = 0;
    state.groups.loading = false;
    state.groups.note = groupId ? '' : (options.emptyNote || '');
    // The album chips live in the control panel, which this view hides — so the
    // filter it is honouring has to be readable here, or the list is narrowed with
    // no visible cause.
    $('groupsBar').hidden = false;
    $('groupsView').hidden = false;
    $('grid').hidden = true;
    $('emptyState').hidden = true;
    $('sentinel').hidden = true;
    $('loadMore').hidden = true;
    $('controlPanel').hidden = true;
    syncGroupOrderChips();
    syncGroupsHeading();
    $('groupsBack').focus();
    await loadGroups('first');
  }

  /* -------------------------------------------------- show similar photos */

  /**
   * Opens the Similar Group a photo belongs to, in the group browser.
   *
   * ## Why "show" and not "find"
   *
   * Grouping already happened. When FeaturePrint analysis ran, PhotoCleaner
   * decided which photos were alternate captures of each other and wrote the
   * answer to `similar_group_members`. This asks for that answer — one GET, one
   * indexed read on the far side — and then navigates. It is the reason the
   * action can be a menu item: there is no search to wait for, and nothing here
   * decodes an image, generates a FeaturePrint or compares two photos.
   *
   * That is also why it is never disabled. Whether this photo has a group, and
   * whether analysis has reached it yet, are both things the user is better told
   * by a result page than by an item that has decided for them that they may not
   * ask. Both answers open the same view and say which of the two they are.
   *
   * ## Why the two empty states are not one
   *
   * "No similar photos found" and "similarity analysis has not reached this
   * photo" are both an absent group, and they are opposite facts: one is a claim
   * about the library, the other about the progress of a background pass.
   * Collapsing them would tell a user their photo is unique when nothing has
   * compared it to anything yet. Neither state creates a group of one — a group
   * needs two members to mean anything, and a single photo is not a result.
   */
  async function showSimilarPhotos(id) {
    let answer;
    try {
      answer = await api.get(`/api/photo/${encodeURIComponent(id)}/similar`);
    } catch (error) {
      // Stay where the user is. A failed lookup is not a reason to throw away
      // their place in a 53,000-photo grid.
      toast('Could not look up similar photos — '
            + (error.message || 'the server refused the request'), 'error');
      return;
    }
    const groupId = answer && typeof answer.groupId === 'string' && answer.groupId ? answer.groupId : '';
    const emptyNote = groupId ? '' : similarPhotosEmptyNote(answer);
    await openGroups({ groupId, originId: id, emptyNote });
  }

  /** Why there is no group to show, in the words that are actually true. */
  function similarPhotosEmptyNote(answer) {
    if (answer && answer.analyzed === false) {
      return 'Similar-photo analysis is not available for this photo yet. '
        + 'PhotoCleaner reads one FeaturePrint per photo as it scores them, and has not reached this one — '
        + 'nothing needs doing unless analysis is paused or failing.';
    }
    return 'No similar photos found. PhotoCleaner has compared this photo with the rest of the library '
      + 'and found no other photo close enough to be an alternate capture of it.';
  }

  /**
   * Records which view is underneath, and where in it.
   *
   * Read before anything is hidden, because `closeLightbox` scrolls the All Photos
   * window back to its anchor — a scroll offset read after that would be the
   * lightbox's idea of the place rather than the user's.
   *
   * `withinGroups` marks the one case where the view being replaced is the group
   * list itself, which is a return target in its own right.
   */
  function captureGroupsReturn(originId, withinGroups = false) {
    state.groups.returnView = withinGroups ? 'groups' : (state.all.active ? 'allPhotos' : 'grid');
    state.groups.returnScrollY = window.scrollY;
    state.groups.returnFocusId = originId || '';
  }

  /**
   * Leaves the group view, restoring whatever was underneath.
   *
   * `leave` distinguishes two callers that both need the group view gone but do
   * **not** mean the same thing by it:
   *
   * - The Back button and Escape pass `false`. Back from a focused group returns
   *   to the list it was opened from, which is the whole point of the view being
   *   two-deep.
   * - A navigation that *replaces* the view passes `true`. Going "back into the
   *   list" and then opening something else on top of it would leave two views
   *   active and both on screen at once.
   */
  async function closeGroups({ leave = false } = {}) {
    if (!state.groups.active) return;
    const back = {
      view: state.groups.returnView,
      scrollY: state.groups.returnScrollY,
      focusId: state.groups.returnFocusId,
    };
    // Abandon any page still in flight before anything else. The response is
    // discarded on the generation check either way, but dropping `loading` as well
    // is what lets the list be re-fetched below when Back was pressed mid-request —
    // otherwise `loadGroups` sees itself already loading, returns, and leaves the
    // view blank.
    state.groups.generation += 1;
    state.groups.loading = false;
    // A menu anchored to one of the group cards goes with them.
    closeTileMenu();
    state.groups.rows = [];
    state.groups.focusId = '';
    state.groups.originId = '';

    // Back out of one group into the list it was chosen from. This is the only
    // Back that does not leave the view: the bar stays, the cards are replaced,
    // and the list is re-fetched because its rows went with the focused group.
    // Nothing else is torn down, so the position in the list is the only thing
    // that has to be put back.
    if (back.view === 'groups' && !leave) {
      state.groups.active = true;
      state.groups.focused = false;
      state.groups.note = '';
      // A focused view is one group, so the window offsets are meaningless to a
      // list that pages by group — back to the first page.
      state.groups.startOffset = 0;
      state.groups.endOffset = 0;
      state.groups.total = 0;
      syncGroupsHeading();
      $('groupsList').replaceChildren();
      window.scrollTo(0, back.scrollY);
      $('groupsBack').focus();
      await loadGroups('first');
      return;
    }

    state.groups.active = false;
    state.groups.focused = false;
    $('groupsBar').hidden = true;
    $('groupsView').hidden = true;
    $('groupsList').replaceChildren();
    syncGroupsHeading();

    if (back.view === 'allPhotos') {
      // The window was hidden, never emptied, so restoring it is unhiding it.
      state.all.active = true;
      $('allPhotosBar').hidden = false;
      $('allPhotosView').hidden = false;
      $('controlPanel').hidden = true;
      $('grid').hidden = true;
      $('emptyState').hidden = true;
      $('sentinel').hidden = true;
      $('loadMore').hidden = true;
      renderAllPhotosBar();
      renderAllPhotosStatus();
    } else {
      $('controlPanel').hidden = false;
      $('grid').hidden = false;
      $('sentinel').hidden = false;
      $('emptyState').hidden = false;
    }
    // Force the restored view back into flow before scrolling: `scrollTo` is
    // clamped to the current document height, which is only correct once the
    // layout is done.
    const host = back.view === 'allPhotos' ? $('allPhotosDays') : $('grid');
    void host.offsetHeight;
    window.scrollTo(0, back.scrollY);
    updateLoadMore();
    renderEmptyState();
    updateSelectionBar();
    requestAnimationFrame(() => {
      // Focus first, with scrolling suppressed, then place the scroll — the other
      // order lets `focus()` win and undo the restore.
      const tile = back.focusId ? host.querySelector(`.tile[data-id="${CSS.escape(back.focusId)}"]`) : null;
      if (tile) tile.focus({ preventScroll: true });
      window.scrollTo(0, back.scrollY);
    });
  }

  function syncGroupOrderChips() {
    for (const chip of document.querySelectorAll('[data-group-order]')) {
      const active = chip.dataset.groupOrder === state.groups.order;
      chip.classList.toggle('active', active);
      chip.setAttribute('aria-pressed', active ? 'true' : 'false');
    }
  }

  /**
   * The bar's own two lines, which differ between the two modes.
   *
   * A single group is a different thing from a list of them and has to say so: the
   * title is what tells the user this is *their* photo's group rather than the
   * cleanup list. The sort control is untouched in both, because it is the same
   * browser.
   */
  function syncGroupsHeading() {
    const focused = state.groups.focused;
    $('groupsTitle').textContent = focused ? 'Similar Photos' : 'Similar Groups';
    // Both filters are named here because they silently narrow the list: without
    // this line a user who filtered the grid to one album and then opened Similar
    // Groups would see fewer groups and have no way to tell that from a library
    // that simply has fewer duplicates. And both chips live in the control panel,
    // which this view hides — so the heading is the only place either is visible.
    const albumScope = state.album === 'all' ? '' : ` · in ${albumName(state.album)}`;
    const mediaScope = state.media === 'all' ? '' : ` · ${mediaScopeLabel()}`;
    $('groupsSub').textContent = (focused
      ? 'The photos PhotoCleaner groups with the one you came from'
      : 'Photos that look like alternate captures of the same shot · sorted within each group')
      + albumScope + mediaScope;
  }

  /** The album in force, named the way a sentence would name it. */
  function albumScopeLabel() {
    return state.album === 'all' ? 'all albums' : albumName(state.album);
  }

  /**
   * Why an album-filtered group list is empty.
   *
   * A separate sentence from the unfiltered one because "no similar groups" and "no
   * similar groups *in this album*" are different facts, and the second one is not
   * evidence about the library at all: a user who concludes their album has no
   * duplicates when a neighbouring album has the whole burst has been told
   * something false.
   */
  function groupsEmptyNote() {
    // Videos are never grouped — see ARCHITECTURE §9 for the reasoning — so this
    // filter has nothing to show by construction. Saying "No similar groups
    // found" would be a claim about the library that happens to be false, and the
    // kind of false claim that convinces a reader their clips are duplicates of
    // nothing. It says what is true instead, and names the filter to change.
    if (state.media === 'videos') {
      return 'Videos are never grouped. A clip is scored and browsed like any other asset, '
        + 'but PhotoCleaner does not put it in a Similar Group — choose “All” or “Photos” to see groups.';
    }
    if (state.album === 'all') {
      return 'No similar groups found. Photos captured seconds apart that look alike will appear here.';
    }
    return `No similar groups in ${albumName(state.album)}. `
      + 'Similar Groups shows the groups that have at least one photo in the album you selected — '
      + 'a group can exist elsewhere in your library without appearing here.';
  }

  /**
   * Why a focused group has nothing to show under an album filter.
   *
   * The group is real and is not being retired: the photo it was opened for is
   * simply not in the album, so none of its members are either. Saying "not found"
   * here would send the user looking for a regrouping that is not needed.
   */
  function albumEmptyNote(group) {
    const total = Number(group.memberCount) + (Number(group.hiddenMemberCount) || 0);
    return `None of this group's ${fmt.plural(total, 'photo', 'photos')} ${fmt.plural(total, 'is', 'are')} `
      + `in ${albumScopeLabel()}. Choose “All albums” to see the whole group.`;
  }

  /**
 * Loads groups into the list window.
 *
 * `direction` is `'first'`, `'top'` or `'bottom'`. The first is the whole view —
 * one page from the start of the list. The other two grow the existing window at
 * that end, which is what makes the strip continuous: nothing already loaded is
 * discarded, so scrolling back up is instant rather than another fetch.
 *
 * Growing at the top has one trap, handled by the caller: rows are prepended, so
 * the document grows *above* the viewport and the reader would be thrown
 * backwards by exactly the height that was added.
 */
  async function loadGroups(direction = 'first') {
    const groups = state.groups;
    if (groups.loading) return;
    // Only the first load may start a fresh window; the two ends need something
    // already on screen to grow.
    if (direction !== 'first' && groups.rows.length === 0) return;
    groups.loading = true;
    groups.loadingAt = direction;
    const generation = groups.generation;
    updateGroupsBusy();
    try {
      if (groups.focused) {
        if (groups.focusId) {
          // One group, through the route the group browser already reads. A focused
          // group is a closed set that arrived whole, so there is nothing to grow.
          // The same two dimensions the grid is filtered by, for the same reason: a group
            // list narrowed by filters the reader cannot see is a list they will
            // misread as the whole library. The group view hides the control
            // panel that holds both chips, so `syncGroupsHeading` has to name them.
            const params = new URLSearchParams({
              id: groups.focusId, order: groups.order,
              album: state.album, media: state.media,
            });
          const group = await api.get('/api/group?' + params.toString());
          if (generation !== groups.generation || !groups.active) return;
          // A group can exist and still hold nothing from the album in view — the
          // photo it was opened for need not be in it. That is a fact about this
          // album and this group, not a missing group, so it is said rather than
          // rendered as an empty card with no members and no explanation.
          const kept = Array.isArray(group && group.items) ? group.items.length : 0;
          if (group && group.id && kept === 0) {
            groups.rows = [];
            groups.total = 0;
            groups.note = albumEmptyNote(group);
          } else {
            groups.rows = group && group.id ? [group] : [];
            groups.total = groups.rows.length;
            // A group that does have members from the album is not an empty state,
            // so a note left over from the previous filter has nothing to explain.
            groups.note = '';
          }
        } else {
          // Focused, and there is no group for this photo. There is nothing to
          // fetch — and reaching for the list here would be the one thing this
          // view must not do, since it would answer a question about a single
          // photo with a list of every group. `note` already holds the reason.
          groups.rows = [];
          groups.total = 0;
        }
      } else {
        const atTop = direction === 'top';
        // The top pull asks for the page *before* the window, clamped at zero: at
        // the very start of the list there is nothing above, and asking for a
        // negative offset would be the server's error, not an empty page.
        const offset = atTop
          ? Math.max(0, groups.startOffset - GROUPS_PAGE)
          : (direction === 'first' ? 0 : groups.endOffset);
        const params = new URLSearchParams({
          order: groups.order,
          limit: String(GROUPS_PAGE),
          offset: String(offset),
          album: state.album,
          media: state.media,
        });
        const data = await api.get('/api/groups?' + params.toString());
        // A page for a superseded order must not splice itself into the view.
        if (generation !== groups.generation || !groups.active) return;
        const page = Array.isArray(data.groups) ? data.groups : [];
        groups.total = Number(data.total) || 0;
        groups.status = data.status || null;

        if (direction === 'first') {
          groups.rows = page;
          groups.startOffset = 0;
          groups.endOffset = page.length;
        } else if (atTop) {
          // Prepended, so the window moves; nothing already loaded is dropped.
          // The overlap with the rows we already hold is trimmed by identity rather
          // than arithmetic, because a rebuild between the two fetches can shift
          // every offset by a different amount.
          const seen = new Set(groups.rows.map((row) => row.id));
          const fresh = page.filter((row) => row && !seen.has(row.id));
          if (fresh.length) {
            groups.rows = [...fresh, ...groups.rows];
            groups.startOffset = offset;
          } else {
            // Nothing new above: this is the top of the list. Recording it stops
            // every further scroll to the top from asking again.
            groups.startOffset = 0;
          }
        } else {
          const seen = new Set(groups.rows.map((row) => row.id));
          const fresh = page.filter((row) => row && !seen.has(row.id));
          groups.rows = [...groups.rows, ...fresh];
          groups.endOffset = offset + page.length;
        }
      }
      renderGroups();
    } catch (error) {
      if (generation === groups.generation) {
        // A rebuild replaces every group, and a group's id is derived from its
        // members — so regrouping can produce a different id and retire the one
        // this view was opened for. Say so rather than leaving a dead end.
        if (groups.focusId) {
          groups.rows = [];
          groups.note = 'That group is no longer stored — the library has been regrouped since you opened it.';
        } else {
          groups.note = error.message || 'The server refused the request.';
        }
      }
      renderGroups();
    } finally {
      if (generation === state.groups.generation) {
        state.groups.loading = false;
        state.groups.loadingAt = '';
        updateGroupsBusy();
      }
    }
  }

  /**
   * Whether more groups can be pulled in at an end.
   *
   * A boolean per end rather than a derived position: the list grows at whichever
   * end the reader reaches, so "which page am I on" is not a question it can answer.
   */
  function groupsEdges() {
    const groups = state.groups;
    if (groups.focused) return { top: false, bottom: false };
    const total = Math.max(0, Number(groups.total) || 0);
    // `total` is 0 before the first response, which means *unknown*, not *none* —
    // so neither end claims to be finished while the answer is still unknown.
    const known = total > 0 || groups.status !== null;
    return {
      top: groups.startOffset > 0,
      bottom: !known || groups.rows.length < total,
    };
  }

  /**
   * The one loading message, and the first-load state.
   *
   * Three jobs, and the third is why this is not just a spinner:
   *
   * 1. A first load, where there is nothing on screen indicating anything at all.
   * 2. A pull-in at either end, which must not silently do nothing.
   * 3. **A grouping pass that has not finished.** While `status.building` is true
   *    the stored groups have not been written yet, so the view must say
   *    "grouping" and never "no similar groups found". That sentence is a claim
   *    about the library, and making it mid-pass reports a false negative for
   *    every photo in it — the user is told their library has no duplicates when
   *    the truth is that nobody has finished looking.
   */
  function updateGroupsBusy() {
    const groups = state.groups;
    const busy = $('groupsBusy');
    const building = Boolean(groups.status && groups.status.building);

    let message = '';
    if (groups.loading) {
      message = groups.loadingAt === 'top' ? 'Loading earlier groups…'
        : (groups.loadingAt === 'bottom' ? 'Loading more groups…' : 'Loading groups…');
    } else if (building) {
      message = 'Grouping your library — groups appear here as they are found…';
    }
    // An empty list with nothing loading is the genuine empty-and-finished case,
    // and it has no message here: `renderGroups` says so in the empty area, which
    // is where a reader looks for an answer rather than at a spinner over nothing.
    busy.hidden = message === '';
    $('groupsBusyText').textContent = message;
    // `is-pending` is the slow, non-urgent variant: a grouping pass is minutes of
    // work, so it reads as a steady state rather than a spinner that appears stuck.
    busy.classList.toggle('is-pending', Boolean(building) && !groups.loading);
  }

  function renderGroups() {
    const status = state.groups.status;
    const focused = state.groups.focused;
    const building = Boolean(status && status.building);
    const parts = [];
    if (focused) {
      // A group page reports its own size rather than a page of a list: "18 photos"
      // is the answer to the question that was asked, and "1 of 1 groups" would be
      // a true sentence about nothing. With no group there is no count to report,
      // so the line says nothing rather than claiming zero.
      const group = state.groups.rows[0];
      if (group) {
        const count = Number(group.memberCount) || 0;
        parts.push(`${fmt.count(count)} ${fmt.plural(count, 'photo', 'photos')}`);
      }
    }
    // Only the settled counts live here. Work still outstanding is the progress
    // line's business, and "grouping is running" is the busy row's — three places
    // claiming one fact is three places to keep in step, and only one of them is
    // the one that must never be absent when the list is empty.
    if (status) {
      if (Number(status.featurePrints) > 0) {
        parts.push(`${fmt.count(status.featurePrints)} photos compared`);
      }
      if (Number(status.facesAnalyzed) > 0) {
        parts.push(`${fmt.count(status.facesAnalyzed)} face quality reads`);
      }
    }
    $('groupsMeta').textContent = parts.join(' · ') || '—';

    // What is still outstanding, stated once and in full.
    const progress = [];
    if (status && Number(status.facesPending) > 0) {
      progress.push(`${fmt.count(status.facesPending)} photos still being checked for faces`);
    }
    if (status && status.stale) progress.push('settings changed — rebuilding');
    $('groupsProgress').textContent = progress.join(' · ');
    $('groupsProgress').hidden = progress.length === 0;

    const list = $('groupsList');
    // Prepending grows the document *above* the viewport, which throws the reader
    // backwards by exactly the height that was added — the single hardest thing to
    // get right about bidirectional scrolling. So the height is measured before the
    // rebuild and the difference is added back afterwards.
    const heightBefore = document.documentElement.scrollHeight;
    const scrollBefore = window.scrollY;
    const prepending = state.groups.loadingAt === 'top' && state.groups.rows.length > 0;

    list.replaceChildren();
    if (state.groups.rows.length === 0) {
      const empty = document.createElement('div');
      empty.className = 'groups-empty';
      // Three different facts, and only one of them is "there are none".
      //
      // While a pass is running there is no answer yet, so the message is the
      // *process*, never a conclusion: "No similar groups found" printed over a
      // half-finished pass is a false negative for every photo in the library, and
      // it is the kind of false negative that convinces a user their photos are
      // unique. `updateGroupsBusy` says the same thing in the row below the list;
      // this is the in-place copy, so the empty area is never a bare void either.
      //
      // `note` outranks both, because in focused mode it is the specific reason
      // *this* photo has no group — a different fact again.
      empty.textContent = state.groups.note || (
        building
          ? 'Grouping your library…'
          : (status && Number(status.featurePrints) === 0
            ? 'No similarity data yet. PhotoCleaner reads one FeaturePrint per photo as it scores them — run "Rescan library" to add them to photos scored before this version.'
            : groupsEmptyNote()));
      list.appendChild(empty);
    }
    let originCell = null;
    for (const group of state.groups.rows) {
      const card = buildGroup(group);
      list.appendChild(card);
      if (focused) originCell = originCell || card.querySelector('.group-cell.origin');
    }
    updateGroupsBusy();
    if (prepending) {
      // Put the reader back on the group they were looking at.
      const delta = document.documentElement.scrollHeight - heightBefore;
      if (delta > 0) window.scrollTo(0, scrollBefore + delta);
    } else {
      scrollGroupOriginIntoView(originCell);
    }
  }

  /**
   * Puts the photo the group was opened for on screen.
   *
   * `nearest` rather than `center`: in a group of fifteen near-identical frames the
   * origin is almost always within a scroll of the viewport already, and centring it
   * would move the strip for no reason. The strip scrolls sideways, so `inline` is
   * what does the work, and `block: 'nearest'` keeps the page itself still.
   */
  function scrollGroupOriginIntoView(cell) {
    if (cell) cell.scrollIntoView({ block: 'nearest', inline: 'nearest' });
  }

  /**
   * One group: its date, size, and members in the requested order.
   *
   * The member strip is a horizontal row rather than a grid because a group's whole
   * point is that it is small — fifteen near-identical frames of one shot — and the
   * comparison the user is making is between neighbours, so they should be adjacent
   * rather than wrapped.
   *
   * The ranking badge states which order is in effect. A group still being face
   * analysed says so: its Best Shot order can still change, and presenting a
   * half-ranked portrait group as settled would be a claim PhotoCleaner cannot back.
   *
   * The member the group was opened for is marked, when there is one. Two things
   * about that are deliberate. It is a *mark*, not a selection: nothing here is
   * queued for deletion, and the class is not the one the score grid uses for a
   * selected tile, so the two states cannot be read as the same one. And it does
   * not move the cell — the group stays in the order the sort control asked for,
   * because a marker that reordered the strip would be making the ranking a lie.
   */
  function buildGroup(group) {
    const card = document.createElement('section');
    card.className = 'group-card';
    card.dataset.id = group.id;

    const hidden = Number(group.hiddenMemberCount) || 0;
    const head = document.createElement('header');
    head.className = 'group-head';
    const title = document.createElement('div');
    title.className = 'group-title';
    // The count is of what this card shows, which under an album filter is the
    // album's share of the group. The number left out is a badge below rather than
    // a second number in the title: the title states the size of the thing on
    // screen, and the badge states what the album filter excluded from it.
    title.textContent = `${fmt.count(group.memberCount)} ${fmt.plural(group.memberCount, 'photo', 'photos')}`;
    const when = document.createElement('span');
    when.className = 'group-when';
    when.textContent = fmt.date(group.date);
    title.appendChild(document.createTextNode(' · '));
    title.appendChild(when);
    head.appendChild(title);

    const badges = document.createElement('div');
    badges.className = 'group-badges';
    const order = group.ranked === 'best_shot' ? 'Best Shot' : 'Aesthetics';
    const orderBadge = document.createElement('span');
    orderBadge.className = 'badge';
    orderBadge.textContent = order;
    orderBadge.title = group.ranked === 'best_shot'
      ? 'Ranked within this group by PhotoCleaner, from the aesthetics score plus face capture quality'
      : "Ranked within this group by Apple's aesthetics score";
    badges.appendChild(orderBadge);

    if (hidden > 0) {
      const albumBadge = document.createElement('span');
      albumBadge.className = 'badge muted-badge';
      albumBadge.textContent = `${fmt.count(hidden)} outside ${albumScopeLabel()}`;
      albumBadge.title = `This group has ${fmt.plural(group.memberCount + hidden, 'photo', 'photos')}. `
        + `The album filter is showing the ${fmt.count(group.memberCount)} in ${albumScopeLabel()}.`;
      badges.appendChild(albumBadge);
    }

    const faces = Number(group.faceMemberCount) || 0;
    if (faces > 0) {
      const faceBadge = document.createElement('span');
      faceBadge.className = 'badge muted-badge';
      faceBadge.textContent = `${fmt.count(faces)} with ${fmt.plural(faces, 'face', 'faces')}`;
      faceBadge.title = "Vision's face capture quality: lighting, sharpness, blur and positioning";
      badges.appendChild(faceBadge);
    }
    if (group.incomplete) {
      const pending = document.createElement('span');
      pending.className = 'badge warn-badge';
      pending.textContent = 'still analysing';
      pending.title = 'Some photos in this group are still being checked for faces, so the Best Shot order may change.';
      badges.appendChild(pending);
    }
    head.appendChild(badges);
    card.appendChild(head);

    const strip = document.createElement('div');
    strip.className = 'group-strip';
    const items = Array.isArray(group.items) ? group.items : [];
    items.forEach((row, index) => {
      strip.appendChild(buildGroupCell(group, row, index, items.length));
    });
    card.appendChild(strip);
    return card;
  }

  /**
   * One group cell: rank, frame, face quality, heart.
   *
   * Split out of `buildGroup` so the strip's own construction and the cells it
   * holds are one decision rather than two.
   */
  function buildGroupCell(group, row, index, total) {
    const cell = document.createElement('div');
    cell.className = 'group-cell';
    cell.dataset.id = row.id;
    cell.dataset.index = String(index);
    // Focusable and button-shaped, rather than a real `<button>`.
    //
    // WebKit does not move focus to a `<button>` when it is clicked, so a cell
    // built as one never holds focus after the click that selected it — and the
    // Space and Enter that previews it are delivered to whatever *is* focused.
    // The keydown below therefore never ran, and Space did nothing on a group
    // thumbnail while working on a grid tile. A `div[tabindex]` takes focus from
    // a click the way the grid's tile already does, which is what puts the cell on
    // the keyboard path at all.
    //
    // `role="button"` is what keeps it announced as one, and the keydown handler
    // below supplies the activation a real button would have done on its own.
    cell.tabIndex = 0;
    cell.setAttribute('role', 'button');
    const originId = state.groups.originId;
    const isOrigin = Boolean(originId) && row.id === originId;
    cell.title = groupMemberTitle(row, index);
    cell.setAttribute('aria-label', `Rank ${index + 1} of ${total}, ${cell.title}`
      + (isOrigin ? ', the photo you opened this group from' : ''));

    const rank = document.createElement('span');
    rank.className = 'group-rank';
    rank.textContent = String(index + 1);

    const image = document.createElement('img');
    image.className = 'group-image';
    image.loading = 'lazy';
    image.decoding = 'async';
    image.alt = '';
    // A group cell is 88 px square whatever the grid is doing, so this one asks
    // for its own rung rather than inheriting the grid's.
    image.src = thumbURL(row.id, THUMB_GROUP);
    image.addEventListener('error', () => { image.classList.add('failed'); }, { once: true });

    // No aesthetics score here. It used to sit under every frame, and it earned
    // nothing: within a group the frames are near-identical, so a signed
    // three-decimal number is a difference the reader cannot see in the picture —
    // and a number under each frame invites sorting by it, which is precisely
    // the impression-based judgement the strip exists to support. The rank
    // number above the frame still says which is first, and the score is one
    // click away in the lightbox.
    //
    // What stays is what the picture cannot tell you: the face capture quality,
    // and the heart, which is the one marker here that changes what deletion may
    // do.
    const meta = document.createElement('span');
    meta.className = 'group-meta';
    // Face capture quality is shown only where Vision found a face, so an absent
    // value is never displayed as a zero.
    if (row.faceCaptureQuality !== null && row.faceCaptureQuality !== undefined) {
      const face = document.createElement('span');
      face.className = 'group-face';
      face.textContent = `face ${Number(row.faceCaptureQuality).toFixed(2)}`;
      face.title = 'Vision face capture quality for this photo — lighting, sharpness, blur and positioning';
      meta.appendChild(face);
    }
    // The heart, and the same one the tile uses: a control, not a report. The grid
    // tile's heart sets the flag from the photo itself, and a heart that only
    // reports on one surface and sets it on the other is the sort of difference a
    // reader has to discover by trying. It is always present here — unlike the
    // tile's, which stays invisible until the pointer arrives — because a strip is
    // scanned rather than hovered, and a heart that appeared on hover would be a
    // different gesture on every frame in the same row.
    const heart = document.createElement('button');
    heart.type = 'button';
    heart.className = 'group-heart';
    attachHeartToggle(heart, row.id);
    decorateHeart(heart, row);
    meta.appendChild(heart);

    cell.appendChild(rank);
    cell.appendChild(image);
    // The heart is always in the meta row now, so this is no longer a conditional
    // line: the strip carries it whether or not Vision found a face.
    cell.appendChild(meta);
    if (isOrigin) {
      // Ring *and* label, the way the All Photos anchor does it: the ring is
      // quick to spot while scrolling the strip, and the label says what the
      // ring means so it does not rest on hue alone.
      cell.classList.add('origin');
      const tag = document.createElement('span');
      tag.className = 'group-origin-label';
      tag.textContent = 'From here';
      cell.appendChild(tag);
    }
    cell.addEventListener('click', (event) => {
      // One click selects, the same as a grid tile. A cell is a photo you are
      // judging against its neighbours, so clicking is a decision about which one
      // you are looking at, and opening it is the second step.
      onGroupCellClick(group, row, index, total, event);
    });
    cell.addEventListener('dblclick', (event) => {
      // Double click previews, matching the grid tile exactly. The `click` that
      // precedes it has already toggled the selection, which is deliberate and is
      // what a double click in the grid does too.
      event.preventDefault();
      openGroupLightbox(group, index);
    });
    cell.addEventListener('keydown', (event) => {
      if (event.target !== cell) return;
      if (event.key === 'Enter' || event.key === ' ') {
        event.preventDefault();
        togglePreview(() => groupQueueMemo(group), () => index, {
          groups: true,
          label: group.ranked === 'best_shot' ? 'Best Shot' : 'Aesthetics',
        });
        event.stopPropagation();
        return;
      }
      // ← and → walk the strip, which is what they do in every list the app owns. The
      // preview's own arrow keys are only live while the preview is open, so there
      // is nothing to shadow here. Space and Enter are the preview toggle instead,
      // the same two keys that open a tile, rather than the selection a button
      // would activate itself with.
      if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') {
        event.preventDefault();
        focusGroupCell(group, index, event.key === 'ArrowLeft' ? -1 : 1);
      }
    });
    // The same PhotoCleaner menu a grid tile gets, on the same terms. A group
    // cell is a photo the user can point at, and "Show Similar Photos" from it
    // is the doorway into the focused view of the group already on screen.
    attachGroupCellContextMenu(cell, group, index);
    return cell;
  }

  /** The group's member list, or an empty array if the card has gone. */
  const groupItems = (group) => (Array.isArray(group.items) ? group.items : []);

  /**
   * One click on a group cell, on the same terms as a grid tile: it selects, and
   * Shift-click extends a range.
   *
   * The range is over the strip in rank order, which is the order the reader is
   * looking along, and it is anchored on the last-clicked cell the same way the
   * grid anchors its own. Ranges are taken over *identifiers* rather than over
   * ranks so that a strip rebuilt mid-range cannot silently widen or narrow what
   * the click meant.
   */
  function onGroupCellClick(group, row, index, total, event) {
    const items = groupItems(group);
    // `index` is the cell's rank in the strip and is already the index into
    // `items`, so no lookup is needed — but it is asserted rather than assumed,
    // because a stale index here would select the wrong photo silently, which is
    // the one failure a selection gesture cannot recover from.
    if (items[index] !== row) return;
    if (event.shiftKey) {
      selectRangeTo(index, () => items, groupAnchor());
      return;
    }
    state.groups.anchorIndex = index;
    toggleSelection(row.id);
  }

  /** Moves focus along the strip, and stops at either end rather than wrapping. */
  function focusGroupCell(group, from, step) {
    const items = groupItems(group);
    const index = from + step;
    if (index < 0 || index >= items.length) return;
    const card = groupCard(group.id);
    const cell = card && card.querySelector(`.group-cell[data-index="${index}"]`);
    if (cell) cell.focus();
  }

  /**
   * The card for a group, found by id.
   *
   * Ids are server-generated strings, so they are compared through the attribute
   * selector rather than by string interpolation into it — an id containing a
   * quote would otherwise make this throw a SyntaxError rather than fail to find
   * a card. `CSS.escape` is the standard answer and every browser this app targets
   * has it.
   */
  function groupCard(id) {
    if (!id) return null;
    const selector = `.group-card[data-id="${CSS.escape(String(id))}"]`;
    return $('groupsList').querySelector(selector);
  }

  /**
   * Anchor accessors.
   *
   * A range needs an anchor, and the grid and the group strips are separate
   * surfaces with separate memories: a range in one strip must not be anchored on
   * a cell the reader last clicked in another. Passing the anchor in as a pair of
   * accessors is what keeps that true, rather than having `selectRangeTo` reach
   * for `state.anchorIndex` on everyone's behalf.
   */
  const gridAnchor = () => ({
    get: () => state.anchorIndex,
    set: (value) => { state.anchorIndex = value; },
  });
  const groupAnchor = () => ({
    get: () => state.groups.anchorIndex,
    set: (value) => { state.groups.anchorIndex = value; },
  });

  /**
   * Right-click on one member of a group.
   *
   * The menu is the tile menu, built by the same code, so "Show in All Photos",
   * "Show Similar Photos", favourite protection and staging cannot drift between
   * the three places a photo can be pointed at. The caller supplies only the row
   * and where to anchor it; the menu's actions all resolve the photo from there.
   *
   * Focus returns to the cell, which is focusable — unlike the lightbox's photo.
   */
  function attachGroupCellContextMenu(cell, group, index) {
    cell.addEventListener('contextmenu', (event) => {
      event.preventDefault();
      event.stopPropagation();
      const row = (Array.isArray(group.items) ? group.items : [])[index];
      if (!row) return;
      openTileMenu(cell, groupMemberRow(row), { x: event.clientX, y: event.clientY });
    });
  }

  /**
   * A group member in the shape the menu and the selection code expect.
   *
   * A group response names a photo's score `aesthetics` and carries no dimensions,
   * while everything downstream of the menu speaks in `score`/`width`/`height`.
   * Converting once here keeps that difference in one place instead of spreading
   * `row.aesthetics || row.score` through the menu.
   */
  function groupMemberRow(row) {
    return {
      id: row.id,
      score: Number(row.aesthetics),
      date: row.date,
      favorite: Boolean(row.favorite),
    };
  }

  /** Tooltip text for one group member, naming only signals that exist. */
  function groupMemberTitle(row, index) {
    const parts = [`Rank ${index + 1}`, `Aesthetics ${fmt.score(row.aesthetics)}`];
    if (row.faceCaptureQuality !== null && row.faceCaptureQuality !== undefined) {
      parts.push(`Face capture quality ${Number(row.faceCaptureQuality).toFixed(3)}`
                 + (Number(row.faceCount) > 1 ? ` (worst of ${row.faceCount} faces)` : ''));
    }
    if (row.date !== null && row.date !== undefined) parts.push(fmt.date(row.date));
    if (row.favorite) parts.push('Favorite');
    return parts.join(' · ');
  }

  /** The group member queue the lightbox walks, in the group's own order. */
  function groupQueue(group) {
    return (Array.isArray(group.items) ? group.items : []).map((row) => ({
      id: row.id,
      // The lightbox's metadata panel reads `score`, `width` and `height`. A group
      // response carries the aesthetics score but not the dimensions, so they are
      // left undefined and rendered as "—" rather than invented as zeros.
      score: Number(row.aesthetics),
      date: row.date,
      favorite: !!row.favorite,
    }));
  }

  function openGroupLightbox(group, index) {
    const queue = groupQueueMemo(group);
    if (!queue[index]) return;
    openLightbox(queue, index, group.ranked === 'best_shot' ? 'Best Shot' : 'Aesthetics',
                { groups: true });
  }

  /**
   * The lightbox queue for a group, built once per group object.
   *
   * `togglePreview` decides "is this the preview already on screen?" by comparing
   * queue *identity*, which is the only identity the preview keeps — it holds no
   * back-reference to where it was opened from. A queue rebuilt on every call
   * would therefore answer "no" every time, and the Space toggle would open the
   * same photo again instead of closing it.
   *
   * Keyed on the group object, which `state.groups.rows` holds until that group is
   * reloaded from the server. A `WeakMap` so a closed group view's objects can be
   * collected rather than pinning their queues for the life of the page.
   *
   * It has to be invalidated with the group, not merely dropped: `state.groups.rows`
   * is replaced wholesale by a refresh, so a stale entry cannot outlive its key —
   * but a *mutated* group object could, and nothing mutates one in place.
   */
  const groupQueueCache = new WeakMap();
  function groupQueueMemo(group) {
    if (!group) return [];
    let queue = groupQueueCache.get(group);
    if (!queue) {
      queue = groupQueue(group);
      groupQueueCache.set(group, queue);
    }
    return queue;
  }

  async function setGroupOrder(order) {
    if (!GROUP_ORDERS.includes(order) || state.groups.order === order) return;
    state.groups.order = order;
    syncGroupOrderChips();
    // The window is dropped rather than re-sorted: the groups already loaded were
    // fetched under the previous order, and the two sentinels would otherwise page
    // through offsets that now belong to a different sequence. A fresh window from
    // the top is the only honest answer to "show me these in the other order".
    state.groups.rows = [];
    state.groups.startOffset = 0;
    state.groups.endOffset = 0;
    await loadGroups('first');
  }

  async function rebuildGroups() {
    const { ok, payload } = await api.post('/api/groups/rebuild', {});
    if (!ok) {
      toast('Could not start a rebuild — ' + errorText(payload, 'the server refused'), 'error');
      return;
    }
    toast(payload.message || 'Rebuilding similar groups.');
    // Every stored group is about to be replaced, so the window on screen is stale
    // at both ends. Clearing it first is also what stops the two sentinels from
    // firing on the outgoing list and paging through offsets that no longer mean
    // what they meant.
    state.groups.rows = [];
    state.groups.startOffset = 0;
    state.groups.endOffset = 0;
    // The pass is detached, so poll while it runs rather than blocking on it.
    await loadGroups('first');
    scheduleGroupsPoll();
  }

  /**
   * Reloads the group list while a pass is running, then stops.
   *
   * Bounded by `state.groups.building` rather than by a timer count, so a long pass
   * is followed to the end and a short one costs a single reload. Nothing is
   * scheduled at all once the view is closed.
   */
  let groupsPollTimer = null;
  function scheduleGroupsPoll() {
    clearTimeout(groupsPollTimer);
    if (!state.groups.active) return;
    groupsPollTimer = setTimeout(async () => {
      if (!state.groups.active) return;
      // Re-reads the *status* while the pass runs, and deliberately does not grow
      // the window: the groups on screen are mid-replacement, so paging further
      // into them would fetch offsets belonging to a list that no longer exists.
      // `loadGroups` is only asked for a fresh window when there is nothing to show.
      if (state.groups.rows.length === 0) await loadGroups('first');
      else await loadGroupsStatus();
      if (state.groups.active && state.groups.status && state.groups.status.building) {
        scheduleGroupsPoll();
      }
    }, GROUPS_POLL_MS);
  }

  async function boot() {
    // Reflect the default sort in the markup before the first paint of the chips.
    document.querySelector('.chip[data-sort="score_asc"]').classList.add('active');
    // The same for the media chips, and from `state.media` rather than by marking
    // one in the markup: `selectMedia` and `adoptAppliedMedia` both write that
    // field, so the first paint has to come from the one place they agree on.
    renderMediaBar();
    wireControls();
    // One call: `updateSelectionBar` ends by repainting the Delete button, and it
    // is the only writer of that button's state.
    updateSelectionBar();
    syncRangeUI();
    renderEmptyState();
    // One status fetch for the first paint; everything after that arrives over
    // SSE, so the UI never polls.
    await refreshStatus();
    connectEvents();
    // Albums last, and never awaited by anything else: the grid must not wait on
    // a library enumeration. This request is also what starts the index pass, so
    // the chip row fills in behind the user's first scroll.
    loadAlbums().then(scheduleAlbumPoll);
  }

  boot();
})();
