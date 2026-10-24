# Publish klutch-rlsmp

The intended repository name is **klutch-rlsmp**, with **public** visibility.

The local checkout is initialized on `main` and its project files are staged. GitHub publication requires access to the owner's GitHub account. Credentials are not stored in this project.

When using a connected GitHub integration, create the repository under the connected account with this exact name and public visibility, then push the prepared sources.

Alternatively, with Git and GitHub CLI installed locally:

```powershell
gh auth login
powershell -NoProfile -ExecutionPolicy Bypass -File .	oolspublish-github.ps1
```

The helper uses the currently signed-in personal GitHub account, creates the initial commit when needed and publishes `OWNER/klutch-rlsmp`. It refuses an existing remote or repository so that it cannot overwrite unrelated work. It uses the account's GitHub noreply address if no local Git email is configured.

Only source, tests, documentation and project tooling are staged. Do not upload `build/`, `reference/`, server configuration, journals, saves or the original RLS archive.
