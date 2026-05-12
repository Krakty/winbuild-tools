# winbuild-tools

Build/deploy tooling for the `winbuild` Windows build server.

## Layout

```
C:\
├── installers\            One-shot installers (vs_BuildTools, Git, etc.)
├── src\                   Per-repo clones (one dir per GitHub repo)
│   ├── macroquest\          The MQ engine fork
│   ├── MQ2Cleric\           Standalone plugin source (this rebuild)
│   └── ...
├── builds\                Per-build outputs, one timestamped dir per build
│   └── <repo>\<UTC-stamp>\
│       ├── build.log
│       └── artifacts\
├── tools\                 This repo, cloned onto winbuild
│   ├── env.ps1              Resolves VS/Git/SDK locations; exports paths
│   ├── Repo.ps1             git clone/pull helpers
│   ├── stage.ps1            Stages plugin source into macroquest src tree
│   ├── build.ps1            The single build entry point
│   └── deploy.ps1           Copy artifacts to a target dir (or remote)
└── deploy\                 Optional: artifact stash for downstream consumption
```

## Workflow

1. Dev on `beast` -> push to GitHub.
2. On `winbuild`, run `pwsh C:\tools\build.ps1 -Repo MQ2Cleric` (auto-syncs both
   `macroquest` and `MQ2Cleric`, stages, builds, logs).
3. Artifacts land under `C:\builds\MQ2Cleric\<stamp>\artifacts\`.

## Scripts

- **env.ps1**: returns a hashtable with `VsRoot`, `MSBuild`, `VcVars`, `SdkVer`,
  `GitExe`. Sourced by every other script.
- **Repo.ps1**: `Sync-Repo -Name X -Url Y [-Branch B]`. Idempotent.
- **stage.ps1**: `Stage-Plugin -Plugin MQ2Cleric -EngineRepo macroquest`.
  Mirrors `C:\src\MQ2Cleric\*` (excluding .git/build/docs) to
  `C:\src\macroquest\src\plugins\MQ2Cleric\` via robocopy.
- **build.ps1**: orchestrator. Takes a plugin name, syncs both repos, stages,
  builds, captures log+artifacts.
- **deploy.ps1**: copies built dll/pdb to a target dir.

All scripts are PowerShell 7 (`pwsh`) and idempotent.
