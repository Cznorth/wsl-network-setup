# Run elevated (deploy-server.sh does this). Idempotent: installs/enables Windows OpenSSH Server,
# listening on 127.0.0.1:22 only, key-only, only -User allowed; no firewall rule (reverse tunnel use only).
# NOTE: keep this file ASCII-only; Windows PowerShell 5.1 reads BOM-less files as ANSI.
param([Parameter(Mandatory)][string]$User, [string]$Log = "$env:TEMP\wslproxy-enable-sshd.log")
$ErrorActionPreference = 'Stop'
Start-Transcript -Path $Log -Force | Out-Null
try {
    if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
        Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null
    }
    $dir = "$env:ProgramData\ssh"
    New-Item -ItemType Directory -Force $dir | Out-Null
    Set-Service sshd -StartupType Automatic
    if (-not (Test-Path "$dir\ssh_host_ed25519_key")) { Start-Service sshd; Start-Sleep 2; Stop-Service sshd }
    @"
ListenAddress 127.0.0.1
Port 22
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
AllowUsers $User
AllowTcpForwarding no
Subsystem sftp sftp-server.exe
"@ | Set-Content -Encoding ascii "$dir\sshd_config"
    Restart-Service sshd
    Get-Service sshd | Format-List Status, StartType
} finally { Stop-Transcript | Out-Null }
