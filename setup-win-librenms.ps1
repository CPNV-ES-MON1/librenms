# ==============================================================================
# setup-win-client.ps1
# Configuration initiale du client Windows pour LibreNMS
# A executer UNE SEULE FOIS directement sur le client Windows
#
# Usage:
#   .\setup-win-client.ps1 -LibreNMSIP 10.229.37.249 -SNMPCommunity public
# ==============================================================================

param(
    [Parameter(Mandatory=$false)]
    [string]$LibreNMSIP = "10.0.2.10",

    [Parameter(Mandatory=$false)]
    [string]$SNMPCommunity = "public"
)

# ==============================================================================
# Fonctions utilitaires
# ==============================================================================
function Write-Step { param([string]$msg) Write-Host "`n===> $msg" -ForegroundColor Cyan }
function Write-OK   { param([string]$msg) Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Warn { param([string]$msg) Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function Write-Fail { param([string]$msg) Write-Host "  [FAIL] $msg" -ForegroundColor Red; exit 1 }

# ==============================================================================
# ETAPE 1 : Installer et configurer SNMP
# ==============================================================================
Write-Step "Installation et configuration de SNMP"

$snmp = Get-WindowsFeature -Name SNMP-Service -ErrorAction SilentlyContinue
if ($snmp -and $snmp.Installed) {
    Write-OK "SNMP deja installe"
} else {
    Install-WindowsFeature -Name SNMP-Service -IncludeManagementTools | Out-Null
    Write-OK "SNMP installe"
}

# Configurer la communaute SNMP
$snmpKey = "HKLM:\SYSTEM\CurrentControlSet\Services\SNMP\Parameters\ValidCommunities"
if (-not (Test-Path $snmpKey)) {
    New-Item -Path $snmpKey -Force | Out-Null
}
New-ItemProperty -Path $snmpKey -Name $SNMPCommunity -Value 4 -PropertyType DWORD -Force | Out-Null

# Autoriser uniquement le serveur LibreNMS
$permKey = "HKLM:\SYSTEM\CurrentControlSet\Services\SNMP\Parameters\PermittedManagers"
if (-not (Test-Path $permKey)) {
    New-Item -Path $permKey -Force | Out-Null
}
New-ItemProperty -Path $permKey -Name "1" -Value $LibreNMSIP -PropertyType String -Force | Out-Null

# Demarrer et activer SNMP
Set-Service -Name SNMP -StartupType Automatic
Restart-Service SNMP
Write-OK "SNMP configure avec la communaute '$SNMPCommunity' et autorise pour $LibreNMSIP"

# ==============================================================================
# ETAPE 2 : Autoriser SNMP dans le firewall
# ==============================================================================
Write-Step "Configuration du firewall (port 161 UDP)"

$snmpFw = Get-NetFirewallRule -DisplayName "SNMP-IN" -ErrorAction SilentlyContinue
if (-not $snmpFw) {
    New-NetFirewallRule -DisplayName "SNMP-IN" `
        -Direction Inbound `
        -Protocol UDP `
        -LocalPort 161 `
        -Action Allow | Out-Null
    Write-OK "Regle firewall SNMP-IN creee"
} else {
    Write-OK "Regle firewall SNMP-IN existe deja"
}

# ==============================================================================
# ETAPE 3 : Installer l agent Check_MK
# ==============================================================================
Write-Step "Installation de l agent Check_MK"

if (-not (Test-Path "C:\Temp")) {
    New-Item -ItemType Directory -Force -Path "C:\Temp" | Out-Null
}

if (-not (Get-Service "Check_MK" -ErrorAction SilentlyContinue)) {
    Set-Location C:\Temp
    curl.exe -L -o check_mk_agent.msi https://github.com/tribe29/checkmk/raw/v1.2.6b5/agents/windows/check_mk_agent.msi
    msiexec /i check_mk_agent.msi /qn
    Start-Sleep -Seconds 5
    Write-OK "Agent Check_MK installe"
} else {
    Write-OK "Agent Check_MK deja installe"
}

$cmkFw = Get-NetFirewallRule -DisplayName "CheckMK Agent" -ErrorAction SilentlyContinue
if (-not $cmkFw) {
    New-NetFirewallRule -DisplayName "CheckMK Agent" -Direction Inbound -Protocol TCP -LocalPort 6556 -Action Allow | Out-Null
    Write-OK "Regle firewall CheckMK Agent creee (port 6556)"
} else {
    Write-OK "Regle firewall CheckMK Agent existe deja"
}

# ==============================================================================
# ETAPE 4 : Installer et demarrer OpenSSH Server
# ==============================================================================
Write-Step "Installation et activation de OpenSSH Server"

$sshCap = Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*'
if ($sshCap.State -ne 'Installed') {
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
    Write-OK "OpenSSH Server installe"
} else {
    Write-OK "OpenSSH Server deja installe"
}

Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
Write-OK "OpenSSH Server demarre et active"

# ==============================================================================
# ETAPE 5 : Configurer PowerShell comme shell SSH par defaut
# ==============================================================================
Write-Step "Configuration de PowerShell comme shell SSH par defaut"

New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" `
    -Name DefaultShell `
    -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -PropertyType String `
    -Force | Out-Null
Write-OK "PowerShell configure comme shell SSH par defaut"

# ==============================================================================
# ETAPE 6 : Activer W32Time comme serveur NTP
# ==============================================================================
Write-Step "Configuration de W32Time comme serveur NTP"

w32tm /config /reliable:YES 2>&1 | Out-Null
Set-ItemProperty `
    -Path "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpServer" `
    -Name "Enabled" -Value 1
Restart-Service W32Time
Write-OK "W32Time configure comme serveur NTP"

# ==============================================================================
# ETAPE 7 : Autoriser NTP dans le firewall
# ==============================================================================
Write-Step "Configuration du firewall (port 123 UDP)"

$ntpFw = Get-NetFirewallRule -DisplayName "NTP-IN" -ErrorAction SilentlyContinue
if (-not $ntpFw) {
    New-NetFirewallRule -DisplayName "NTP-IN" `
        -Direction Inbound `
        -Protocol UDP `
        -LocalPort 123 `
        -Action Allow | Out-Null
    Write-OK "Regle firewall NTP-IN creee"
} else {
    Write-OK "Regle firewall NTP-IN existe deja"
}

# ==============================================================================
# ETAPE 8 : Autoriser le ping (ICMP) depuis le serveur LibreNMS
# ==============================================================================
Write-Step "Configuration du firewall (ICMP ping)"

$icmpFw = Get-NetFirewallRule -DisplayName "ICMP-IN" -ErrorAction SilentlyContinue
if (-not $icmpFw) {
    New-NetFirewallRule -DisplayName "ICMP-IN" `
        -Direction Inbound `
        -Protocol ICMPv4 `
        -Action Allow | Out-Null
    Write-OK "Regle firewall ICMP-IN creee"
} else {
    Write-OK "Regle firewall ICMP-IN existe deja"
}

# ==============================================================================
# ETAPE 9 : Configurer sysLocation SNMP
# ==============================================================================
Write-Step "Configuration de la location SNMP (sysLocation)"

Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\SNMP\Parameters\RFC1156Agent" `
    -Name "sysLocation" -Value "Datacenter" -Force
Restart-Service SNMP
Write-OK "sysLocation configure a 'Datacenter'"

# ==============================================================================
# RESUME
# ==============================================================================
Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  Configuration client terminee !" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  SNMP communaute : $SNMPCommunity"
Write-Host "  SNMP autorise   : $LibreNMSIP"
Write-Host "  OpenSSH         : actif (port 22)"
Write-Host "  W32Time NTP     : actif (port 123)"
Write-Host "  ICMP ping       : autorise"
Write-Host ""
Write-Host "  Prochaine etape : executer setup-win-librenms.sh"
Write-Host "  sur le serveur LibreNMS avec :"
Write-Host "  sudo bash setup-win-librenms.sh --win-ip <IP_DE_CE_WINDOWS> --win-password <PASS> --mysql-password <PASS>"
Write-Host "============================================`n" -ForegroundColor Cyan
