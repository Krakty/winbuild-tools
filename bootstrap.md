# winbuild bootstrap

How to provision a fresh Windows host as a clone of `winbuild` from scratch.
This is what was done on 2026-05-11; capture it here so the rebuild is
reproducible without trawling chat logs.

## Prerequisites

- A Windows Server 2022 (or 11) VM with ~60 GB disk, 4+ vCPU, 8+ GB RAM.
- Local Administrator account, network reachability from `beast`.
- A static IP on VLAN 500 (or whichever VLAN is wired).
- DNS forward/reverse records added in FreeIPA.

## One-shot steps

### 1. SSH server (run on the new host, via Proxmox console or RDP)

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
New-NetFirewallRule -Name OpenSSH-Server-In-TCP -DisplayName 'OpenSSH Server' `
    -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
```

Drop beast's `~/.ssh/id_rsa.pub` into
`C:\ProgramData\ssh\administrators_authorized_keys` (UTF-8 no-BOM, LF endings).
ACL: inheritance:r, then grant `*S-1-5-32-544:F` and `*S-1-5-18:F`.

### 2. Switch SSH default shell to cmd.exe

The default OpenSSH shell is PS5.1, which corrupts scp/sftp and mishandles
stdin piping. Also kill any `ForceCommand powershell.exe` line in
`C:\ProgramData\ssh\sshd_config`.

```powershell
New-ItemProperty -Path HKLM:\SOFTWARE\OpenSSH -Name DefaultShell `
    -Value 'C:\Windows\System32\cmd.exe' -PropertyType String -Force
Restart-Service sshd
```

### 3. SSH config on beast

```
Host winbuild winbuild.romulous.lan
    HostName winbuild.romulous.lan
    User administrator
    IdentityFile ~/.ssh/id_rsa
```

### 4. PowerShell 7

```powershell
$url = (Invoke-RestMethod 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest').assets |
    Where-Object name -like '*win-x64.msi' | Select-Object -First 1 -ExpandProperty browser_download_url
Invoke-WebRequest $url -OutFile C:\installers\PowerShell.msi
msiexec /i C:\installers\PowerShell.msi /quiet ADD_PATH=1 REGISTER_MANIFEST=1 ENABLE_PSREMOTING=1
```

### 5. Disk extend (if VM disk grew at Proxmox layer)

```powershell
reagentc /disable
Remove-Partition -DiskNumber 0 -PartitionNumber <Recovery> -Confirm:$false
Update-Disk -Number 0
Resize-Partition -DriveLetter C -Size (Get-PartitionSupportedSize -DriveLetter C).SizeMax
```

### 6. Install build prerequisites as SYSTEM (UAC bypass for non-interactive)

Direct `Start-Process` of the VS bootstrapper from an SSH session exits
silently because it cannot elevate. Run via `schtasks` as SYSTEM:

```powershell
# Drop installers
Copy-Item .\vs_BuildTools.exe C:\installers\
Copy-Item .\Git-Setup.exe   C:\installers\

# Register a "never-trigger" scheduled task per installer, then Start-ScheduledTask.
$action = New-ScheduledTaskAction -Execute 'C:\installers\vs_BuildTools.exe' `
    -Argument '--quiet --wait --norestart --nocache --installPath C:\BuildTools `
              --add Microsoft.VisualStudio.Workload.VCTools `
              --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
              --add Microsoft.VisualStudio.Component.Windows11SDK.22621 `
              --add Microsoft.VisualStudio.Component.VC.ATL `
              --add Microsoft.VisualStudio.Component.VC.CMake.Project `
              --includeRecommended'
$trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddYears(10)
$principal = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2)
Register-ScheduledTask -TaskName VSBuildToolsInstall -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings
Start-ScheduledTask -TaskName VSBuildToolsInstall
```

Do the same for Git (`/VERYSILENT /NORESTART /NOCANCEL /SP- /SUPPRESSMSGBOXES`).

### 7. Git auth (beast-parity)

Copy beast's `~/.git-credentials` to `C:\Users\administrator\.git-credentials`
and set helper:

```powershell
git config --global credential.helper store
[Environment]::SetEnvironmentVariable('GIT_TERMINAL_PROMPT','0','Machine')
```

### 8. Layout

```powershell
mkdir C:\installers, C:\src, C:\builds, C:\deploy, C:\tools
```

### 9. Clone tools repo

Once `winbuild-tools` is pushed to GitHub:

```powershell
git clone https://github.com/Krakty/winbuild-tools.git C:\tools
```

### 10. First build (smoke test)

```powershell
pwsh C:\tools\build.ps1 -EngineOnly -Preset live -Configuration Release
```

Expect ~45-60 min on first run (vcpkg builds protobuf + crashpad + etc.).
Subsequent runs are ~5-10 min once vcpkg cache is warm.

### 11. Windows Updates

After the first build proves the toolchain works, install pending updates
(some reboots required):

```powershell
Install-Module PSWindowsUpdate -Scope AllUsers -Force -AllowClobber
Get-WindowsUpdate -MicrosoftUpdate -AcceptAll -Install -AutoReboot
```
