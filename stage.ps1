# stage.ps1 -- copies plugin source from C:\src\<Plugin> into the macroquest
# engine source tree so the cmake build picks it up.
#
# Layout choice -- macroquest has two plugin locations:
#
#   src/plugins/<name>/   In-tree plugins, listed explicitly in MQ_PLUGIN_SUBDIRS
#                         in the root CMakeLists.txt. Example: src/plugins/MQ2CF.
#                         Adding a new plugin here requires editing the root
#                         CMakeLists.txt.
#
#   plugins/<name>/       Auto-detected by detect_custom_plugins() (cmake/plugins.cmake)
#                         when MQ_BUILD_CUSTOM_PLUGINS=ON, which the live/test
#                         presets enable. No CMakeLists.txt edit needed.
#
# By default stage.ps1 targets the root plugins/ dir so out-of-tree plugins
# (MQ2Cleric, etc.) drop in without touching the engine's CMakeLists.txt.
# Use -InTree to target src/plugins/ instead (rare; only for plugins that
# are also listed in MQ_PLUGIN_SUBDIRS).
#
# Uses robocopy /MIR with excludes for .git, build outputs, docs.

. $PSScriptRoot\env.ps1

function Stage-Plugin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$Plugin,
        [string]$EngineRepo = 'macroquest',
        [string]$SrcRoot,
        [switch]$InTree
    )

    $env_ = Get-BuildEnv
    if (-not $SrcRoot) { $SrcRoot = $env_.SrcRoot }

    $pluginSrc = Join-Path $SrcRoot $Plugin
    $engineDir = Join-Path $SrcRoot $EngineRepo
    $pluginsDir = if ($InTree) {
        Join-Path $engineDir 'src\plugins'
    } else {
        Join-Path $engineDir 'plugins'
    }
    $dest = Join-Path $pluginsDir $Plugin

    if (-not (Test-Path $pluginSrc)) { throw "Plugin source missing: $pluginSrc (run Sync-Repo first)" }
    if (-not (Test-Path $pluginsDir)) {
        New-Item -ItemType Directory -Path $pluginsDir -Force | Out-Null
    }

    Write-Host "[Stage-Plugin] $Plugin -> $dest" -ForegroundColor Cyan
    $excludeDirs  = @('.git','.github','build','out','.vs','docs','x64','Debug','Release')
    $excludeFiles = @('*.user','*.suo','*.log')
    $rcArgs = @($pluginSrc, $dest, '/MIR', '/NFL', '/NDL', '/NJH', '/NP', '/R:1', '/W:1')
    foreach ($d in $excludeDirs) { $rcArgs += @('/XD', (Join-Path $pluginSrc $d)) }
    foreach ($f in $excludeFiles) { $rcArgs += @('/XF', $f) }
    & robocopy @rcArgs | Out-Null
    # robocopy exit codes 0-7 are success-ish; 8+ are errors
    $rc = $LASTEXITCODE
    if ($rc -ge 8) { throw "robocopy failed (exit=$rc)" }

    $copied = (Get-ChildItem $dest -File -Recurse -ErrorAction SilentlyContinue | Measure-Object).Count
    Write-Host "[Stage-Plugin] $copied files in $dest" -ForegroundColor Green
    return $dest
}
