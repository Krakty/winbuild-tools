# build.ps1 -- cmake-based build wrapper for winbuild.
#
# Examples:
#   pwsh C:\tools\build.ps1                                # build engine only, preset 'live'
#   pwsh C:\tools\build.ps1 -Plugin MQ2Cleric              # stage + build, preset 'live'
#   pwsh C:\tools\build.ps1 -Plugin MQ2Cleric -Preset test
#   pwsh C:\tools\build.ps1 -Plugin MQ2Cleric -CleanReconfigure
#
# Flow:
#   1. Sync engine repo (Krakty/MQ2-Krakty:test).
#   2. If -Plugin: sync plugin repo + stage source into engine plugins dir.
#   3. Submodule update.
#   4. Crashpad cache hygiene (handles the stale-debug-CRT corruption case).
#   5. cmake --preset <preset>
#   6. cmake --build build --config <Configuration>
#   7. Copy *.dll, *.pdb under build\bin\release\ matching the plugin name
#      into C:\builds\<plugin>\<UTC-stamp>\artifacts\.
#   8. Return cmake's exit code.

[CmdletBinding()]
param(
    [string]$Plugin,
    [string]$EngineRepo = 'macroquest',
    [string]$EngineUrl  = 'https://github.com/Krakty/MQ2-Krakty.git',
    [string]$EngineBranch = 'test',
    [string]$PluginUrl,
    [string]$PluginBranch = 'main',
    [ValidateSet('live','emu','test')]
    [string]$Preset = 'live',
    [ValidateSet('Release','Debug','RelWithDebInfo')]
    [string]$Configuration = 'Release',
    [switch]$CleanReconfigure,
    [switch]$SkipSync,
    [switch]$EngineOnly
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $PSCommandPath
. (Join-Path $scriptDir 'env.ps1')
. (Join-Path $scriptDir 'Repo.ps1')
. (Join-Path $scriptDir 'stage.ps1')

$env_ = Get-BuildEnv

# Identity
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmssZ')
$buildName = if ($EngineOnly -or -not $Plugin) { $EngineRepo } else { $Plugin }
$buildDir  = Join-Path $env_.BuildRoot (Join-Path $buildName $stamp)
$logFile   = Join-Path $buildDir 'build.log'
$artifactsDir = Join-Path $buildDir 'artifacts'
New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null

function Log {
    param([string]$Msg, [ConsoleColor]$Color = 'Gray')
    $ts = (Get-Date).ToString('HH:mm:ss')
    $line = "[$ts] $Msg"
    Write-Host $line -ForegroundColor $Color
    Add-Content -Path $logFile -Value $line
}

Log "=== Build $buildName preset=$Preset config=$Configuration ===" 'White'
Log "Build dir: $buildDir"

# 1. Sync engine
if (-not $SkipSync) {
    $engineInfo = Sync-Repo -Name $EngineRepo -Url $EngineUrl -Branch $EngineBranch
    Log "Engine: $($engineInfo.Name) @ $($engineInfo.Branch) $($engineInfo.Sha)" 'Cyan'
}
$engineDir = Join-Path $env_.SrcRoot $EngineRepo

# 2. Sync plugin + stage
if (-not $EngineOnly -and $Plugin) {
    if (-not $SkipSync) {
        if (-not $PluginUrl) { $PluginUrl = "https://github.com/Krakty/$Plugin.git" }
        $pluginInfo = Sync-Repo -Name $Plugin -Url $PluginUrl -Branch $PluginBranch
        Log "Plugin: $($pluginInfo.Name) @ $($pluginInfo.Branch) $($pluginInfo.Sha)" 'Cyan'
    }
    Stage-Plugin -Plugin $Plugin -EngineRepo $EngineRepo | Out-Null
}

# 3. Submodules
Log "Submodule update --init --recursive"
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
Push-Location $engineDir
try {
    & $env_.GitExe submodule update --init --recursive 2>&1 | Tee-Object -FilePath $logFile -Append | Out-Null
} finally {
    Pop-Location
    $ErrorActionPreference = $prevEAP
}

# 4. Crashpad cache hygiene -- the crashpad portfile fix only sticks if the
# binary cache and any prior vcpkg_installed are clear. See
# tools/build_mq2cf.ps1 (upstream) for the recurring trap this guards.
$crashpadRelLib = Join-Path $engineDir "build\vcpkg_installed\x64-windows-static\lib\common.lib"
if (Test-Path $crashpadRelLib) {
    $text = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($crashpadRelLib))
    if ($text -match 'DEFAULTLIB:libcmtd') {
        Log "Stale crashpad release lib with debug CRT detected -- purging build\vcpkg_installed" 'Yellow'
        Remove-Item -Recurse -Force (Join-Path $engineDir 'build\vcpkg_installed') -ErrorAction SilentlyContinue
        Remove-Item -Force (Join-Path $engineDir 'build\CMakeCache.txt') -ErrorAction SilentlyContinue
    }
}
if ($CleanReconfigure) {
    Log "CleanReconfigure: removing build\CMakeCache.txt" 'Yellow'
    Remove-Item -Force (Join-Path $engineDir 'build\CMakeCache.txt') -ErrorAction SilentlyContinue
}

# 5. Apply vcvars so cmake finds the toolset
Invoke-VcVars -Env_ $env_

# 6. Configure
# Native commands (cmake, msbuild) write to stderr for warnings -- with
# ErrorActionPreference=Stop, PowerShell wraps those in a NativeCommandError
# and aborts. Drop to Continue around external-tool calls and rely on
# $LASTEXITCODE for the actual pass/fail signal.
Log "cmake --preset $Preset" 'White'
$tCfg = Get-Date
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
Push-Location $engineDir
try {
    & cmake --preset $Preset 2>&1 | Tee-Object -FilePath $logFile -Append
    $cfgRc = $LASTEXITCODE
} finally {
    Pop-Location
    $ErrorActionPreference = $prevEAP
}
$cfgDur = [int]((Get-Date) - $tCfg).TotalSeconds
if ($cfgRc -ne 0) {
    Log "CONFIGURE FAILED rc=$cfgRc in ${cfgDur}s" 'Red'
    exit $cfgRc
}
Log "Configure OK (${cfgDur}s)" 'Green'

# 7. Build
Log "cmake --build build --config $Configuration" 'White'
$tBld = Get-Date
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
Push-Location $engineDir
try {
    & cmake --build build --config $Configuration 2>&1 | Tee-Object -FilePath $logFile -Append
    $bldRc = $LASTEXITCODE
} finally {
    Pop-Location
    $ErrorActionPreference = $prevEAP
}
$bldDur = [int]((Get-Date) - $tBld).TotalSeconds

# 8. Artifacts
$binDir = Join-Path $engineDir "build\bin\$($Configuration.ToLower())"
if (-not (Test-Path $binDir)) { $binDir = Join-Path $engineDir "build\bin\release" }
$artifactCount = 0
if (Test-Path $binDir) {
    $pattern = if ($EngineOnly -or -not $Plugin) { '*.dll','*.pdb','*.exe' } else { "$Plugin*.dll","$Plugin*.pdb" }
    foreach ($p in $pattern) {
        Get-ChildItem $binDir -Recurse -Filter $p -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item $_.FullName -Destination $artifactsDir -Force
            $artifactCount++
        }
    }
}

# 9. Summary
Log ("-" * 60)
if ($bldRc -eq 0) {
    Log "BUILD OK  $buildName  cfg=${cfgDur}s  bld=${bldDur}s  artifacts=$artifactCount" 'Green'
} else {
    Log "BUILD FAILED  $buildName  rc=$bldRc  bld=${bldDur}s" 'Red'
    # Surface the first few error lines for quick triage
    Get-Content $logFile | Select-String -Pattern 'error C\d+|error LNK\d+|FAILED|fatal error' | Select-Object -First 20 | ForEach-Object { Log "  $_" 'Red' }
}
Log "Log: $logFile"
exit $bldRc
