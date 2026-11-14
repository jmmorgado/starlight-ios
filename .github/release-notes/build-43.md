## Artwork: Steam first, SteamGridDB as fallback

- **New order for every image of every game**, installed or not: your pick in Edit Artwork, then Steam's official artwork (games with a Steam appid), then SteamGridDB, by appid or by name for games that aren't on Steam. The fallback works image by image, so a game can use Steam's background and SteamGridDB's logo.
- **Steam games get artwork without a SteamGridDB key.** The key is only needed for games that aren't on Steam, images Steam doesn't have, icons and Edit Artwork.
- **SteamGridDB matches Steam games by appid**, so they get the right edition instead of the first search result. Picking a game in Edit Artwork switches that game to SteamGridDB.
- **Edit Artwork on every game**, including Library games that aren't on the PC (••• menu, long press, Options on the controller).
- Library games that aren't on the PC download their artwork as they appear on screen.
- All artwork is downloaded again once. Your manual picks are kept.

## New app identity

- **Own Bundle ID (`com.jmmorgado.starlight`).** Starlight now installs alongside the official Moonlight instead of replacing it. iOS treats it as a new app: pair the PC and paste the SteamGridDB and Steam keys again (once).
- Settings → About shows the real version (0.43.0).
- The SteamGridDB key is now stored in the Keychain, like the Steam key.

## Performance and cleanup

- Steam lookups, artwork checks and the image cache no longer slow down Home and Library with big libraries.
- The controller is only polled while one is connected, and keeps working while scrolling.
- The hidden Moonlight grid isn't built under Home any more.
- Code split into smaller files, unused code removed, README and usage guide (SHORTCUTS.md) updated.
