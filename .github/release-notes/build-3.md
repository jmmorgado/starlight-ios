**First release of Starlight**, a fork of [Moonlight for iOS](https://github.com/moonlight-stream/moonlight-ios) (GPLv3), built to stream games from a PC running Sunshine / Vibepollo.

Apart from the changes below, the app behaves exactly like the original Moonlight.

## What's new

### Direct shortcuts to streaming apps
- New URL scheme to launch a specific app or game straight into a stream:
  ```
  starlight://launch?host=<PC>&app=<app>
  ```
  - `host` (or `pc`): the PC's UUID or its name as shown in the app.
  - `app` (or `game`): the app ID on the host or its exact name.
- Works from the **Shortcuts** app ("Open URLs" action), so it can be used on the Home Screen, in widgets or with Siri.
- **Copy Shortcut Link**: long-press a game to copy its ready-made link.
- When opened from a link, the app waits up to ~6 seconds for the PC to come online, then starts the stream. If another app is already running on the PC, the usual resume / quit menu is shown.
- Clear error messages when the PC isn't paired or the app isn't found.

### Other changes
- App renamed to **Starlight** (Home Screen name and `starlight://` URL scheme).
- GitHub Actions workflow that builds an unsigned `.ipa` and publishes it as a release on every change.

## Install
1. Download `Starlight.ipa` below.
2. Install it with [Sideloadly](https://sideloadly.io) (Windows or macOS) using your Apple ID. In *Advanced options*, set a custom Bundle ID if the official Moonlight app is also installed.
3. On the iPhone, trust your Apple ID in Settings → General → VPN & Device Management and enable Developer Mode if asked.

With a free Apple ID the app expires after 7 days; reinstall the same `.ipa` to refresh it (your data is kept).

## Credits
Based on [Moonlight](https://moonlight-stream.org) by the Moonlight Game Streaming Project, licensed under the GNU GPL v3.
