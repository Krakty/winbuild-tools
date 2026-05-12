# stage.ps1 -- copies plugin source from C:\src\<Plugin> into the macroquest
# engine source tree at C:\src\<Engine>\src\plugins\<Plugin>\.
#
# Uses robocopy /MIR with excludes for .git, build outputs, docs.

. $PSScriptRoot\env.ps1

function Stage-Plugin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$Plugin,
        [string]$EngineRepo = 'macroquest',
        [string]$SrcRoot
    )

    $env_ = Get-BuildEnv
    if (-not $SrcRoot) { $SrcRoot = $env_.SrcRoot }

    $pluginSrc = Join-Path $SrcRoot $Plugin
    $engineDir = Join-Path $SrcRoot $EngineRepo
    $pluginsDir = Join-Path $engineDir 'src\plugins'
    $dest = Join-Path $pluginsDir $Plugin

    if (-not (Test-Path $pluginSrc)) { throw "Plugin source missing: $pluginSrc (run Sync-Repo first)" }
    if (-not (Test-Path $pluginsDir)) { throw "Engine plugins dir missing: $pluginsDir (engine not cloned/built?)" }

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
