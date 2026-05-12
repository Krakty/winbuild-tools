# Repo.ps1 -- git clone/pull helpers.

. $PSScriptRoot\env.ps1

function Sync-Repo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$Name,
        [Parameter(Mandatory=$true)] [string]$Url,
        [string]$Branch,
        [string]$SrcRoot
    )

    $env_ = Get-BuildEnv
    if (-not $env_.GitExe) { throw "git not installed" }
    if (-not $SrcRoot) { $SrcRoot = $env_.SrcRoot }
    if (-not (Test-Path $SrcRoot)) { New-Item -ItemType Directory -Path $SrcRoot | Out-Null }

    $repoDir = Join-Path $SrcRoot $Name
    if (Test-Path (Join-Path $repoDir '.git')) {
        Write-Host "[Sync-Repo] $Name : fetch+pull" -ForegroundColor Cyan
        Push-Location $repoDir
        try {
            & $env_.GitExe fetch --prune
            if ($LASTEXITCODE -ne 0) { throw "git fetch failed" }
            if ($Branch) {
                & $env_.GitExe checkout $Branch
                if ($LASTEXITCODE -ne 0) { throw "git checkout $Branch failed" }
            }
            & $env_.GitExe pull --ff-only
            if ($LASTEXITCODE -ne 0) { throw "git pull failed" }
        } finally { Pop-Location }
    } else {
        Write-Host "[Sync-Repo] $Name : clone" -ForegroundColor Cyan
        $cloneArgs = @('clone', $Url, $repoDir)
        if ($Branch) { $cloneArgs += @('--branch', $Branch) }
        & $env_.GitExe @cloneArgs
        if ($LASTEXITCODE -ne 0) { throw "git clone $Url failed" }
    }

    # Return the resolved HEAD for logging
    Push-Location $repoDir
    try {
        $sha = (& $env_.GitExe rev-parse --short HEAD).Trim()
        $branchName = (& $env_.GitExe rev-parse --abbrev-ref HEAD).Trim()
    } finally { Pop-Location }
    return @{ Name = $Name; Path = $repoDir; Sha = $sha; Branch = $branchName }
}
