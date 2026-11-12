## What's new

### Game artwork from SteamGridDB
- Starlight can now download proper artwork for every game on your PC from [SteamGridDB](https://www.steamgriddb.com): **cover**, **wide background (hero)**, **logo** and **square icon**.
- New **Game Artwork** button (image icon) in the top bar to enter your free SteamGridDB API key. The key is stored only on your device, never in the app's code.
  - **Save Key & Download** fetches artwork for games that don't have it yet.
  - **Re-download All Artwork** refreshes everything.
  - **Remove Key & Artwork** deletes the key and the cached images.
- Once a key is set, new games are fetched automatically whenever Starlight reads a PC's app list. Artwork is cached on the device and shared between PCs that have the same game.
- Entries that aren't games (Desktop, Steam Big Picture, Remote Input/Monitor, Playnite) are skipped to avoid wrong matches.

### Where the artwork shows up
- **Game grid:** SteamGridDB covers replace the PC's box art (the PC's art is still used as a fallback).
- **Start screen:** the game's hero image fills the background behind the cover.
- **Save Icon to Photos:** now uses SteamGridDB's square icon (on a black background) instead of cropping the cover.
- **Shortcuts app:** the Start Game picker shows the icon (or cover) next to each game.

### New app icon
- Starlight has its own gold star icon.

## Setup
1. Sign in at steamgriddb.com, open **Preferences → API** and generate a key.
2. In Starlight, tap the **Game Artwork** button and paste the key.

## Install
Download `Starlight.ipa` below and install it with [Sideloadly](https://sideloadly.io) over your current version, using the same Bundle ID.
