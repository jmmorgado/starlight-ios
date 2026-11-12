## What's new: Steam foundations

This release lays the groundwork for Steam playtime, recently played games and achievements. Those appear in the interface in the next releases.

### Steam account
- New **Settings › Steam** screen. Paste your **Steam Web API key**, created at steamcommunity.com/dev/apikey, and your **SteamID64**. A profile URL or the profile name in it works too, and Starlight converts it.
- **Connect / Save & Test** checks the account straight away and shows the account name, the number of games owned and the number played in the last two weeks.
- It warns you if your profile's **Game details** are private, because playtime and achievements come back empty otherwise.
- The key is stored only in the iPhone's **Keychain**.
- Steam data is cached on the iPhone and refreshed automatically every few hours. Refresh Now and Disconnect Steam are also on that screen.

### Games linked to Steam
- Starlight now reads each app's Vibepollo **UUID**. Steam games carry their Steam appid in it, so each game on your PC is linked to its Steam entry with no name guessing.
- Non-Steam apps, such as Desktop or emulators, simply stay unlinked.

### "Permission denied" from Vibepollo
- If this iPhone lacks the **List applications** permission on the PC, Starlight no longer shows the fake "Permission denied" app as a game. It explains how to fix it instead: Vibepollo Web UI › Client Management › this iPhone › List applications.

## Install
Download `Starlight.ipa` below and install it with [Sideloadly](https://sideloadly.io) over your current version, using the same Bundle ID.
