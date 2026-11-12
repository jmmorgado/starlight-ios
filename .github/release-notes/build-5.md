## What's new

### Pin games to the app icon
- New **Pin to App Icon** option in a game's long-press menu (and **Unpin from App Icon** to remove it).
- Pinned games appear when you long-press the Starlight icon on the Home Screen. Tapping one starts streaming that game directly.
- Up to 4 items (an iOS limit). Pinned games are listed first, followed by your PCs as before.

### Straight into the stream, no main screen
- Launching from a pinned game or a `starlight://` link now opens a full-screen **start screen** with the game's art, its name and the PC it's connecting to, then goes straight into the stream. The main screen is no longer shown on the way.
- Works from a cold start (app closed) and when the app is already running in the background.
- Faster start: the app now waits at most ~3 seconds (was ~6) for the PC to be found before connecting with its last known address.
- If the same game is already running on the PC, the stream resumes immediately. If a *different* game is running, the usual resume / quit menu is shown.

### Fixes
- Error messages now refer to Starlight instead of Moonlight.

## Install
Download `Starlight.ipa` below and install it with [Sideloadly](https://sideloadly.io) over your current version (your PCs, pairing and settings are kept if you use the same Bundle ID as before).
