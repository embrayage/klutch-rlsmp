# Klutch RLSMP 0.8.1-alpha

RLS Career Overhaul 2.8.0 final release / BeamNG 0.40 / BeamMP Server 3.9.3 bridge. Each account uses its own local career profiles for this server. Players share the map and three synchronized civilian AI vehicles per active career.

All custom RLSMP player-facing text is English: Player Exchange, server-career labels, import validation, startup notifications, transaction errors and traffic notices. Original RLS/game localization and player-created names are preserved.

## RLS 2.8.0 final release compatibility

The local builder starts from the upstream final release; the original archive is obtained separately. Its native profile validation, failed-load UI handling and runtime retry behavior are retained. MP save names remain stable. Solo imports prioritize sequenced commits over legacy slots and recognize all four native autosave slots; cars being prepared for an NPC auction cannot be published on the player marketplace, and reserved player listings cannot be consigned to an NPC auction. Existing server identity, local career namespaces and marketplace journals remain compatible. Pending marketplace purchases reserve garage capacity while native admission for cars returning to their confirmed home and space-exempt vehicles is preserved.

## Player Exchange

Open the RLS phone and choose **Player Exchange**. The app is preinstalled and placed on existing phone home screens through RLS's native app catalog.

- **Market**: browse every public car listing, search by car/model/seller, and sort by price or date. The asking price is taken from the server's listing. Review and confirm the purchase. You need sufficient wallet funds and free space in an owned garage.
- **Sell**: store and repair an owned car, select it and enter an asking price. Review and confirm to publish it. Your car is reserved and cannot be spawned, modified, auctioned or sold elsewhere until the listing is withdrawn or sold. There is no listing expiry, and disconnecting does not remove it. **My listings** provides the withdrawal action on the owning career.
- **Transfer**: choose a connected player and an amount. They review and accept the transfer in **Offers**. Funds come from the RLS wallet; bank accounts remain in the Bank app. Direct transfer offers expire after three minutes and are removed on disconnect.
- **Offers**: accept or decline incoming transfers, or cancel pending outgoing ones. Previously issued private car offers remain compatible, but new car sales use the public marketplace.

Listings stay public across server restarts. Sellers may be offline: publication first saves the car reservation on their PC, then the server stores its portable configuration, installed parts, condition, mileage and maintenance. Only then can anyone buy it. The asking price is debited and the car delivered stored into the buyer's garage. The seller's career removes its reserved car and receives the money when the seller next loads the same career. The seller's insurance is not transferred.

One listing cannot be bought twice. While a purchase is preparing, the listing is reserved. A refused, timed-out or interrupted purchase returns the buyer's reservation and leaves the listing available after recovery. A committed purchase is never turned into an abort. Completed buyers can continue using the marketplace without waiting for an offline seller. Multiple distinct cars from one offline seller can be purchased.

Stay stopped and connected while saving a publication, withdrawal, purchase or transfer. RLS may defer a save during movement or another activity. After reconnecting, load the same career to finish pending work. The server retries until final saved receipts arrive. A failed save is never acknowledged as complete.

Limits: 10 pending/active listings per account and 200 on the server. Prices and transfers range from 0.01 to 100,000,000 with at most two decimal places. Self-purchases and self-transfers are refused. Unlimited-money careers cannot trade.

## Install or update a remote server

The portable **RLSMP-0.8.1-update.zip** contains both required sides:

```
Resources/Client/rls_career_overhaul_rlsmp_teamx.zip
Resources/Server/rlsmpTeamx/main.lua
Resources/Server/rlsmpTeamx/trade.lua
Resources/Server/rlsmpTeamx/tradeWire.lua
```

1. Stop the remote server and back up its current client ZIP, server scripts, `config.json` and `trades.jsonl` if present.
2. Extract the update into the server root, replacing those four files. Keep the existing `Resources/Server/rlsmpTeamx/config.json` and `trades.jsonl`. They are deliberately absent from the update package.
3. Start the server. Fully close BeamNG on every PC, then reconnect so both Lua and the phone UI load the new client.

Updating only the client ZIP does not install the marketplace coordinator. The update requires the server folder too. The server ID in `config.json` must remain unchanged; it selects the namespace of each player's local careers. New clients are required to publish or buy marketplace listings. Old transaction records remain readable by 0.8.1.

For this local server, the checked installer is:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\install-client-hotfix.ps1 -ServerRoot "PATH_TO_BEAMMP_SERVER" -IncludeServer
```

It backs up replaced files under `RLSMP-backups`, validates hashes, preserves configuration options, and installs the server coordinator after its dependencies. It does not connect to a remote server.

## Career storage and safety

Server careers live in the player's BeamNG user folder:

```
settings/rlsmpTeamx/saves/<serverId>/beammp_<account>_<profile>/
```

The legacy `beammp_<account>` profile remains recognized. The native RLS selector provides multiple account-owned profiles and imports compatible RLS/BeamNG single-player saves by copying them into a new server career. Importing never moves or changes the original solo save. The server map is RLS West Coast. Unsupported versions/maps require opening and saving with the current single-player RLS first.

Keep the append-only `Resources/Server/rlsmpTeamx/trades.jsonl` together with the server configuration. It contains marketplace listings, durable vehicle snapshots and transaction decisions. Local `career/rlsmpTrades.json` receipts are captured in the same RLS snapshot as wallet and inventory changes. An unreadable/truncated journal or a failed write suspends exchanges. Never delete these journals or restore just one old career to undo a completed trade.

Withdraw listings and finish transactions before duplicating or importing a career that contains reservations. Completed receipts can be reset for a copied profile; pending receipts stay bound to the original career and server. Local progression remains editable by the player: this is interruption recovery, not an anti-cheat economy or protection against deliberate save rollback.

## Existing compatibility behavior

- No Auth+ dependency. A signed-in BeamMP account supplies the permanent profile identity.
- Only the patched RLS archive is distributed. Installers move conflicting RLS providers into hash-checked backups rather than deleting them.
- The career selector reopens after BeamMP's world-ready navigation and retries lost routes. The RLS route tree stays native. Only the career picker gets a visible loading/retry presentation after 300 ms, within BeamNG's 3-second commit budget. That presentation uses the game's actual route-readiness composable because the picker declares handlesOwnReady. Late imports render inside the same mounted presentation; failed imports offer retry. Other route/host/phone loading and native navigation guards remain unchanged.
- Explicit parts-shop vehicle replacements retain the original vehicle ID. Foreign vehicles, stale objects and ambient traffic are excluded from inventory management.
- The saved live-fleet list takes precedence over stale garage positions, preventing stored cars from reappearing on join.
- Global audio is restored once after RLS confirms activation of the selected career. Recovery waits for the loading manager, native loading requests and black-screen fade to finish, the play route to be active, physics to be unpaused, and the local player's vehicle Lua to acknowledge readiness. It then waits one stable second and clears the native loading/pause audio flags and UI audio blur. This works while walking as well as driving. The 0.6.2 vehicle-source rebuild is removed. Volumes, sound banks, vehicle state and simulation speed are preserved. The bridge's `getStatus().audio` and `rlsmpTeamx.audio` log messages expose progress. Profile changes and disconnects cancel pending recovery; later missions, menus and pauses keep their normal audio behavior.
- Three simple-traffic cars are owned by each active career client. Native RLS automatic traffic is disabled. Leaving a career removes only that client's AI group.
- The network guard filters non-finite transforms and prediction during pause/zero-duration frames. It does not change the clock or time of day.
- RLS requests saves after activation, every 60 seconds and on exit, respecting its own save gates.

## Build and verify

```powershell
python .\build.py --source "PATH_TO_RLS_ZIP"
python .\tests\run_tests.py
```

The builder validates 17 original RLS patch targets: 13 Lua and four UI files. It bundles nine GE bridge modules, one vehicle module, the phone manifest/component and three server scripts. The original RLS ZIP and base game files are not changed.

Tests cover native APIs and vehicle locks, career/profile isolation, imports, startup retries, traffic, explicit vehicle replacement, stored fleet restoration, pause/network guards, the actual game's icon catalog, Vue compilation and UI actions. Multi-client marketplace tests cover durable publication, no expiry, disconnect/restart persistence, offline sellers, simultaneous buyers, exact parts/condition transfer, one-time seller credit, ownership/profile checks, interrupted withdrawals, insufficient funds/space, failed saves and legacy transaction recovery.

Actual CEF rendering, physical audio output, physics and two-player network behavior still require in-game validation. On a fresh connection, select a career and check ambient sound, engine/exhaust, horn and tires before using a garage or mission. Also check a walking career and verify a later mission loading screen and pause still work normally. Audio recovery logs use `rlsmpTeamx.audio`. Start with a low-value transfer and one stored car; verify both wallets/inventories after reconnecting. Then test publication, seller disconnect, purchase while the seller is offline, seller return and withdrawal. Check `beamng.log` for `rlsmpTeamx` and `Server.log` for `[RLSMP]`.
