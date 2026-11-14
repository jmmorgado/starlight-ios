## Fix: old Moonlight PC picker over Home

- When Starlight couldn't reach the PC (offline, connection failed or interrupted, pairing cancelled), the old Moonlight PC picker ("jmmorgado-PC" with a warning icon and "Add Host Manually") was drawn on top of Home. It covered the top of the screen, so the PC button couldn't be tapped.
- That picker is never shown any more while Home is in use. Home stays as it is and marks the PC as offline (orange dot), and the PC menu offers Wake, Refresh Games and Add PC by Address.
