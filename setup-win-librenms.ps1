# ==============================================================================
# setup-win-librenms.ps1
# Configuration automatique du client Windows pour LibreNMS
# Usage: .\setup-win-librenms.ps1 -LibreNMSIP <IP> -LibreNMSUser <user> -LibreNMSPassword <pass> -MySQLPassword <pass>
# ==============================================================================

param(
    [Parameter(Mandatory=$true)]
    [string]$LibreNMSIP = "10.229.37.249",

    [Parameter(Mandatory=$true)]
    [string]$LibreNMSUser = "cpnv",

    [Parameter(Mandatory=$true)]
    [string]$LibreNMSPassword,

    [Parameter(Mandatory=$true)]
    [string]$MySQLPassword,

    [string]$WindowsIP = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike "*Loopback*" } | Select-Object -First 1 -ExpandProperty IPAddress),
    [string]$SNMPCommunity = "public"
)

# ==============================================================================
# Fonctions utilitaires
# ==============================================================================

function Write-Step {
    param([string]$Message)
    Write-Host "`n===> $Message" -ForegroundColor Cyan
}

function Write-OK {
    param([string]$Message)
    Write-Host "  [OK] $Message" -ForegroundColor Green
}

function Write-Fail {
    param([string]$Message)
    Write-Host "  [FAIL] $Message" -ForegroundColor Red
    exit 1
}

function Invoke-SSHCommand {
    param(
        [string]$Command,
        [string]$KeyPath = "C:\ProgramData\librenms\librenms_restart"
    )
    $result = & ssh -i $KeyPath `
        -o StrictHostKeyChecking=no `
        -o BatchMode=yes `
        "$LibreNMSUser@$LibreNMSIP" $Command 2>&1
    return $result
}

function Invoke-SSHCommandWithPassword {
    param([string]$Command)
    $result = & ssh -o StrictHostKeyChecking=no `
        "$LibreNMSUser@$LibreNMSIP" $Command 2>&1
    return $result
}

# ==============================================================================
# ÉTAPE 1 : Configurer OpenSSH Server
# ==============================================================================

Write-Step "Configuration OpenSSH Server"

$sshdStatus = Get-Service sshd -ErrorAction SilentlyContinue
if ($sshdStatus -eq $null) {
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
    Write-OK "OpenSSH Server installé"
}

Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
Write-OK "OpenSSH Server démarré et activé"

# ==============================================================================
# ÉTAPE 2 : Configurer PowerShell comme shell SSH par défaut
# ==============================================================================

Write-Step "Configuration de PowerShell comme shell SSH par défaut"

$psPath = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" `
    -Name DefaultShell `
    -Value $psPath `
    -PropertyType String `
    -Force | Out-Null

Write-OK "PowerShell configuré comme shell SSH par défaut"

# ==============================================================================
# ÉTAPE 3 : Générer la clé SSH sur le serveur LibreNMS via SSH avec mot de passe
# ==============================================================================

Write-Step "Génération de la clé SSH sur le serveur LibreNMS"

# Utilise plink (PuTTY) ou ssh avec sshpass si disponible
# Sur Windows Server Core on utilise ssh avec expect via la commande suivante

$sshKeyPath = "/var/lib/librenms/.ssh/librenms_restart"

# Vérifier si la clé existe déjà
$checkKey = echo $LibreNMSPassword | & ssh -o StrictHostKeyChecking=no `
    -o PasswordAuthentication=yes `
    "$LibreNMSUser@$LibreNMSIP" `
    "test -f $sshKeyPath && echo EXISTS || echo NOTFOUND" 2>&1

if ($checkKey -match "NOTFOUND") {
    # Générer la clé
    echo $LibreNMSPassword | & ssh -o StrictHostKeyChecking=no `
        "$LibreNMSUser@$LibreNMSIP" `
        "ssh-keygen -t ed25519 -f $sshKeyPath -N ''" 2>&1 | Out-Null

    # Créer le dossier et mettre les permissions
    echo $LibreNMSPassword | & ssh -o StrictHostKeyChecking=no `
        "$LibreNMSUser@$LibreNMSIP" `
        "sudo mkdir -p /var/lib/librenms/.ssh && sudo chown -R librenms:librenms /var/lib/librenms/.ssh && sudo chmod 600 $sshKeyPath" 2>&1 | Out-Null

    Write-OK "Clé SSH générée sur le serveur LibreNMS"
} else {
    Write-OK "Clé SSH existe déjà sur le serveur LibreNMS"
}

# ==============================================================================
# ÉTAPE 4 : Récupérer la clé publique depuis le serveur LibreNMS
# ==============================================================================

Write-Step "Récupération de la clé publique depuis LibreNMS"

$pubKey = echo $LibreNMSPassword | & ssh -o StrictHostKeyChecking=no `
    "$LibreNMSUser@$LibreNMSIP" `
    "sudo cat ${sshKeyPath}.pub" 2>&1

if (-not $pubKey -or $pubKey -notmatch "ssh-ed25519") {
    Write-Fail "Impossible de récupérer la clé publique"
}

Write-OK "Clé publique récupérée : $($pubKey.Substring(0, 40))..."

# ==============================================================================
# ÉTAPE 5 : Configurer authorized_keys sur Windows
# ==============================================================================

Write-Step "Configuration de authorized_keys pour Administrator"

New-Item -ItemType Directory -Force -Path "C:\ProgramData\ssh" | Out-Null
Set-Content -Path "C:\ProgramData\ssh\administrators_authorized_keys" -Value $pubKey -Force

icacls "C:\ProgramData\ssh\administrators_authorized_keys" /inheritance:r /grant "SYSTEM:(F)" /grant "Administrators:(F)" | Out-Null

Write-OK "authorized_keys configuré"

# ==============================================================================
# ÉTAPE 6 : Activer W32Time comme serveur NTP
# ==============================================================================

Write-Step "Configuration de W32Time comme serveur NTP"

w32tm /config /reliable:YES 2>&1 | Out-Null

Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpServer" `
    -Name "Enabled" -Value 1

Restart-Service W32Time
Write-OK "W32Time configuré comme serveur NTP"

# ==============================================================================
# ÉTAPE 7 : Autoriser NTP dans le firewall Windows
# ==============================================================================

Write-Step "Configuration du firewall Windows"

$ntpRule = Get-NetFirewallRule -DisplayName "NTP-IN" -ErrorAction SilentlyContinue
if (-not $ntpRule) {
    New-NetFirewallRule -DisplayName "NTP-IN" -Direction Inbound -Protocol UDP -LocalPort 123 -Action Allow | Out-Null
    Write-OK "Règle firewall NTP-IN créée"
} else {
    Write-OK "Règle firewall NTP-IN existe déjà"
}

# ==============================================================================
# ÉTAPE 8 : Tester la connexion SSH sans mot de passe
# ==============================================================================

Write-Step "Test de la connexion SSH depuis LibreNMS vers Windows"

# Attendre que sshd soit prêt
Start-Sleep -Seconds 3

$testSSH = echo $LibreNMSPassword | & ssh -o StrictHostKeyChecking=no `
    "$LibreNMSUser@$LibreNMSIP" `
    "sudo -u librenms ssh -i $sshKeyPath -o StrictHostKeyChecking=no Administrator@$WindowsIP 'Get-Service W32Time' 2>&1" 2>&1

if ($testSSH -match "W32Time") {
    Write-OK "Connexion SSH depuis LibreNMS vers Windows fonctionne"
} else {
    Write-Host "  [WARN] SSH test échoué, vérification manuelle nécessaire" -ForegroundColor Yellow
    Write-Host "  Output: $testSSH" -ForegroundColor Yellow
}

# ==============================================================================
# ÉTAPE 9 : Créer le script de restart sur le serveur LibreNMS
# ==============================================================================

Write-Step "Création du script de restart sur LibreNMS"

$scriptContent = "#!/bin/bash`nssh -i /var/lib/librenms/.ssh/librenms_restart -o StrictHostKeyChecking=no Administrator@$WindowsIP `"Restart-Service W32Time; Write-Host 'Service restarted OK'`""

echo $LibreNMSPassword | & ssh -o StrictHostKeyChecking=no `
    "$LibreNMSUser@$LibreNMSIP" `
    "echo '$scriptContent' | sudo tee /opt/librenms/scripts/restart_w32time_client.sh > /dev/null && sudo chmod +x /opt/librenms/scripts/restart_w32time_client.sh && sudo chown librenms:librenms /opt/librenms/scripts/restart_w32time_client.sh" 2>&1 | Out-Null

Write-OK "Script de restart créé"

# ==============================================================================
# ÉTAPE 10 : Configurer LibreNMS via MySQL
# ==============================================================================

Write-Step "Configuration de LibreNMS (transport, opération, rule)"

# Vérifier si le transport existe déjà
$checkTransport = echo $LibreNMSPassword | & ssh -o StrictHostKeyChecking=no `
    "$LibreNMSUser@$LibreNMSIP" `
    "sudo mysql -u librenms -p$MySQLPassword librenms -e ""SELECT COUNT(*) FROM alert_transports WHERE transport_name='Restart W32Time';"" -s -N 2>/dev/null" 2>&1

if ($checkTransport -eq "0") {
    # Créer le transport
    echo $LibreNMSPassword | & ssh -o StrictHostKeyChecking=no `
        "$LibreNMSUser@$LibreNMSIP" `
        "sudo mysql -u librenms -p$MySQLPassword librenms -e ""INSERT INTO alert_transports (transport_name, transport_type, transport_config) VALUES ('Restart W32Time', 'program', '{\\\"program\\\":\\\"/opt/librenms/scripts/restart_w32time_client.sh\\\"}');"" 2>/dev/null" 2>&1 | Out-Null

    # Récupérer transport_id
    $transportId = echo $LibreNMSPassword | & ssh -o StrictHostKeyChecking=no `
        "$LibreNMSUser@$LibreNMSIP" `
        "sudo mysql -u librenms -p$MySQLPassword librenms -e ""SELECT transport_id FROM alert_transports WHERE transport_name='Restart W32Time';"" -s -N 2>/dev/null" 2>&1

    # Créer l'opération
    echo $LibreNMSPassword | & ssh -o StrictHostKeyChecking=no `
        "$LibreNMSUser@$LibreNMSIP" `
        "sudo mysql -u librenms -p$MySQLPassword librenms -e ""INSERT INTO alert_operations (name, default_operation_step_duration_seconds, notifications_suppressed) VALUES ('Restart W32Time', 0, 0);"" 2>/dev/null" 2>&1 | Out-Null

    # Récupérer operation_id
    $operationId = echo $LibreNMSPassword | & ssh -o StrictHostKeyChecking=no `
        "$LibreNMSUser@$LibreNMSIP" `
        "sudo mysql -u librenms -p$MySQLPassword librenms -e ""SELECT id FROM alert_operations WHERE name='Restart W32Time';"" -s -N 2>/dev/null" 2>&1

    # Créer le segment
    echo $LibreNMSPassword | & ssh -o StrictHostKeyChecking=no `
        "$LibreNMSUser@$LibreNMSIP" `
        "sudo mysql -u librenms -p$MySQLPassword librenms -e ""INSERT INTO alert_operation_segments (alert_operation_id, position, operation_phase, escalation_step_from, escalation_step_to, start_in_seconds, step_duration_seconds) VALUES ($operationId, 0, 'problem', 1, NULL, 0, 0);"" 2>/dev/null" 2>&1 | Out-Null

    # Récupérer segment_id
    $segmentId = echo $LibreNMSPassword | & ssh -o StrictHostKeyChecking=no `
        "$LibreNMSUser@$LibreNMSIP" `
        "sudo mysql -u librenms -p$MySQLPassword librenms -e ""SELECT id FROM alert_operation_segments WHERE alert_operation_id=$operationId;"" -s -N 2>/dev/null" 2>&1

    # Lier segment au transport
    echo $LibreNMSPassword | & ssh -o StrictHostKeyChecking=no `
        "$LibreNMSUser@$LibreNMSIP" `
        "sudo mysql -u librenms -p$MySQLPassword librenms -e ""INSERT INTO alert_operation_transport_map (segment_id, transport_or_group_id, target_type) VALUES ($segmentId, $transportId, 'single');"" 2>/dev/null" 2>&1 | Out-Null

    # Créer la rule
    $builder = '{\"condition\":\"AND\",\"rules\":[{\"id\":\"services.service_status\",\"field\":\"services.service_status\",\"type\":\"string\",\"input\":\"text\",\"operator\":\"not_equal\",\"value\":\"0\"},{\"id\":\"macros.device_up\",\"field\":\"macros.device_up\",\"type\":\"integer\",\"input\":\"radio\",\"operator\":\"equal\",\"value\":\"1\"}],\"valid\":true}'
    $query = 'SELECT * FROM devices,services WHERE (devices.device_id = ? AND devices.device_id = services.device_id) AND services.service_status != 0 AND (devices.status = 1 && (devices.disabled = 0 && devices.ignore = 0)) = 1'

    echo $LibreNMSPassword | & ssh -o StrictHostKeyChecking=no `
        "$LibreNMSUser@$LibreNMSIP" `
        "sudo mysql -u librenms -p$MySQLPassword librenms -e ""INSERT INTO alert_rules (severity, extra, disabled, name, query, builder, alert_operation_id) VALUES ('critical', '{\\\"mute\\\":false,\\\"count\\\":-1,\\\"delay\\\":0,\\\"invert\\\":false,\\\"interval\\\":0}', 0, 'W32Time Service Down', '$query', '$builder', $operationId);"" 2>/dev/null" 2>&1 | Out-Null

    Write-OK "Transport, opération, segment et rule créés (transport_id=$transportId, operation_id=$operationId)"
} else {
    Write-OK "Transport 'Restart W32Time' existe déjà, configuration ignorée"
}

# ==============================================================================
# ÉTAPE 11 : Ajouter le service dans LibreNMS
# ==============================================================================

Write-Step "Ajout du service NTP dans LibreNMS"

$checkService = echo $LibreNMSPassword | & ssh -o StrictHostKeyChecking=no `
    "$LibreNMSUser@$LibreNMSIP" `
    "sudo mysql -u librenms -p$MySQLPassword librenms -e ""SELECT COUNT(*) FROM services WHERE service_ip='$WindowsIP' AND service_type='ntp_time';"" -s -N 2>/dev/null" 2>&1

if ($checkService -eq "0") {
    # Récupérer device_id
    $deviceId = echo $LibreNMSPassword | & ssh -o StrictHostKeyChecking=no `
        "$LibreNMSUser@$LibreNMSIP" `
        "sudo mysql -u librenms -p$MySQLPassword librenms -e ""SELECT device_id FROM devices WHERE hostname='$WindowsIP';"" -s -N 2>/dev/null" 2>&1

    if ($deviceId) {
        echo $LibreNMSPassword | & ssh -o StrictHostKeyChecking=no `
            "$LibreNMSUser@$LibreNMSIP" `
            "sudo mysql -u librenms -p$MySQLPassword librenms -e ""INSERT INTO services (device_id, service_ip, service_type, service_desc, service_param, service_name) VALUES ($deviceId, '$WindowsIP', 'ntp_time', 'Windows NTP Service', '-w 0.5 -c 1', 'W32Time_Service');"" 2>/dev/null" 2>&1 | Out-Null
        Write-OK "Service W32Time_Service ajouté dans LibreNMS"
    } else {
        Write-Host "  [WARN] Device $WindowsIP non trouvé dans LibreNMS, ajout du service ignoré" -ForegroundColor Yellow
        Write-Host "  Ajoutez d'abord le device avec : ./lnms device:add --v2c -c $SNMPCommunity $WindowsIP" -ForegroundColor Yellow
    }
} else {
    Write-OK "Service W32Time_Service existe déjà dans LibreNMS"
}

# ==============================================================================
# RÉSUMÉ
# ==============================================================================

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  Configuration terminée avec succès !" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Serveur LibreNMS : $LibreNMSIP"
Write-Host "  Client Windows   : $WindowsIP"
Write-Host "  Service surveillé: W32Time (NTP port 123)"
Write-Host "  Transport SSH    : /opt/librenms/scripts/restart_w32time_client.sh"
Write-Host "`n  Pour tester :"
Write-Host "    Stop-Service W32Time"
Write-Host "    # Attendre ~2 minutes"
Write-Host "    Get-Service W32Time  # doit être Running"
Write-Host "============================================`n" -ForegroundColor Cyan
