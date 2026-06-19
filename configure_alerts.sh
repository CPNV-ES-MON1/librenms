#!/bin/bash
# =============================================================================
# Script de configuration des alertes LibreNMS avec transport Telegram
# =============================================================================
# Usage: sudo bash configure_alerts.sh
# =============================================================================

set -e

# --- Couleurs ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

[ "$EUID" -ne 0 ] && error "Ce script doit être exécuté en tant que root (sudo bash $0)"

DB_NAME="librenms"
LIBRENMS_DIR="/data/librenms"

# =============================================================================
# 1. SAISIE INTERACTIVE
# =============================================================================
echo ""
echo -e "${BLUE}=== Configuration des alertes LibreNMS ===${NC}"
echo ""

read -p "Token du bot Telegram : " TELEGRAM_TOKEN
read -p "Chat ID du groupe Telegram : " TELEGRAM_CHAT_ID

# Validation que les champs ne sont pas vides
[ -z "$TELEGRAM_TOKEN" ]   && error "Le token Telegram est obligatoire."
[ -z "$TELEGRAM_CHAT_ID" ] && error "Le Chat ID Telegram est obligatoire."

# =============================================================================
# 2. TEST DE CONNEXION AU BOT TELEGRAM
# =============================================================================
info "Vérification du bot Telegram..."
RESPONSE=$(curl -s "https://api.telegram.org/bot${TELEGRAM_TOKEN}/getMe")
if echo "$RESPONSE" | grep -q '"ok":true'; then
  BOT_NAME=$(echo "$RESPONSE" | grep -o '"username":"[^"]*"' | cut -d'"' -f4)
  success "Bot Telegram vérifié : @${BOT_NAME}"
else
  error "Token Telegram invalide ou bot inaccessible. Vérifiez le token."
fi

# Test d'envoi d'un message
info "Envoi d'un message de test..."
TEST_RESPONSE=$(curl -s -X POST \
  "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
  -d "chat_id=${TELEGRAM_CHAT_ID}&text=✅ LibreNMS - Configuration des alertes en cours...")

if echo "$TEST_RESPONSE" | grep -q '"ok":true'; then
  success "Message de test envoyé sur Telegram."
else
  error "Impossible d'envoyer sur le Chat ID ${TELEGRAM_CHAT_ID}. Vérifiez que le bot est dans le groupe."
fi

# =============================================================================
# 3. CRÉATION DU TRANSPORT TELEGRAM EN BASE
# =============================================================================
info "Création du transport Telegram..."

TRANSPORT_CONFIG="{\"telegram-chat-id\":\"${TELEGRAM_CHAT_ID}\",\"message-thread-id\":\"\",\"telegram-token\":\"${TELEGRAM_TOKEN}\",\"telegram-format\":\"HTML\",\"telegram-send-png-graph-mode\":\"photo\"}"

mysql -u root "$DB_NAME" <<SQLEOF
-- Supprimer l'ancien transport Telegram s'il existe
DELETE FROM alert_transports WHERE transport_type = 'telegram';

-- Créer le transport Telegram
INSERT INTO alert_transports (transport_name, transport_type, is_default, transport_config)
VALUES ('telegram', 'telegram', 0, '${TRANSPORT_CONFIG}');
SQLEOF

TRANSPORT_ID=$(mysql -u root "$DB_NAME" -sNe \
  "SELECT transport_id FROM alert_transports WHERE transport_type='telegram' LIMIT 1;")

[ -z "$TRANSPORT_ID" ] && error "Impossible de créer le transport Telegram."
success "Transport Telegram créé (ID: ${TRANSPORT_ID})."

# =============================================================================
# 4. CRÉATION DU TRANSPORT GROUP
# =============================================================================
info "Création du transport group Telegram..."

mysql -u root "$DB_NAME" <<SQLEOF
-- Supprimer l'ancien groupe s'il existe
DELETE FROM transport_group_transport WHERE transport_group_id IN (
  SELECT transport_group_id FROM alert_transport_groups WHERE transport_group_name = 'Telegram'
);
DELETE FROM alert_transport_groups WHERE transport_group_name = 'Telegram';

-- Créer le groupe
INSERT INTO alert_transport_groups (transport_group_name)
VALUES ('Telegram');
SQLEOF

GROUP_ID=$(mysql -u root "$DB_NAME" -sNe \
  "SELECT transport_group_id FROM alert_transport_groups WHERE transport_group_name='Telegram' LIMIT 1;")

# Lier le transport au groupe
mysql -u root "$DB_NAME" <<SQLEOF
INSERT INTO transport_group_transport (transport_group_id, transport_id)
VALUES (${GROUP_ID}, ${TRANSPORT_ID});
SQLEOF

success "Transport group Telegram créé (ID: ${GROUP_ID})."

# =============================================================================
# 5. CRÉATION DE L'ALERT TEMPLATE
# =============================================================================
info "Création du template d'alerte..."

TEMPLATE_BODY='@if ($alert->state == 1)
⚠️ Interruption de service détectée.
La machine "{{ $alert->display }}" est actuellement indisponible.
Nos équipes sont informées et travaillent à la résolution.
@else
✅ Service rétabli.
La machine "{{ $alert->display }}" est de nouveau disponible.
Merci de votre patience.
@endif'

TEMPLATE_RECOVERY='✅ Service rétabli. La machine "{{ $alert->display }}" est de nouveau disponible. Merci de votre patience.'

mysql -u root "$DB_NAME" <<SQLEOF
-- Supprimer l'ancien template par défaut s'il existe
DELETE FROM alert_templates WHERE name = 'Default Alert Template';

-- Créer le template
INSERT INTO alert_templates (name, template, title, title_rec)
VALUES (
  'Default Alert Template',
  '${TEMPLATE_BODY}',
  '⚠️ Interruption de service',
  '${TEMPLATE_RECOVERY}'
);
SQLEOF

TEMPLATE_ID=$(mysql -u root "$DB_NAME" -sNe \
  "SELECT id FROM alert_templates WHERE name='Default Alert Template' LIMIT 1;")

# Lier le template à toutes les règles
mysql -u root "$DB_NAME" <<SQLEOF
DELETE FROM alert_template_map;
INSERT INTO alert_template_map (alert_templates_id, alert_rule_id)
SELECT ${TEMPLATE_ID}, id FROM alert_rules;
SQLEOF

success "Template d'alerte créé et lié à toutes les règles (ID: ${TEMPLATE_ID})."

# =============================================================================
# 6. CRÉATION DE L'OPERATION ET LIAISON AUX RÈGLES
# =============================================================================
info "Création de l'opération d'alerte et liaison au transport group..."

mysql -u root "$DB_NAME" <<SQLEOF
-- Nettoyage des anciennes opérations
DELETE FROM alert_operation_transport_map;
DELETE FROM alert_operation_segments;
DELETE FROM alert_operations;

-- 1. Créer l'opération
INSERT INTO alert_operations (name, notifications_suppressed)
VALUES ('Telegram', 0);
SET @op_id = LAST_INSERT_ID();

-- 2. Créer un segment pour la phase "problem"
INSERT INTO alert_operation_segments
  (alert_operation_id, position, operation_phase, escalation_step_from,
   escalation_step_to, start_in_seconds, step_duration_seconds)
VALUES
  (@op_id, 0, 'problem', 1, NULL, 0, 0);
SET @seg_id = LAST_INSERT_ID();

-- 3. Lier le transport group au segment
INSERT INTO alert_operation_transport_map (segment_id, transport_or_group_id, target_type)
VALUES (@seg_id, ${GROUP_ID}, 'group');

-- 4. Lier toutes les règles à cette opération
UPDATE alert_rules SET alert_operation_id = @op_id;
SQLEOF

success "Opération créée et liée à toutes les règles d'alerte."

# =============================================================================
# 7. VIDER LE CACHE LIBRENMS
# =============================================================================
info "Vidage du cache LibreNMS..."
su - librenms -s /bin/bash -c \
  "cd $LIBRENMS_DIR && php lnms config:cache" 2>/dev/null || true
success "Cache vidé."

# =============================================================================
# FIN
# =============================================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  Configuration des alertes Telegram terminée !${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "  Bot Telegram    : ${YELLOW}@${BOT_NAME}${NC}"
echo -e "  Chat ID         : ${YELLOW}${TELEGRAM_CHAT_ID}${NC}"
echo -e "  Transport ID    : ${YELLOW}${TRANSPORT_ID}${NC}"
echo -e "  Transport Group : ${YELLOW}${GROUP_ID}${NC}"
echo -e "  Template        : ${YELLOW}${TEMPLATE_ID}${NC}"
echo ""
info "Un message de test a été envoyé sur votre groupe Telegram."
echo ""
