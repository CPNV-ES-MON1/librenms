# ==============================================================================
# setup-win-librenms.ps1 (PRODUCTION FIXED VERSION)
# ==============================================================================

param(
    [Parameter(Mandatory=$true)]
    [string]$LibreNMSIP,

    [Parameter(Mandatory=$true)]
    [string]$LibreNMSUser,

    [Parameter(Mandatory=$true)]
    [string]$MySQLPassword,

    [string]$SSHKeyPath = "$env:USERPROFILE\.ssh\id_ed25519_librenms",

    [string]$WindowsIP = (Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.InterfaceAlias -notlike "*Loopback*" } |
        Select-Object -First 1 -ExpandProperty IPAddress),

    [string]$SNMPCommunity = "public"
)

# ==============================================================================
# SSH helper (NON INTERACTIF SAFE)
# ==============================================================================

function Invoke-LibreNMSSSH {
    param([string]$Command)

    return & ssh -i $SSHKeyPath `
        -o StrictHostKeyChecking=no `
        -o BatchMode=yes `
        "$LibreNMSUser@$LibreNMSIP" `
        "sudo -n $Command" 2>&1
}

function Write-Step { param($m) Write-Host "`n===> $m" -ForegroundColor Cyan }
function Write-OK { param($m) Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Fail { param($m) Write-Host "  [FAIL] $m" -ForegroundColor Red; exit 1 }

# ==============================================================================
# OPENSSH WINDOWS
# ==============================================================================

Write-Step "Configuration OpenSSH Server"

Start-Service sshd -ErrorAction SilentlyContinue
Set-Service sshd -StartupType Automatic
Write-OK "OpenSSH actif"

# ==============================================================================
# POWERSHELL SSH SHELL
# ==============================================================================

Write-Step "Configuration PowerShell SSH shell"

$psPath = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"

New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" `
    -Name DefaultShell `
    -Value $psPath `
    -PropertyType String `
    -Force | Out-Null

Write-OK "Shell configuré"

# ==============================================================================
# SSH KEY SETUP ON LIBRENMS
# ==============================================================================

Write-Step "Gestion clé SSH LibreNMS"

$sshKeyRemote = "/var/lib/librenms/.ssh/librenms_restart"

Invoke-LibreNMSSSH "mkdir -p /var/lib/librenms/.ssh"
Invoke-LibreNMSSSH "chown -R librenms:librenms /var/lib/librenms/.ssh"
Invoke-LibreNMSSSH "chmod 700 /var/lib/librenms/.ssh"

# génération clé (non bloquante si existe)
Invoke-LibreNMSSSH "sudo -n -u librenms ssh-keygen -t ed25519 -f $sshKeyRemote -N '' -q || true" | Out-Null

Write-OK "Clé SSH OK"

# ==============================================================================
# PUBLIC KEY RETRIEVAL (FIX IMPORTANT)
# ==============================================================================

Write-Step "Récupération clé publique"

$pubKey = Invoke-LibreNMSSSH "cat /var/lib/librenms/.ssh/librenms_restart.pub"

if (-not $pubKey -or $pubKey -notmatch "ssh-ed25519") {
    Write-Fail "Impossible de récupérer la clé publique"
}

Write-OK "Clé récupérée"

# ==============================================================================
# WINDOWS AUTHORIZED KEYS
# ==============================================================================

Write-Step "authorized_keys Windows"

New-Item -ItemType Directory -Force -Path "C:\ProgramData\ssh" | Out-Null

Set-Content `
    -Path "C:\ProgramData\ssh\administrators_authorized_keys" `
    -Value $pubKey -Force

icacls "C:\ProgramData\ssh\administrators_authorized_keys" `
    /inheritance:r /grant "SYSTEM:(F)" /grant "Administrators:(F)" | Out-Null

Write-OK "authorized_keys OK"

# ==============================================================================
# NTP
# ==============================================================================

Write-Step "NTP"

Invoke-LibreNMSSSH "w32tm /config /reliable:YES"
Invoke-LibreNMSSSH "Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpServer' -Name Enabled -Value 1"
Invoke-LibreNMSSSH "Restart-Service W32Time"

Write-OK "NTP OK"

# ==============================================================================
# FIREWALL
# ==============================================================================

Write-Step "Firewall"

Invoke-LibreNMSSSH "if (-not (Get-NetFirewallRule -DisplayName 'NTP-IN' -ErrorAction SilentlyContinue)) { New-NetFirewallRule -DisplayName 'NTP-IN' -Direction Inbound -Protocol UDP -LocalPort 123 -Action Allow }"

Write-OK "Firewall OK"

# ==============================================================================
# SSH TEST
# ==============================================================================

Write-Step "Test SSH"

Start-Sleep 3

$test = Invoke-LibreNMSSSH "Get-Service W32Time"

if ($test -match "Running") {
    Write-OK "SSH OK"
} else {
    Write-Warn "Test SSH à vérifier"
}

# ==============================================================================
# FIN
# ==============================================================================

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "SETUP TERMINÉ" -ForegroundColor Green
Write-Host "============================================"
Write-Host "LibreNMS: $LibreNMSIP"
Write-Host "Windows : $WindowsIP"
Write-Host "User    : $LibreNMSUser"
Write-Host "============================================"
