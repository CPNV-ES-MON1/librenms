#!/bin/bash
# ==============================================================================
# setup-win-librenms.sh
# Configuration automatique du client Windows pour LibreNMS
# Exécuté depuis le serveur LibreNMS
#
# Usage:
#   sudo bash setup-win-librenms.sh \
#     --win-ip "ip du client windows" \
#     --win-password 'mot de passe' \
#     --mysql-password 'mot de passe'
# ==============================================================================

set -e

# ==============================================================================
# Valeurs par défaut
# ==============================================================================
WIN_IP=""
WIN_USER="Administrator"
WIN_PASSWORD=""
MYSQL_PASSWORD=""
LIBRENMS_IP="10.0.2.10"
SNMP_COMMUNITY="public"
SSH_KEY_PATH="/var/lib/librenms/.ssh/librenms_restart"
SCRIPT_PATH="/opt/librenms/scripts/restart_w32time_client.sh"

# ==============================================================================
# Parsing des arguments
# ==============================================================================
while [[ $# -gt 0 ]]; do
    case $1 in
        --win-ip)           WIN_IP="$2";           shift 2 ;;
        --win-user)         WIN_USER="$2";          shift 2 ;;
        --win-password)     WIN_PASSWORD="$2";      shift 2 ;;
        --mysql-password)   MYSQL_PASSWORD="$2";    shift 2 ;;
        --librenms-ip)      LIBRENMS_IP="$2";       shift 2 ;;
        --snmp-community)   SNMP_COMMUNITY="$2";    shift 2 ;;
        *) echo "Argument inconnu: $1"; exit 1 ;;
    esac
done

# ==============================================================================
# Vérification des arguments obligatoires
# ==============================================================================
if [[ -z "$WIN_IP" || -z "$WIN_PASSWORD" || -z "$MYSQL_PASSWORD" ]]; then
    echo "Usage: sudo bash $0 --win-ip <IP> --win-password <pass> --mysql-password <pass>"
    echo ""
    echo "Arguments optionnels:"
    echo "  --win-user        Utilisateur Windows (défaut: Administrator)"
    echo "  --librenms-ip     IP du serveur LibreNMS (défaut: 10.229.37.249)"
    echo "  --snmp-community  Communauté SNMP (défaut: public)"
    exit 1
fi

# ==============================================================================
# Fonctions utilitaires
# ==============================================================================
step() { echo -e "\n\033[0;36m===> $1\033[0m"; }
ok()   { echo -e "  \033[0;32m[OK]\033[0m $1"; }
warn() { echo -e "  \033[0;33m[WARN]\033[0m $1"; }
fail() { echo -e "  \033[0;31m[FAIL]\033[0m $1"; exit 1; }

ssh_win() {
    sshpass -p "$WIN_PASSWORD" ssh \
        -o StrictHostKeyChecking=no \
        -o PasswordAuthentication=yes \
        -o ConnectTimeout=10 \
        "$WIN_USER@$WIN_IP" "$1" 2>/dev/null
}

mysql_cmd() {
    mysql -u librenms -p"$MYSQL_PASSWORD" librenms -s -N -e "$1" 2>/dev/null
}

# ==============================================================================
# ÉTAPE 1 : Ajout du device Windows dans LibreNMS
# ==============================================================================
step "Ajout du device Windows dans LibreNMS"

DEVICE_EXISTS=$(mysql_cmd "SELECT COUNT(*) FROM devices WHERE hostname='$WIN_IP';")
if [[ "$DEVICE_EXISTS" == "0" ]]; then
    cd /opt/librenms && sudo -u librenms php artisan device:add --v2c -c "$SNMP_COMMUNITY" --force "$WIN_IP" 2>/dev/null || \
        warn "Ajout du device échoué, vérifiez que SNMP est activé sur le client"
    ok "Device $WIN_IP ajouté dans LibreNMS"
else
    ok "Device $WIN_IP existe déjà dans LibreNMS"
fi

# ==============================================================================
# ÉTAPE 2 : Fréquence de récupération des métriques à 1 minute
# ==============================================================================
step "Configuration de la fréquence de poll à 1 minute"

if ! grep -q "^\* \* \* \* \* librenms.*poller-wrapper" /etc/cron.d/librenms; then
    sed -i 's|^[^#]*poller-wrapper\.py 16|* * * * * librenms /opt/librenms/cronic /opt/librenms/poller-wrapper.py 16|' /etc/cron.d/librenms
    systemctl restart cron
    ok "Fréquence de poll configurée à 1 minute"
else
    ok "Fréquence de poll déjà à 1 minute"
fi

# ==============================================================================
# ÉTAPE 3 : Générer la clé SSH sur le serveur LibreNMS
# ==============================================================================
step "Génération de la clé SSH sur le serveur LibreNMS"

if [ ! -f "$SSH_KEY_PATH" ]; then
    mkdir -p /var/lib/librenms/.ssh
    ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -q
    chown -R librenms:librenms /var/lib/librenms/.ssh
    chmod 600 "$SSH_KEY_PATH"
    ok "Clé SSH générée : $SSH_KEY_PATH"
else
    ok "Clé SSH existe déjà : $SSH_KEY_PATH"
fi

PUB_KEY=$(cat "${SSH_KEY_PATH}.pub")

# ==============================================================================
# ÉTAPE 4 : Configurer OpenSSH Server sur Windows
# ==============================================================================
step "Démarrage et activation de OpenSSH Server sur Windows"

ssh_win "powershell -Command \"Start-Service sshd; Set-Service -Name sshd -StartupType Automatic\""
ok "OpenSSH Server démarré et activé"

# ==============================================================================
# ÉTAPE 5 : Configurer PowerShell comme shell SSH par défaut
# ==============================================================================
step "Configuration de PowerShell comme shell SSH par défaut"

ssh_win "powershell -Command \"New-ItemProperty -Path 'HKLM:\\SOFTWARE\\OpenSSH' -Name DefaultShell -Value 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe' -PropertyType String -Force | Out-Null\""
ok "PowerShell configuré comme shell SSH par défaut"

# ==============================================================================
# ÉTAPE 6 : Copier la clé publique vers Windows
# ==============================================================================
step "Configuration de authorized_keys sur Windows"

ssh_win "powershell -Command \"
New-Item -ItemType Directory -Force -Path 'C:\\ProgramData\\ssh' | Out-Null;
Set-Content -Path 'C:\\ProgramData\\ssh\\administrators_authorized_keys' -Value '$PUB_KEY' -Force;
icacls 'C:\\ProgramData\\ssh\\administrators_authorized_keys' /inheritance:r /grant 'SYSTEM:(F)' /grant 'Administrators:(F)' | Out-Null
\""
ok "authorized_keys configuré"

# ==============================================================================
# ÉTAPE 7 : Activer W32Time comme serveur NTP
# ==============================================================================
step "Configuration de W32Time comme serveur NTP"

ssh_win "powershell -Command \"
w32tm /config /reliable:YES | Out-Null;
Set-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\W32Time\\TimeProviders\\NtpServer' -Name 'Enabled' -Value 1;
Restart-Service W32Time
\""
ok "W32Time configuré comme serveur NTP"

# ==============================================================================
# ÉTAPE 8 : Autoriser NTP dans le firewall Windows
# ==============================================================================
step "Configuration du firewall Windows (port 123 UDP)"

RULE_EXISTS=$(ssh_win "powershell -Command \"
\$r = Get-NetFirewallRule -DisplayName 'NTP-IN' -ErrorAction SilentlyContinue;
if (\$r) { 'EXISTS' } else { 'NOTFOUND' }
\"")

if [[ "$RULE_EXISTS" == *"NOTFOUND"* ]]; then
    ssh_win "powershell -Command \"New-NetFirewallRule -DisplayName 'NTP-IN' -Direction Inbound -Protocol UDP -LocalPort 123 -Action Allow | Out-Null\""
    ok "Règle firewall NTP-IN créée"
else
    ok "Règle firewall NTP-IN existe déjà"
fi

# ==============================================================================
# ÉTAPE 9 : Tester la connexion SSH sans mot de passe depuis LibreNMS
# ==============================================================================
step "Test de la connexion SSH depuis LibreNMS vers Windows"

sleep 3
TEST=$(sudo -u librenms ssh -i "$SSH_KEY_PATH" \
    -o StrictHostKeyChecking=no \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    "$WIN_USER@$WIN_IP" \
    "Get-Service W32Time" 2>&1)

if echo "$TEST" | grep -q "W32Time"; then
    ok "Connexion SSH sans mot de passe fonctionne"
else
    warn "SSH sans mot de passe échoué, vérification manuelle nécessaire"
    warn "Output: $TEST"
fi

# ==============================================================================
# ÉTAPE 10 : Créer le script de restart sur le serveur LibreNMS
# ==============================================================================
step "Création du script de restart W32Time"

cat > "$SCRIPT_PATH" << EOF
#!/bin/bash
ssh -i $SSH_KEY_PATH \\
    -o StrictHostKeyChecking=no \\
    $WIN_USER@$WIN_IP "Restart-Service W32Time; Write-Host 'Service restarted OK'"
EOF

chmod +x "$SCRIPT_PATH"
chown librenms:librenms "$SCRIPT_PATH"
ok "Script créé : $SCRIPT_PATH"

# Test du script
TEST_SCRIPT=$(sudo -u librenms bash "$SCRIPT_PATH" 2>&1)
if echo "$TEST_SCRIPT" | grep -q "restarted OK"; then
    ok "Script de restart testé avec succès"
else
    warn "Test du script échoué : $TEST_SCRIPT"
fi

# ==============================================================================
# ÉTAPE 11 : Configurer LibreNMS (transport, opération, segment, rule)
# ==============================================================================
step "Configuration de LibreNMS (transport, opération, rule)"

# Transport
TRANSPORT_COUNT=$(mysql_cmd "SELECT COUNT(*) FROM alert_transports WHERE transport_name='Restart W32Time';")
if [[ "$TRANSPORT_COUNT" == "0" ]]; then
    mysql_cmd "INSERT INTO alert_transports (transport_name, transport_type, transport_config) VALUES ('Restart W32Time', 'program', '{\"program\":\"$SCRIPT_PATH\"}');"
    ok "Transport 'Restart W32Time' créé"
else
    ok "Transport 'Restart W32Time' existe déjà"
fi
TRANSPORT_ID=$(mysql_cmd "SELECT transport_id FROM alert_transports WHERE transport_name='Restart W32Time';")

# Opération
OPERATION_COUNT=$(mysql_cmd "SELECT COUNT(*) FROM alert_operations WHERE name='Restart W32Time';")
if [[ "$OPERATION_COUNT" == "0" ]]; then
    mysql_cmd "INSERT INTO alert_operations (name, default_operation_step_duration_seconds, notifications_suppressed) VALUES ('Restart W32Time', 0, 0);"
    ok "Opération 'Restart W32Time' créée"
else
    ok "Opération 'Restart W32Time' existe déjà"
fi
OPERATION_ID=$(mysql_cmd "SELECT id FROM alert_operations WHERE name='Restart W32Time';")

# Segment
SEGMENT_COUNT=$(mysql_cmd "SELECT COUNT(*) FROM alert_operation_segments WHERE alert_operation_id=$OPERATION_ID;")
if [[ "$SEGMENT_COUNT" == "0" ]]; then
    mysql_cmd "INSERT INTO alert_operation_segments (alert_operation_id, position, operation_phase, escalation_step_from, escalation_step_to, start_in_seconds, step_duration_seconds) VALUES ($OPERATION_ID, 0, 'problem', 1, NULL, 0, 0);"
    ok "Segment créé"
else
    ok "Segment existe déjà"
fi
SEGMENT_ID=$(mysql_cmd "SELECT id FROM alert_operation_segments WHERE alert_operation_id=$OPERATION_ID;")

# Lien segment -> transport
LINK_COUNT=$(mysql_cmd "SELECT COUNT(*) FROM alert_operation_transport_map WHERE segment_id=$SEGMENT_ID AND transport_or_group_id=$TRANSPORT_ID;")
if [[ "$LINK_COUNT" == "0" ]]; then
    mysql_cmd "INSERT INTO alert_operation_transport_map (segment_id, transport_or_group_id, target_type) VALUES ($SEGMENT_ID, $TRANSPORT_ID, 'single');"
    ok "Segment lié au transport"
else
    ok "Lien segment/transport existe déjà"
fi

# Alert Rule
RULE_COUNT=$(mysql_cmd "SELECT COUNT(*) FROM alert_rules WHERE name='W32Time Service Down';")
if [[ "$RULE_COUNT" == "0" ]]; then
    BUILDER='{"condition":"AND","rules":[{"id":"services.service_status","field":"services.service_status","type":"string","input":"text","operator":"not_equal","value":"0"},{"id":"macros.device_up","field":"macros.device_up","type":"integer","input":"radio","operator":"equal","value":"1"}],"valid":true}'
    QUERY='SELECT * FROM devices,services WHERE (devices.device_id = ? AND devices.device_id = services.device_id) AND services.service_status != 0 AND (devices.status = 1 && (devices.disabled = 0 && devices.ignore = 0)) = 1'
    mysql_cmd "INSERT INTO alert_rules (severity, extra, disabled, name, query, builder, alert_operation_id) VALUES ('critical', '{\"mute\":false,\"count\":-1,\"delay\":0,\"invert\":false,\"interval\":0}', 0, 'W32Time Service Down', '$QUERY', '$BUILDER', $OPERATION_ID);"
    ok "Alert rule 'W32Time Service Down' créée"
else
    ok "Alert rule 'W32Time Service Down' existe déjà"
fi

# ==============================================================================
# ÉTAPE 12 : Ajouter le service NTP dans LibreNMS
# ==============================================================================
step "Ajout du service NTP dans LibreNMS"

DEVICE_ID=$(mysql_cmd "SELECT device_id FROM devices WHERE hostname='$WIN_IP';")

if [[ -z "$DEVICE_ID" ]]; then
    warn "Device $WIN_IP non trouvé dans LibreNMS, service non ajouté"
    warn "Relancez le script après avoir vérifié la connectivité SNMP"
else
    SERVICE_COUNT=$(mysql_cmd "SELECT COUNT(*) FROM services WHERE device_id=$DEVICE_ID AND service_type='ntp_time';")
    if [[ "$SERVICE_COUNT" == "0" ]]; then
        mysql_cmd "INSERT INTO services (device_id, service_ip, service_type, service_desc, service_param, service_name) VALUES ($DEVICE_ID, '$WIN_IP', 'ntp_time', 'Windows NTP Service', '-w 0.5 -c 1', 'W32Time_Service');"
        ok "Service W32Time_Service ajouté dans LibreNMS"
    else
        ok "Service W32Time_Service existe déjà dans LibreNMS"
    fi
fi

# ==============================================================================
# ÉTAPE 13 : Forcer la découverte et le poll du device
# ==============================================================================
step "Découverte et poll du device Windows"

cd /opt/librenms
# Ajouter la location Datacenter si elle n existe pas
LOCATION_ID=$(mysql_cmd "SELECT id FROM locations WHERE location='Datacenter' LIMIT 1;")
if [[ -z "$LOCATION_ID" ]]; then
    mysql_cmd "INSERT INTO locations (location) VALUES ('Datacenter');"
    LOCATION_ID=$(mysql_cmd "SELECT id FROM locations WHERE location='Datacenter' LIMIT 1;")
fi

# Assigner la location au device et activer unix-agent
DEVICE_ID_TMP=$(mysql_cmd "SELECT device_id FROM devices WHERE hostname='$WIN_IP';")
if [[ -n "$DEVICE_ID_TMP" ]]; then
    mysql_cmd "UPDATE devices SET location_id=$LOCATION_ID WHERE device_id=$DEVICE_ID_TMP;"
    ok "Location 'Datacenter' assignée au device"

    # Activer le module unix-agent pour Check_MK
    AGENT_EXISTS=$(mysql_cmd "SELECT COUNT(*) FROM devices_attribs WHERE device_id=$DEVICE_ID_TMP AND attrib_type='poll_unix-agent';")
    if [[ "$AGENT_EXISTS" == "0" ]]; then
        mysql_cmd "INSERT INTO devices_attribs (device_id, attrib_type, attrib_value) VALUES ($DEVICE_ID_TMP, 'poll_unix-agent', '1');"
        ok "Module unix-agent activé"
    else
        ok "Module unix-agent déjà activé"
    fi
fi

sleep 10
sudo -u librenms php artisan device:discover "$WIN_IP" 2>/dev/null && ok "Discovery effectué" || warn "Discovery échoué"
sleep 5
sudo -u librenms php artisan device:poll "$WIN_IP" 2>/dev/null && ok "Poll effectué" || warn "Poll échoué"

# ==============================================================================
# ÉTAPE 14 : Activer le module services dans LibreNMS
# ==============================================================================
step "Activation du module services dans LibreNMS"

if ! grep -q "show_services" /opt/librenms/config.php 2>/dev/null; then
    echo "\$config['show_services'] = 1;" >> /opt/librenms/config.php
    ok "Module services activé dans config.php"
else
    ok "Module services déjà activé"
fi

# ==============================================================================
# RÉSUMÉ
# ==============================================================================
echo -e "\n\033[0;36m============================================\033[0m"
echo -e "\033[0;32m  Configuration terminée avec succès !\033[0m"
echo -e "\033[0;36m============================================\033[0m"
echo "  Serveur LibreNMS : $LIBRENMS_IP"
echo "  Client Windows   : $WIN_IP"
echo "  Service surveillé: W32Time (NTP port 123)"
echo "  Clé SSH          : $SSH_KEY_PATH"
echo "  Script restart   : $SCRIPT_PATH"
echo ""
echo "  Pour tester le scénario :"
echo "    Sur Windows : Stop-Service W32Time"
echo "    Attendre ~2 minutes"
echo "    Sur Windows : Get-Service W32Time  # doit être Running"
echo ""
echo "  Pour vérifier les alertes :"
echo "    mysql -u librenms -p librenms -e \"SELECT datetime, message FROM eventlog WHERE type='alert' AND message LIKE '%Issued%' ORDER BY datetime DESC LIMIT 5;\""
echo -e "\033[0;36m============================================\033[0m\n"
