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
#   6. cmake --build build --config <Configuration> --parallel
#   7. Copy *.dll, *.pdb under build\bin\release\ matching the plugin name
#      into C:\builds\<plugin>\<UTC-stamp>\artifacts\.
#   8. Return cmake's exit code.
#
# Logs:
#   build.log    -- script-emitted lines (UTF-8, no BOM)
#   console.log  -- raw cmake/msbuild output (whatever encoding the tools choose)
#   Split into two files so my Log() and Tee-Object don't race on the same
#   handle and so build.log stays trivially greppable.

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
    [int]$Parallel = 0,                # 0 => use cmake's default (= NUMBER_OF_PROCESSORS)
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
$buildName    = if ($EngineOnly -or -not $Plugin) { $EngineRepo } else { $Plugin }
$buildDir     = Join-Path $env_.BuildRoot (Join-Path $buildName $stamp)
$logFile      = Join-Path $buildDir 'build.log'
$consoleLog   = Join-Path $buildDir 'console.log'
$artifactsDir = Join-Path $buildDir 'artifacts'
New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null

# Log writer: open-write-close per call so no persistent file handle.
# UTF-8 no BOM via System.IO.File.AppendAllText with a no-BOM encoding instance.
$script:_LogEnc = [System.Text.UTF8Encoding]::new($false)
function Log {
    param([string]$Msg, [ConsoleColor]$Color = 'Gray')
    $ts = (Get-Date).ToString('HH:mm:ss')
    $line = "[$ts] $Msg"
    Write-Host $line -ForegroundColor $Color
    [System.IO.File]::AppendAllText($logFile, $line + "`r`n", $script:_LogEnc)
}

# Redirect a native-command pipeline to console.log (Tee-Object on PS5.1
# writes UTF-16; on pwsh 7 it defaults to UTF-8. Either is consistent within
# a single run and stays out of build.log's way.)
function Capture-Native {
    param([scriptblock]$Block)
    & $Block 2>&1 | Tee-Object -FilePath $consoleLog -Append
}

Log "=== Build $buildName preset=$Preset config=$Configuration ===" 'White'
Log "Build dir: $buildDir"
Log "Logs: build.log (script) + console.log (tool output)"

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
    Capture-Native { & $env_.GitExe submodule update --init --recursive } | Out-Null
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
    Capture-Native { & cmake --preset $Preset } | Out-Null
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
# Splat-through-scriptblock is unreliable across PS5.1/pwsh7 (the `@var`
# splat operator binds to local scope, and Capture-Native's scriptblock
# wraps in a different scope). Inline the call so the splat sees the
# right scope.
$parallelMsg = if ($Parallel -gt 0) { "--parallel $Parallel" } else { '--parallel' }
Log "cmake --build build --config $Configuration $parallelMsg" 'White'
$tBld = Get-Date
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
Push-Location $engineDir
try {
    if ($Parallel -gt 0) {
        & cmake --build build --config $Configuration --parallel $Parallel 2>&1 | Tee-Object -FilePath $consoleLog -Append | Out-Null
    } else {
        & cmake --build build --config $Configuration --parallel 2>&1 | Tee-Object -FilePath $consoleLog -Append | Out-Null
    }
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
    # Surface the first few error lines for quick triage. console.log is
    # where the cmake/msbuild output lives; check both encodings.
    if (Test-Path $consoleLog) {
        $bytes = [IO.File]::ReadAllBytes($consoleLog)
        # Heuristic: if first 2 bytes look like a UTF-16 LE BOM (FF FE) or a
        # bunch of low bytes interleaved with 00, decode as Unicode.
        $enc = if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
            [Text.Encoding]::Unicode
        } elseif ($bytes.Length -ge 2 -and $bytes[1] -eq 0x00) {
            [Text.Encoding]::Unicode
        } else {
            [Text.Encoding]::UTF8
        }
        $txt = $enc.GetString($bytes)
        ($txt -split "`r?`n") |
            Select-String -Pattern 'error C\d+|error LNK\d+|fatal error|^FAILED' |
            Select-Object -First 20 |
            ForEach-Object { Log "  $($_.Line)" 'Red' }
    }
}
Log "Log: $logFile"
Log "Tool output: $consoleLog"
exit $bldRc
