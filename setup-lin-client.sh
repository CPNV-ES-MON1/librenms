#!/bin/bash
# ==============================================================================
# setup-lin-client.sh
# Configuration initiale du client Linux pour LibreNMS
# A executer UNE SEULE FOIS directement sur le client Linux
#
# Usage:
#   sudo bash setup-lin-client.sh --librenms-ip 10.229.37.249 --snmp-community public
# ==============================================================================

set -e

# ==============================================================================
# Valeurs par défaut
# ==============================================================================
LIBRENMS_IP="10.229.37.249"
SNMP_COMMUNITY="public"
LIN_USER="cpnv"

# ==============================================================================
# Parsing des arguments
# ==============================================================================
while [[ $# -gt 0 ]]; do
    case $1 in
        --librenms-ip)      LIBRENMS_IP="$2";    shift 2 ;;
        --snmp-community)   SNMP_COMMUNITY="$2"; shift 2 ;;
        --user)             LIN_USER="$2";        shift 2 ;;
        *) echo "Argument inconnu: $1"; exit 1 ;;
    esac
done

# ==============================================================================
# Fonctions utilitaires
# ==============================================================================
step() { echo -e "\n\033[0;36m===> $1\033[0m"; }
ok()   { echo -e "  \033[0;32m[OK]\033[0m $1"; }
warn() { echo -e "  \033[0;33m[WARN]\033[0m $1"; }
fail() { echo -e "  \033[0;31m[FAIL]\033[0m $1"; exit 1; }

# ==============================================================================
# ÉTAPE 1 : Installer et configurer SNMP
# ==============================================================================
step "Installation et configuration de SNMP"

apt-get update -qq
apt-get install -y snmpd 2>/dev/null
ok "snmpd installé"

# Configurer la communauté SNMP
sed -i "s|^rocommunity.*|rocommunity $SNMP_COMMUNITY $LIBRENMS_IP|" /etc/snmp/snmpd.conf
if ! grep -q "rocommunity $SNMP_COMMUNITY" /etc/snmp/snmpd.conf; then
    echo "rocommunity $SNMP_COMMUNITY $LIBRENMS_IP" >> /etc/snmp/snmpd.conf
fi

# Écouter sur toutes les interfaces
sed -i 's|^agentAddress.*|agentAddress udp:161|' /etc/snmp/snmpd.conf
if ! grep -q "^agentAddress" /etc/snmp/snmpd.conf; then
    echo "agentAddress udp:161" >> /etc/snmp/snmpd.conf
fi

systemctl enable snmpd
systemctl restart snmpd
ok "SNMP configuré avec la communauté '$SNMP_COMMUNITY' pour $LIBRENMS_IP"

# ==============================================================================
# ÉTAPE 2 : Configurer sysLocation
# ==============================================================================
step "Configuration de sysLocation SNMP"

if ! grep -q "^sysLocation" /etc/snmp/snmpd.conf; then
    echo "sysLocation Datacenter" >> /etc/snmp/snmpd.conf
else
    sed -i 's|^sysLocation.*|sysLocation Datacenter|' /etc/snmp/snmpd.conf
fi
systemctl restart snmpd
ok "sysLocation configuré à 'Datacenter'"

# ==============================================================================
# ÉTAPE 3 : Installer l'agent Check_MK
# ==============================================================================
step "Installation de l'agent Check_MK"

if [ ! -f /usr/bin/check_mk_agent ]; then
    apt-get install -y wget 2>/dev/null
    wget -q https://github.com/tribe29/checkmk/raw/v1.2.6b5/agents/check_mk_agent.linux \
        -O /usr/bin/check_mk_agent
    chmod +x /usr/bin/check_mk_agent
    ok "Agent Check_MK installé"
else
    ok "Agent Check_MK déjà installé"
fi

# Configurer via systemd socket
if [ ! -f /etc/systemd/system/check_mk.socket ]; then
    cat > /etc/systemd/system/check_mk.socket << 'EOF'
[Unit]
Description=Check_MK LibreNMS Agent Socket

[Socket]
ListenStream=6556
Accept=yes

[Install]
WantedBy=sockets.target
EOF

    cat > /etc/systemd/system/check_mk@.service << 'EOF'
[Unit]
Description=Check_MK LibreNMS Agent

[Service]
ExecStart=/usr/bin/check_mk_agent
StandardInput=socket
EOF

    systemctl daemon-reload
    systemctl enable check_mk.socket
    systemctl start check_mk.socket
    ok "Agent Check_MK configuré via systemd socket (port 6556)"
else
    ok "Agent Check_MK socket déjà configuré"
fi

# ==============================================================================
# ÉTAPE 4 : Installer ntpsec comme serveur NTP
# ==============================================================================
step "Installation et configuration de ntpsec"

apt-get install -y ntpsec 2>/dev/null
systemctl enable ntpsec
systemctl start ntpsec
ok "ntpsec installé et démarré"

# ==============================================================================
# ÉTAPE 5 : Configurer sudoers pour restart ntpsec sans mot de passe
# ==============================================================================
step "Configuration sudoers pour restart ntpsec"

SUDOERS_FILE="/etc/sudoers.d/librenms-ntp"
if [ ! -f "$SUDOERS_FILE" ]; then
    echo "$LIN_USER ALL=(ALL) NOPASSWD: /bin/systemctl restart ntpsec" > "$SUDOERS_FILE"
    chmod 440 "$SUDOERS_FILE"
    ok "sudoers configuré pour $LIN_USER"
else
    ok "sudoers déjà configuré"
fi

# ==============================================================================
# ÉTAPE 6 : Autoriser les ports dans le firewall (si ufw actif)
# ==============================================================================
step "Configuration du firewall"

if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
    ufw allow from "$LIBRENMS_IP" to any port 161 proto udp comment "SNMP"
    ufw allow from "$LIBRENMS_IP" to any port 22 proto tcp comment "SSH LibreNMS"
    ufw allow from "$LIBRENMS_IP" to any port 6556 proto tcp comment "Check_MK"
    ufw allow 123/udp comment "NTP"
    ok "Règles firewall ufw configurées"
else
    ok "ufw non actif, pas de règles firewall nécessaires"
fi

# ==============================================================================
# RÉSUMÉ
# ==============================================================================
echo -e "\n\033[0;36m============================================\033[0m"
echo -e "\033[0;32m  Configuration client Linux terminée !\033[0m"
echo -e "\033[0;36m============================================\033[0m"
echo "  SNMP communauté : $SNMP_COMMUNITY"
echo "  SNMP autorisé   : $LIBRENMS_IP"
echo "  ntpsec NTP      : actif (port 123)"
echo "  Check_MK agent  : actif (port 6556)"
echo "  SSH             : actif (port 22)"
echo ""
echo "  Prochaine étape : executer setup-lin-librenms.sh"
echo "  sur le serveur LibreNMS avec :"
echo "  sudo bash setup-lin-librenms.sh --lin-ip <IP_DE_CE_LINUX> --lin-password <PASS> --mysql-password <PASS>"
echo -e "\033[0;36m============================================\033[0m\n"
