# Starlight

**Starlight** is a game streaming client for iPhone and iPad, built on [Moonlight for iOS](https://github.com/moonlight-stream/moonlight-ios). It streams games from a PC running [Vibepollo](https://github.com/Nonary/Vibepollo) or [Sunshine](https://github.com/LizardByte/Sunshine), and wraps them in a console-style, native iOS 26 interface with Liquid Glass, game artwork and your Steam stats.

Streaming itself is Moonlight's: same video, audio, input and pairing. Starlight adds everything around it.

[![Latest release](https://img.shields.io/github/v/release/jmmorgado/starlight-ios?label=latest%20build)](https://github.com/jmmorgado/starlight-ios/releases/latest)

## Features

### Home, Library and Search
- **Home:** the featured game with full-screen artwork, **Play** (or **Resume** and **Quit** when it's already running), then **Continue Playing** and **Ready to Play** rows. Pinned games always come first.
- **Library:** your whole collection, meaning every Steam game you own plus everything on the PC, merged by Steam appid. Games on the PC carry a **Ready to Play** badge. Filter by All / Ready to Play / Not Installed and sort by Name, Recently Played or Most Played.
- **Search** across the whole collection.
- Native iOS 26 tab bar, navigation bar and menus, with the system Liquid Glass animations. The top right capsule holds the PC button (with its online/offline/unpaired status), clock, controller, network and battery.

### Game page
- Opens with the native zoom transition.
- **Steam playtime:** total hours, last two weeks and last played date.
- **Achievements:** progress bar and the full list with icons, unlock dates and rarity. Rare ones (under 10% of players) are highlighted in gold, and hidden ones stay hidden until unlocked.

### Artwork
- Covers, backgrounds, logos and icons from [SteamGridDB](https://www.steamgriddb.com), downloaded automatically for new games.
- **Edit Artwork** to fix a wrong match and pick your preferred background, cover and logo. Your choices survive re-downloads.
- Games that aren't installed use Steam's official artwork.

### Straight into a game
- **Pin** up to 4 games to the app icon's long-press menu. They launch straight into the stream with a loading screen showing the game's art.
- **Start Game** action for Shortcuts, Siri and Spotlight, with the game list read from the PC.
- `starlight://launch?host=<PC>&app=<game>` deep links. **Copy Shortcut Link** builds them for you.
- **Save Icon to Photos** to give a home screen shortcut the game's icon.
- **Wake-on-LAN:** pinned games, links and Shortcuts wake the PC automatically when it's off and wait for it to come online. **Wake PC** is also in the PC menu.

### Controller
- Full controller navigation of the interface: D-pad / left stick to move, **A / ✕** opens a game page, **R2** plays, **Options** opens the game menu, **L1 / R1** switch tabs, **Y / △** search, **X / □** PC.
- In the stream, iOS 26 reserves the Home button for Apple's Games app, so Starlight uses **Start + Select** (Options + Share, Menu + View): tap both to send **Guide** to the PC, hold both for a second to open the stream menu.

### Stream menu
- Swipe from the left edge (or Start + Select hold) to open a Liquid Glass panel: back to game, on-screen keyboard with PC keys, stats, disconnect and quit.

## Requirements
- iPhone or iPad on **iOS 26** for the full Liquid Glass design. Earlier versions fall back to materials.
- A PC running **Vibepollo** (recommended) or **Sunshine**.
- Optional: a SteamGridDB API key for artwork, and a Steam Web API key for playtime, achievements and the full library.

## Install

There's no App Store build. Each push to the `starlight` branch builds an unsigned `.ipa` with GitHub Actions and publishes it as a [release](https://github.com/jmmorgado/starlight-ios/releases).

1. Download `Starlight.ipa` from the [latest release](https://github.com/jmmorgado/starlight-ios/releases/latest).
2. Install it with [Sideloadly](https://sideloadly.io) (Windows or macOS) using your Apple ID. Starlight has its own Bundle ID (`com.jmmorgado.starlight`), so it installs alongside the official Moonlight.
3. On the iPhone, trust your Apple ID in **Settings › General › VPN & Device Management** and enable **Developer Mode** if asked.

With a free Apple ID the app expires after 7 days. Reinstall the same `.ipa` over it (your data stays) or use Sideloadly's auto refresh. To update, install a newer `.ipa` with the same Bundle ID.

## Setup
1. **Pair your PC:** open Starlight, pick the PC and enter the PIN in the Vibepollo / Sunshine web UI.
2. **Let Starlight see your games:** in the Vibepollo web UI, go to **Client Management**, open this iPhone and enable **List applications**. Without it, Starlight shows a notice instead of your games.
3. **Artwork:** on steamgriddb.com, sign in and generate a key under **Preferences › API**, then paste it in **Settings › Game Artwork**.
4. **Steam:** create a key at [steamcommunity.com/dev/apikey](https://steamcommunity.com/dev/apikey) and paste it in **Settings › Steam** with your SteamID64 or profile URL. Your profile's **Game details** must be public for playtime and achievements.

Both API keys are stored only in the device's Keychain.

A step-by-step guide to pinning, Shortcuts, links and fixing artwork is in [SHORTCUTS.md](SHORTCUTS.md).

## Building

### Without a Mac (GitHub Actions)
[`.github/workflows/build-ipa.yml`](.github/workflows/build-ipa.yml) builds the app on a macOS 26 runner on every push to `starlight` (or manually from **Actions › Build unsigned IPA › Run workflow**) and publishes a release:
- Tag `v0.<N>.0` and title **Starlight build N**, where N is the workflow run number.
- Notes come from `.github/release-notes/build-<N>.md` when that file exists, or from the commit message otherwise.
- Commits with `[skip ci]` in the message don't build.
- Pushes to any other branch run [`build-test-ipa.yml`](.github/workflows/build-test-ipa.yml): same `.ipa`, kept as a workflow artifact for 14 days instead of a release.

### With Xcode
1. `git clone --recursive -b starlight https://github.com/jmmorgado/starlight-ios.git`
   (if you cloned without `--recursive`, run `git submodule update --init --recursive`)
2. Open `Moonlight.xcodeproj` and select the **Moonlight** target (it builds Starlight).
3. Under **Signing & Capabilities**, choose your team. With a free Apple ID you may need to change the **Bundle Identifier** to something unique.
4. Select your iPhone and run.

## Repository layout
| Path | What's there |
|---|---|
| `Limelight/Home/` | The Starlight SwiftUI interface: Home, Library, Search, game page, settings |
| `Limelight/Intents/` | Start Game App Intent for Shortcuts, Siri and Spotlight |
| `Limelight/Stream/`, `Limelight/Input/`, `Limelight/ViewControllers/` | Moonlight streaming and input, plus the Starlight stream menu and controller shortcuts |
| `moonlight-common/` | Moonlight's streaming core (submodule) |
| `.github/release-notes/` | Hand-written release notes, one file per build |
| `tools/` | Maintenance scripts, such as release retagging |

## Roadmap
- iPad-optimised layout
- Apple TV version

## Credits and license
Starlight is a fork of [Moonlight for iOS/tvOS](https://github.com/moonlight-stream/moonlight-ios) by the Moonlight team, and is distributed under the same **GNU GPL v3** license. See [LICENSE.txt](LICENSE.txt). It is not affiliated with Moonlight, NVIDIA, Valve or SteamGridDB.
