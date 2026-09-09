# AlnPlay 1.1.0: glass navigation, bounded library scanning, cache and updates

## Scope

Implement the approved September 9 plan on the existing Flutter UI/native player
architecture. No Baidu, Quark or Ali cloud account integration, token backend,
cloud STRM generation, installer, release tag, or playback-engine replacement.

## Implementation

- Dock: separate search; draggable selected lens, cached icon/text-only atlas,
  local fragment shader refraction, reduced-motion/render-backend fallback.
  Never capture the page or HDR platform view. Hide Dock while IME is open.
- Sources: put Add in the top app bar, not underneath the floating Dock.
- Details: full-width iPad layout with shared content insets (20 phone / 32
  tablet plus safe area); retain episode centering and bounded modal sheets.
- Library: breadth-first traversal; root depth 0, configurable maximum 1–20
  (default 6). Include files at the boundary but do not enqueue deeper folders.
  Depth truncation, unreadable directories and invalid STRM are partial scans;
  never prune prior records on partial/error/cancel. Manual overrides use
  revisions to reject stale automatic metadata results.
- Matching: preserve manual/server identity, prefer explicit filename evidence,
  then fill missing show/season from nearest meaningful ancestors. Ignore
  quality/container folders. Do not treat an unknown season as specials (0).
  Do not restore the retired home “needs organizing” section.
- External STRM: local/SAF/bookmarks and WebDAV; bounded UTF-8 read (64 KiB),
  BOM/comments/blank lines allowed, exactly one HTTP(S) target. Reject other
  schemes, nested STRM and multiple targets. Scanning never requests video
  targets. Re-read on playback and preserve the STRM's stable identity;
  signed target URLs and source credentials must not enter persisted history
  or be forwarded to a different target host.
- Cache: 1/2/5/10/50 GB/unlimited, default 5 GB; GB = 1024^3 bytes. LRU only
  for regenerable danmaku, artwork and temporary subtitles. Serialize writes,
  reserve replacement bytes including temp files, coordinate Android native
  subtitle reservations, protect active playback files, defer their eviction
  until backend disposal. Library/index/history/manual bindings/user videos,
  STRM originals and persistent subtitle downloads are excluded.
- Updates: public AlnPlay latest GitHub release; installed native version,
  stable SemVer, daily automatic checks with per-version notification dedupe,
  manual check, ETag/304, total timeout/body cap, server cooldown, validated
  repository tag URL. Show release notes/date; open browser, not an installer.
  iOS continues using the user's IPA sideload tooling.

## Core flow

```text
scan(root):
  queue = [(root, depth=0, ancestors=[])]
  while queue:
    directory = dequeue()
    list directory with bounded timeout
    enqueue children only if depth < root.maxScanDepth
    read STRM text only; never GET its target during scanning
    resolve(metadata, filename, ancestors, captured override revision)
    persist incremental batches
  prune missing old records only after a complete successful traversal

play(strm):
  read original small file again -> validate single HTTP(S) target
  open target without inheriting source-server credentials
  save progress against original source identity, excluding target URL

cache.write(bytes):
  serialize -> evict oldest unleased entries -> reserve native budget
  write temporary file -> atomic rename -> release reservation
```

## Verification

Final command results and remaining device checks are recorded in
`implementation-index.md`. Physical Android/iPad liquid refraction, rotation,
IME, active playback/cache pressure and HDR regression remain device checks;
Flutter widget tests cannot certify native optical output or HDR passthrough.
