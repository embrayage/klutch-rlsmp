# Contributing

Describe the trigger, expected behavior and observed behavior when reporting a problem. Include the bridge version and BeamNG/BeamMP/RLS versions. Remove authentication keys, account identifiers, endpoints and personal save contents from shared logs.

Keep custom player-facing text in English. Preserve server IDs and per-account local profile isolation. Treat marketplace wallet/inventory effects and their receipts as one durable save operation. Keep native RLS behavior outside an authorized MP session.

Run the source checks for documentation or tooling changes. Run the full native-source regression suite for Lua, UI, patch-anchor or upstream compatibility changes. Document in-game checks and any limitations in your pull request.

Use small pull requests that describe the concrete failure and resulting behavior. Do not commit generated mods, reference sources, server configuration, journals or player saves.
