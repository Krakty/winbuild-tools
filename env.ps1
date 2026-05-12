# env.ps1 -- resolves build-environment locations on winbuild.
# Returns a hashtable callers consume. Throws on missing critical pieces.
#
# Usage:
#   . C:\tools\env.ps1
#   $env_ = Get-BuildEnv
#   & $env_.MSBuild ...

function Get-BuildEnv {
    [CmdletBinding()]
    param(
        [string]$VsInstallPath = 'C:\BuildTools'
    )

    if (-not (Test-Path $VsInstallPath)) {
        throw "VS Build Tools not found at $VsInstallPath. Install with vs_BuildTools.exe --installPath $VsInstallPath ..."
    }

    $vcvars = Join-Path $VsInstallPath 'VC\Auxiliary\Build\vcvars64.bat'
    if (-not (Test-Path $vcvars)) {
        throw "vcvars64.bat missing under $VsInstallPath (expected VC tools workload)."
    }

    # MSBuild lives at MSBuild\Current\Bin\MSBuild.exe regardless of edition.
    $msbuild = Join-Path $VsInstallPath 'MSBuild\Current\Bin\MSBuild.exe'
    if (-not (Test-Path $msbuild)) {
        $msbuild = (Get-ChildItem -Recurse -Path (Join-Path $VsInstallPath 'MSBuild') -Filter MSBuild.exe -ErrorAction SilentlyContinue |
                   Where-Object { $_.FullName -match '\\Bin\\MSBuild\.exe$' } |
                   Select-Object -First 1 -ExpandProperty FullName)
    }
    if (-not $msbuild -or -not (Test-Path $msbuild)) {
        throw "MSBuild.exe not located under $VsInstallPath\MSBuild."
    }

    $git = (Get-Command git -ErrorAction SilentlyContinue).Source
    if (-not $git) {
        $git = 'C:\Program Files\Git\cmd\git.exe'
        if (-not (Test-Path $git)) { $git = $null }
    }

    return @{
        VsRoot      = $VsInstallPath
        VcVars      = $vcvars
        MSBuild     = $msbuild
        GitExe      = $git
        SrcRoot     = 'C:\src'
        BuildRoot   = 'C:\builds'
        ToolsRoot   = 'C:\tools'
        InstallerRoot = 'C:\installers'
    }
}

# Apply vcvars64 once per session and cache the resulting environment.
# Avoids the cost of re-running vcvars (it takes ~1s).
function Invoke-VcVars {
    param([hashtable]$Env_)
    if ($script:_VcVarsApplied) { return }
    $bat = $Env_.VcVars
    $tmp = [IO.Path]::GetTempFileName()
    try {
        cmd /c "`"$bat`" >NUL 2>&1 && set" > $tmp
        Get-Content $tmp | ForEach-Object {
            if ($_ -match '^([^=]+)=(.*)$') {
                Set-Item -Path "Env:$($Matches[1])" -Value $Matches[2]
            }
        }
        $script:_VcVarsApplied = $true
    } finally {
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
}
