# Implementation index

## Code map

| Concern | Files |
| --- | --- |
| Dock / responsive details | `lib/widgets/liquid_glass_dock.dart`, `shaders/liquid_glass.frag`, `lib/app.dart`, `lib/screens/unified_title_details_screen.dart` |
| Source Add / root-depth editor | `lib/screens/home_screen.dart`, `lib/library/widgets/scan_depth_setting.dart`, `lib/services/library_folders.dart` |
| Traversal / stable metadata | `lib/library/scanner/library_scanner.dart`, `lib/library/metadata/library_metadata_resolver.dart`, `lib/library/repository/library_repository.dart`, `lib/services/tmdb_client.dart` |
| STRM parsing / playback refresh | `lib/library/source/strm_file.dart`, `lib/library/source/library_source_adapters.dart`, `lib/services/strm_playback.dart`, `lib/services/file_browser.dart`, native FileBrowser/WebDAVClient |
| Quota / native reservations | `lib/services/cache_quota_manager.dart`, native CacheCleaner, thumbnail/danmaku/temporary-subtitle writers |
| Update checks | `lib/services/update_service.dart`, `lib/widgets/update_settings_tile.dart`, native `dreamplayer/app_info` |

## Verification on September 9, 2026

- WSL Ubuntu 26.04, Flutter 3.44.7 / Dart 3.12.2, JDK 17.
- Full Flutter suite: **565 tests passed**.
- `dart analyze lib test`: **No issues found**.
- Android release APK successfully built locally; no physical device was
  connected to adb. No device install, HDR measurement or visual claim is made.
- iOS native code was inspected but not compiled locally (Windows/WSL host).
  Repository workflows are manual/tag-triggered, not push CI. This delivery
  does not create a tag or publish a GitHub Release.

## Device follow-up

- Android/iPad: drag lens across all three tabs, change theme/text size,
  rotate, show/hide search keyboard, verify Add button and safe-area alignment.
- iPad: verify bookmark-provider remount and relaunch. STRM text reads now use
  `folderbookmark:<id>/<relative path>` against the re-resolved bookmark root.
- Play local and WebDAV STRM twice with the target URL changed between opens;
  check continuing progress, subtitles and next episode, no target URL in
  serialized history, no source Authorization forwarded to target.
- Quota pressure while playing/PiP: retain active subtitles, refuse writes that
  exceed capacity, evict deferred files after acknowledged backend disposal.
- Keep Media3 hybrid-composition HDR/DV and AetherEngine playback regression
  checks on the user's actual devices.

## Deliberate boundaries

- External STRM support is local/SAF/bookmarks and WebDAV, not cloud account
  integration or a new SMB/FTP STRM backend.
- STRM reduces scan-time traffic; it does **not** guarantee a cloud provider
  will never throttle, challenge or suspend an account. Playback still requests
  the target stream.
- Cache limit covers managed regenerable disk files, not app binaries,
  persisted library/history, user media or RAM. OS-owned and unknown native
  engine caches are deliberately outside destructive cleanup.
