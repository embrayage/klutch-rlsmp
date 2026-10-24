# Changelog

## 0.8.1-alpha

- Fix slow career-selector imports exceeding BeamNG's route commit deadline.
- Show a visible profile loading/retry screen and acknowledge native mount readiness.
- Preserve the native route tree, other lazy routes and stable mounted component identities.
- Add regression checks using the installed game's real transition manager and route-readiness code.

## 0.8.0-alpha

- Update the bridge to the RLS Career Overhaul 2.8.0 final release.
- Retain the native release route loader and remove the previous MP route override.
- Follow native save ordering across sequenced commits, legacy slots and four rotating autosaves.
- Preserve returning-car and space-exempt garage admission while reserving pending marketplace purchases.
- Preserve independent profiles, public marketplace recovery, three AI per active player and global startup audio recovery.

The initial repository import also makes local test paths configurable and adds reference preparation, documentation and public source checks.
