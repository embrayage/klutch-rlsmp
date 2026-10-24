# Development

## Repository structure

- `src/client/`: bridge Lua, vehicle guard, English phone UI and app manifest.
- `src/server/`: account coordinator and durable marketplace coordinator.
- `build.py`: checked upstream patches and local package generation.
- `tests/`: behavioral checks against actual native source and isolated multiplayer harnesses.
- `tools/`: local installation, reference preparation and maintenance helpers.

Runtime paths keep the existing `rlsmpTeamx` names to preserve compatibility with established server profiles, extension names and exchange receipts. The GitHub repository is named `klutch-rlsmp`.

## Local build

Use Python 3.11 or newer. The builder uses only the Python standard library.

```powershell
python .uild.py --source "PATH_TO_RLS_ZIP"
```

Generated files are in `build/`, which Git ignores. A new build generates an independent server ID when there is no existing build configuration.

For the checked local hotfix installer, first copy an existing server's RLSMP `config.json` into `build/Resources/Server/rlsmpTeamx/config.json`, then rebuild. The installer verifies that build and installed identities match. Manual deployment of the portable update preserves the installed configuration without this step.

## Full regression suite

Local requirements:

- Original RLS Career Overhaul 2.8.0 ZIP.
- Installed BeamNG.drive 0.40 with its Lua and Vue source files.
- Installed BeamMP client archive, normally `mods/multiplayer/BeamMP.zip` in the BeamNG user folder.
- BeamMP Server's 64-bit `lua53.dll`.
- Python 3.11+ and Node.js.

Prepare ignored local fixtures from your own archives:

```powershell
python .	oolsprepare-references.py --rls "PATH_TO_RLS_ZIP" --beammp "PATH_TO_BEAMMP_CLIENT_ZIP"
$env:BEAMNG_DIR = "PATH_TO_BEAMNG_INSTALLATION"
$env:BEAMMP_LUA_DLL = "PATH_TO_BEAMMP_SERVER_LUA53_DLL"
python .	ests
un_tests.py
```

The fixture metadata must match the upstream ZIP used by the build. Reference preparation writes only under this checkout's ignored `reference/` directory. Archive inputs are read only.

The full suite checks 25 Lua files, real game/RLS exports, independent profiles, native route loading, stored fleet restoration, explicit vehicle replacement, traffic scheduling, audio gates, finite network state, native auction locks, garage reservations, solo imports and durable two-client exchanges.

Automated checks cannot validate physical sound output, actual CEF rendering or multiplayer physics. Use two signed-in clients for in-game verification.

## Source checks without the game

```powershell
python .	oolscheck-source.py
```

On systems with Lua 5.3's compiler:

```sh
find src -name '*.lua' -exec luac5.3 -p {} \;
```

The public workflow runs source checks and Lua syntax checks. It does not download or publish RLS, game files, player data or a prebuilt client ZIP.

## Maintenance tools

`install.ps1` handles a local first installation and backs up replaced files. `install-client-hotfix.ps1` updates an established matching server and backs up the old client/plugin. Both operate on an explicitly supplied server directory.

`repair-stored-cars.py` is a targeted maintenance tool, with a dry run by default. Read its CLI help and review the selected inventory IDs before applying a repair. It requires BeamNG to be closed.
