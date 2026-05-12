# deploy.ps1 -- copy build artifacts to a target.
#
# Examples:
#   pwsh C:\tools\deploy.ps1 -Plugin MQ2Cleric -Target \\eqserver\plugins
#   pwsh C:\tools\deploy.ps1 -Plugin MQ2Cleric -Target C:\deploy\latest

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string]$Plugin,
    [Parameter(Mandatory=$true)] [string]$Target,
    [string]$Build = 'latest',     # 'latest' or a UTC stamp directory name
    [string[]]$Include = @('*.dll','*.pdb')
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $PSCommandPath
. (Join-Path $scriptDir 'env.ps1')
$env_ = Get-BuildEnv

$pluginBuilds = Join-Path $env_.BuildRoot $Plugin
if (-not (Test-Path $pluginBuilds)) { throw "No builds for $Plugin under $($env_.BuildRoot)" }

if ($Build -eq 'latest') {
    $buildDir = Get-ChildItem $pluginBuilds -Directory |
        Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
} else {
    $buildDir = Join-Path $pluginBuilds $Build
}
$artifactsDir = Join-Path $buildDir 'artifacts'
if (-not (Test-Path $artifactsDir)) { throw "No artifacts at $artifactsDir" }

if (-not (Test-Path $Target)) { New-Item -ItemType Directory -Path $Target -Force | Out-Null }

$files = Get-ChildItem $artifactsDir -File -Include $Include -ErrorAction SilentlyContinue
if (-not $files) { throw "No files matching $($Include -join ', ') in $artifactsDir" }

foreach ($f in $files) {
    Copy-Item $f.FullName -Destination $Target -Force
    Write-Host "  $($f.Name) -> $Target"
}
Write-Host "Deployed $($files.Count) file(s) from $buildDir to $Target" -ForegroundColor Green
