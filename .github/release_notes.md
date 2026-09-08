## Download & install

### Android

Pick the APK for your device and allow "Install unknown apps" when prompted:

| File | Best for |
|---|---|
| `AlnPlay-<version>-arm64-v8a.apk` | 64-bit ARM phones (most modern Android devices) |
| `AlnPlay-<version>-armeabi-v7a.apk` | 32-bit ARM phones (older devices) |
| `AlnPlay-<version>-x86_64.apk` | 64-bit Intel/AMD devices (emulators, some tablets) |
| `AlnPlay-<version>-universal.apk` | **Universal** — all architectures in one file, installs everywhere |

Not sure which to pick? Grab the **Universal** APK.

### iOS / iPadOS (sideload)

The `AlnPlay-<version>-unsigned.ipa` in this release is **unsigned** — Apple only allows app installation through the App Store / TestFlight, so the IPA must be signed with your own (free) Apple ID. It's quick:

1. Install **SideStore** or **AltStore** on your iPhone/iPad ([sidestore.io](https://sidestore.io) / [altstore.io](https://altstore.io)).
2. Download `AlnPlay-<version>-unsigned.ipa` from this release.
3. Open SideStore/AltStore → **+** → select `AlnPlay-<version>-unsigned.ipa`. It signs it with your Apple ID and installs.
4. The signature lasts **7 days**; SideStore/AltStore **auto-refresh** it in the background over WiFi — a weekly open is all that's needed.

Notes:
- A free Apple ID can keep ~3 sideloaded apps active per device.
- First-time setup of SideStore/AltStore needs a computer (or a second Apple device).
- No automatic updates — re-download the newest IPA from this page when a new version is published.

## Versioning

App version follows **semver**, bumped per release (current release: **1.0.1**).

## Playing videos from your NAS / SMB share

AlnPlay plays NAS files through the Files app's built-in SMB support and "Open with"

- **iPhone/iPad:** Files → **⋯ → Connect to Server** → enter `smb://<address>` → browse to a video → long-press → **Share → Open in "AlnPlay"**. Prefer a folder? Bookmark it once: home **+** → **Add folder to library** → your NAS folder.
- **Android:** CX Explorer → **Open with → AlnPlay** (streams over CX's local HTTP proxy).

Full walkthrough: **[SMB / NAS playback tutorial](docs/tutorials/play-smb-nas-videos.md)**.
