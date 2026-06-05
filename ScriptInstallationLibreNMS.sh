#!/bin/bash
# =============================================================================
# Script d'installation complète de LibreNMS
# =============================================================================
# Usage: sudo bash install_librenms.sh
# =============================================================================

set -e

# --- Couleurs ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

[ "$EUID" -ne 0 ] && error "Ce script doit être exécuté en tant que root (sudo bash $0)"

# =============================================================================
# VARIABLES FIXES
# =============================================================================
# Détection automatique du data storage
# Cherche le deuxième disque non partitionné (pas le disque OS)
# Supporte sdb (SATA/SCSI) et nvme1n1 (NVMe)
OS_DISK=$(lsblk -ndo PKNAME $(findmnt -n -o SOURCE /) 2>/dev/null || echo "")
DATA_DISK=$(lsblk -ndo NAME,TYPE | awk '$2=="disk" {print $1}' | grep -v "^${OS_DISK}$" | head -1)
DATA_DISK="/dev/${DATA_DISK}"
DATA_MOUNT="/data"

DB_NAME="librenms"
DB_USER="librenms"
SNMP_COMMUNITY="public"
TIMEZONE="Europe/Zurich"
PHP_TARGET="8.3"
LIBRENMS_DIR="/opt/librenms"
SERVER_IP=$(hostname -I | awk '{print $1}')
APP_URL="http://${SERVER_IP}"

# Valeurs par défaut (surchargées par les arguments)
DB_PASS=""
ADMIN_USER=""
ADMIN_PASS=""

# =============================================================================
# PARSING DES ARGUMENTS
# Usage: sudo bash install_librenms.sh --db-pass "xxx" --admin-user "yyy" --admin-pass "zzz"
# =============================================================================
usage() {
  echo ""
  echo "Usage : sudo bash $0 --db-pass <mdp_db> --admin-user <user> --admin-pass <mdp_admin>"
  echo ""
  echo "  --db-pass      Mot de passe de l'utilisateur MariaDB 'librenms'"
  echo "  --admin-user   Nom d'utilisateur administrateur LibreNMS"
  echo "  --admin-pass   Mot de passe de l'administrateur LibreNMS"
  echo ""
  echo "Exemple :"
  echo "  sudo bash $0 --db-pass 'P@ssw0rd!' --admin-user 'cpnv' --admin-pass 'Admin2026'"
  echo ""
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db-pass)    DB_PASS="$2";    shift 2 ;;
    --admin-user) ADMIN_USER="$2"; shift 2 ;;
    --admin-pass) ADMIN_PASS="$2"; shift 2 ;;
    --help|-h)    usage ;;
    *) error "Argument inconnu : $1 — utilisez --help pour l'aide." ;;
  esac
done

# Vérification que tous les arguments obligatoires sont fournis
MISSING=0
[ -z "$DB_PASS" ]    && warn "Argument manquant : --db-pass"    && MISSING=1
[ -z "$ADMIN_USER" ] && warn "Argument manquant : --admin-user" && MISSING=1
[ -z "$ADMIN_PASS" ] && warn "Argument manquant : --admin-pass" && MISSING=1
[ "$MISSING" -eq 1 ] && usage

echo ""
echo -e "${GREEN}=== Démarrage de l'installation ===${NC}"
echo -e "  IP détectée : ${BLUE}${APP_URL}${NC}"
echo -e "  Admin       : ${YELLOW}${ADMIN_USER}${NC}"
echo ""
sleep 1

# =============================================================================
# 0. VÉRIFICATION ET MONTAGE DU DATA STORAGE
#    Détection automatique du second disque (sdb, nvme1n1, etc.)
#    Tout /opt/librenms sera sur ce disque via un lien symbolique
# =============================================================================
info "Vérification du data storage (${DATA_DISK})..."

if ! lsblk "${DATA_DISK}" &>/dev/null; then
  error "Le disque ${DATA_DISK} est introuvable. Vérifiez que le data storage est bien connecté."
fi

# Vérifier si le data disk est déjà monté sur /data
if mountpoint -q "${DATA_MOUNT}"; then
  success "${DATA_MOUNT} est déjà monté."
else
  info "${DATA_DISK} non monté, formatage et montage sur ${DATA_MOUNT}..."

  # Vérifier si le disque a déjà une partition/filesystem
  FS_TYPE=$(blkid -o value -s TYPE "${DATA_DISK}" 2>/dev/null || echo "")

  if [ -z "$FS_TYPE" ]; then
    info "Aucun filesystem détecté sur ${DATA_DISK}, création d'un ext4..."
    mkfs.ext4 -F "${DATA_DISK}"
    success "Filesystem ext4 créé sur ${DATA_DISK}."
  else
    info "Filesystem existant détecté sur ${DATA_DISK} : ${FS_TYPE}, on garde."
  fi

  # Création du point de montage et montage
  mkdir -p "${DATA_MOUNT}"
  mount "${DATA_DISK}" "${DATA_MOUNT}"
  success "${DATA_DISK} monté sur ${DATA_MOUNT}."

  # Ajout dans /etc/fstab pour montage automatique au boot
  UUID=$(blkid -o value -s UUID "${DATA_DISK}")
  if ! grep -q "$UUID" /etc/fstab; then
    echo "UUID=${UUID} ${DATA_MOUNT} ext4 defaults 0 2" >> /etc/fstab
    success "Montage ajouté dans /etc/fstab (UUID: ${UUID})."
  fi
fi

# Création du répertoire librenms sur le data storage
mkdir -p "${DATA_MOUNT}/librenms"

# Lien symbolique /opt/librenms -> /data/librenms
if [ -L "${LIBRENMS_DIR}" ]; then
  warn "Le lien symbolique ${LIBRENMS_DIR} existe déjà, on continue."
elif [ -d "${LIBRENMS_DIR}" ]; then
  warn "${LIBRENMS_DIR} existe comme dossier réel, déplacement vers ${DATA_MOUNT}/librenms..."
  mv "${LIBRENMS_DIR}" "${DATA_MOUNT}/librenms"
  ln -s "${DATA_MOUNT}/librenms" "${LIBRENMS_DIR}"
else
  ln -s "${DATA_MOUNT}/librenms" "${LIBRENMS_DIR}"
fi
success "Lien symbolique : ${LIBRENMS_DIR} -> ${DATA_MOUNT}/librenms"

# =============================================================================
# 1. DÉPÔT PHP sury.org + épinglage PHP 8.3
# =============================================================================
info "Ajout du dépôt sury.org pour forcer PHP ${PHP_TARGET}..."
apt-get install -y -q apt-transport-https lsb-release ca-certificates curl gnupg2

curl -sSL https://packages.sury.org/php/apt.gpg \
  | gpg --dearmor -o /usr/share/keyrings/sury-php.gpg

echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" \
  > /etc/apt/sources.list.d/sury-php.list

cat > /etc/apt/preferences.d/pin-php.pref <<'PREF'
Package: php8.4*
Pin: release *
Pin-Priority: -1

Package: php8.3*
Pin: release o=sury.org
Pin-Priority: 900

Package: nginx
Pin: release o=Ubuntu
Pin-Priority: 900
PREF

apt-get update -q
success "Dépôt ajouté, PHP 8.4 bloqué."

# =============================================================================
# 2. INSTALLATION DES PAQUETS
# =============================================================================
info "Installation des paquets (PHP ${PHP_TARGET})..."
apt-get install -y \
  acl curl fping git mariadb-client mariadb-server mtr-tiny nginx nmap \
  php${PHP_TARGET}-cli php${PHP_TARGET}-curl php${PHP_TARGET}-fpm \
  php${PHP_TARGET}-gd php${PHP_TARGET}-gmp php${PHP_TARGET}-mbstring \
  php${PHP_TARGET}-mysql php${PHP_TARGET}-snmp php${PHP_TARGET}-xml \
  php${PHP_TARGET}-zip \
  python3-dotenv python3-pip \
  python3-psutil python3-pymysql python3-redis python3-setuptools \
  python3-systemd rrdtool rrdcached snmp snmpd traceroute unzip whois

# command_runner n'est pas disponible via apt → installation via pip3
info "Installation des modules Python manquants via pip3..."
pip3 install --break-system-packages "command_runner>=1.3.0" 2>/dev/null || \
  pip3 install "command_runner>=1.3.0" 2>/dev/null || \
  warn "Impossible d'installer command_runner via pip3, on continue."

# S'assurer que tous les requirements LibreNMS sont satisfaits (après clone, step 4)
# Cette commande sera ré-exécutée après le clone — voir step 7b ci-dessous
success "Modules Python de base installés."

PHP_VERSION=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;" 2>/dev/null || echo "unknown")
if [ "$PHP_VERSION" != "$PHP_TARGET" ]; then
  update-alternatives --set php /usr/bin/php${PHP_TARGET} 2>/dev/null || true
  PHP_VERSION=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;" 2>/dev/null || echo "unknown")
  [ "$PHP_VERSION" != "$PHP_TARGET" ] && \
    error "PHP ${PHP_TARGET} attendu mais PHP ${PHP_VERSION} actif."
fi
success "Paquets installés — PHP ${PHP_VERSION} confirmé."

# Vérification version nginx (on veut 1.24 depuis Ubuntu 24.04)
NGINX_VERSION=$(nginx -v 2>&1 | grep -oP '[0-9]+\.[0-9]+' | head -1)
info "Nginx version installée : ${NGINX_VERSION}"
# Vérification version Python (on veut 3.12 sur Ubuntu 24.04)
PYTHON_VERSION=$(python3 --version 2>&1 | grep -oP '[0-9]+\.[0-9]+' | head -1)
info "Python version installée : ${PYTHON_VERSION}"

# =============================================================================
# 3. CRÉATION DE L'UTILISATEUR librenms
# =============================================================================
info "Création de l'utilisateur librenms..."
if ! id "librenms" &>/dev/null; then
  useradd librenms -d "$LIBRENMS_DIR" -M -r -s "$(which bash)"
  success "Utilisateur librenms créé."
else
  warn "L'utilisateur librenms existe déjà, on continue."
fi

# =============================================================================
# 4. CLONE DU DÉPÔT LIBRENMS
# =============================================================================
info "Clonage du dépôt LibreNMS..."
cd /opt
if [ ! -d "$LIBRENMS_DIR/.git" ]; then
  git clone https://github.com/librenms/librenms.git
  success "Dépôt cloné."
else
  warn "Le dépôt LibreNMS existe déjà, on passe le clone."
fi

# Chown sur le dossier RÉEL (data disk) et non le lien symbolique
# car chown -R sur un symlink ne propage pas aux fichiers cibles
chown -R librenms:librenms "${DATA_MOUNT}/librenms"
chmod 771 "${DATA_MOUNT}/librenms"

# =============================================================================
# 5. CONFIGURATION MARIADB
#    Fait avant le .env pour s'assurer que la DB existe quand Laravel démarre
# =============================================================================
info "Configuration de MariaDB..."
MARIADB_CONF="/etc/mysql/mariadb.conf.d/50-server.cnf"

if ! grep -q "innodb_file_per_table" "$MARIADB_CONF"; then
  sed -i '/\[mysqld\]/a innodb_file_per_table=1\nlower_case_table_names=0' "$MARIADB_CONF"
fi

systemctl enable mariadb
systemctl restart mariadb

# Chargement des timezones système dans MariaDB
# Nécessaire pour utiliser des noms de timezone (ex: Europe/Zurich) dans MySQL
info "Chargement des timezones système dans MariaDB..."
mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql -u root mysql 2>/dev/null   && success "Timezones chargées."   || warn "Chargement timezones échoué (non bloquant)."

# Configuration du timezone MariaDB = même que PHP (Europe/Zurich)
if ! grep -q "^default-time-zone" "$MARIADB_CONF"; then
  sed -i '/\[mysqld\]/a default-time-zone = Europe\/Zurich' "$MARIADB_CONF"
fi
# Rechargement pour appliquer le timezone (les tables existent maintenant)
systemctl restart mariadb

info "Création de la base de données et de l'utilisateur MariaDB..."
mysql -u root <<SQLEOF
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQLEOF
success "Base de données et utilisateur MariaDB configurés."

# =============================================================================
# 6. CONFIGURATION DU FICHIER .env
#    /!\ Doit être fait AVANT composer install et les migrations
#        pour que Laravel connaisse les credentials DB dès le départ
# =============================================================================
info "Création du fichier .env..."
cat > "$LIBRENMS_DIR/.env" <<DOTENV
APP_URL=${APP_URL}
APP_KEY=

DB_HOST=localhost
DB_DATABASE=${DB_NAME}
DB_USERNAME=${DB_USER}
DB_PASSWORD=${DB_PASS}
DOTENV

chown librenms:librenms "$LIBRENMS_DIR/.env"
chmod 640 "$LIBRENMS_DIR/.env"

success "Fichier .env créé avec les credentials DB (APP_KEY générée après Composer)."

# =============================================================================
# 7. INSTALLATION DES DÉPENDANCES PHP (Composer)
# =============================================================================
info "Installation des dépendances Composer (en tant que librenms)..."
su - librenms -s /bin/bash -c \
  "cd $LIBRENMS_DIR && ./scripts/composer_wrapper.php install --no-dev"
success "Dépendances installées."

# Installation de TOUS les modules Python requis par LibreNMS (requirements.txt)
info "Installation des dépendances Python LibreNMS (requirements.txt)..."
pip3 install --break-system-packages -r "$LIBRENMS_DIR/requirements.txt" 2>/dev/null || \
  pip3 install -r "$LIBRENMS_DIR/requirements.txt" 2>/dev/null || \
  warn "pip3 install requirements.txt a rencontré des erreurs (non bloquant)."
success "Dépendances Python installées."

# Génération de la APP_KEY — DOIT être après Composer (Laravel pas bootstrappable avant)
info "Génération de la APP_KEY Laravel..."
su - librenms -s /bin/bash -c \
  "cd $LIBRENMS_DIR && php artisan key:generate --force"
success "APP_KEY générée."

# =============================================================================
# 8. PERMISSIONS ET ACL (après Composer — les dossiers existent maintenant)
# =============================================================================
info "Application des permissions et ACL..."
mkdir -p \
  "$LIBRENMS_DIR/rrd" \
  "$LIBRENMS_DIR/logs" \
  "$LIBRENMS_DIR/bootstrap/cache" \
  "$LIBRENMS_DIR/storage"

# Chown sur le dossier réel (pas le symlink)
chown -R librenms:librenms "${DATA_MOUNT}/librenms"

setfacl -d -m g::rwx \
  "$LIBRENMS_DIR/rrd" \
  "$LIBRENMS_DIR/logs" \
  "$LIBRENMS_DIR/bootstrap/cache/" \
  "$LIBRENMS_DIR/storage/"
setfacl -R -m g::rwx \
  "$LIBRENMS_DIR/rrd" \
  "$LIBRENMS_DIR/logs" \
  "$LIBRENMS_DIR/bootstrap/cache/" \
  "$LIBRENMS_DIR/storage/"
success "Permissions et ACL appliquées."

# =============================================================================
# 9. CONFIGURATION PHP — fuseau horaire Europe/Zurich
# =============================================================================
info "Configuration du fuseau horaire PHP ($TIMEZONE)..."
for PHP_INI in \
  "/etc/php/${PHP_TARGET}/fpm/php.ini" \
  "/etc/php/${PHP_TARGET}/cli/php.ini"; do
  if [ -f "$PHP_INI" ]; then
    sed -i "s|^;*date\.timezone\s*=.*|date.timezone = $TIMEZONE|" "$PHP_INI"
    success "Fuseau horaire mis à jour dans $PHP_INI"
  else
    warn "$PHP_INI introuvable, ignoré."
  fi
done

timedatectl set-timezone "$TIMEZONE"
success "Timezone système : $TIMEZONE"

# =============================================================================
# 10. CONFIGURATION PHP-FPM
# =============================================================================
info "Configuration de PHP-FPM..."
FPM_POOL_SRC="/etc/php/${PHP_TARGET}/fpm/pool.d/www.conf"
FPM_POOL_DST="/etc/php/${PHP_TARGET}/fpm/pool.d/librenms.conf"

cp "$FPM_POOL_SRC" "$FPM_POOL_DST"
sed -i 's/^\[www\]/[librenms]/'                               "$FPM_POOL_DST"
sed -i 's/^user = .*/user = librenms/'                        "$FPM_POOL_DST"
sed -i 's/^group = .*/group = librenms/'                      "$FPM_POOL_DST"
sed -i 's|^listen = .*|listen = /run/php-fpm-librenms.sock|'  "$FPM_POOL_DST"
success "PHP-FPM configuré."

# =============================================================================
# 11. CONFIGURATION NGINX
# =============================================================================
info "Configuration de Nginx..."
cat > /etc/nginx/conf.d/librenms.conf <<'NGINX_EOF'
server {
    listen      80;
    server_name localhost;
    root        /opt/librenms/html;
    index       index.php;

    charset utf-8;
    gzip on;
    gzip_types text/css application/javascript text/javascript
               application/x-javascript image/svg+xml text/plain
               text/xsd text/xsl text/xml image/x-icon;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ [^/]\.php(/|$) {
        fastcgi_pass unix:/run/php-fpm-librenms.sock;
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        include fastcgi.conf;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
NGINX_EOF

rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default
systemctl restart nginx
systemctl restart "php${PHP_TARGET}-fpm"
success "Nginx et PHP-FPM redémarrés."

# =============================================================================
# 12. COMMANDE lnms + COMPLETION BASH
# =============================================================================
info "Activation de la commande lnms..."
ln -sf "$LIBRENMS_DIR/lnms" /usr/bin/lnms
cp "$LIBRENMS_DIR/misc/lnms-completion.bash" /etc/bash_completion.d/
success "Commande lnms activée."

# =============================================================================
# 13. CONFIGURATION SNMPD (v2c)
# =============================================================================
info "Configuration de SNMP..."
cp "$LIBRENMS_DIR/snmpd.conf.example" /etc/snmp/snmpd.conf
sed -i "s/RANDOMSTRINGGOESHERE/$SNMP_COMMUNITY/" /etc/snmp/snmpd.conf

if ! grep -q "rocommunity $SNMP_COMMUNITY 127.0.0.1" /etc/snmp/snmpd.conf; then
  echo "rocommunity $SNMP_COMMUNITY 127.0.0.1" >> /etc/snmp/snmpd.conf
fi

curl -s -o /usr/bin/distro \
  https://raw.githubusercontent.com/librenms/librenms-agent/master/snmp/distro
chmod +x /usr/bin/distro

systemctl enable snmpd
systemctl restart snmpd
success "SNMPD configuré et démarré."

# =============================================================================
# 14. CRON JOB
# =============================================================================
info "Installation du cron LibreNMS..."
cp "$LIBRENMS_DIR/dist/librenms.cron" /etc/cron.d/librenms
chmod 644 /etc/cron.d/librenms

# Vérification que l'entrée du wrapper Python est bien présente
if ! grep -q "python3.*wrapper" /etc/cron.d/librenms 2>/dev/null; then
  echo "*/5 * * * * librenms /opt/librenms/wrapper.sh /opt/librenms/poller.php -h all >> /dev/null 2>&1" \
    >> /etc/cron.d/librenms
  warn "Entrée wrapper Python ajoutée manuellement dans le cron."
fi

# Redémarrage du service cron pour prise en compte
systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null || true
success "Cron installé."

# =============================================================================
# 15. SCHEDULER SYSTEMD
# =============================================================================
info "Activation du scheduler LibreNMS..."
# Les fichiers dist contiennent /opt/librenms en dur
# On remplace par le chemin réel /data/librenms avant de les copier
sed "s#/opt/librenms#${DATA_MOUNT}/librenms#g"   "$LIBRENMS_DIR/dist/librenms-scheduler.service"   > /etc/systemd/system/librenms-scheduler.service

sed "s#/opt/librenms#${DATA_MOUNT}/librenms#g"   "$LIBRENMS_DIR/dist/librenms-scheduler.timer"   > /etc/systemd/system/librenms-scheduler.timer

systemctl daemon-reload
systemctl enable librenms-scheduler.timer
systemctl start librenms-scheduler.timer

# Vérification que le scheduler est bien actif
if systemctl is-active --quiet librenms-scheduler.timer; then
  success "Scheduler activé."
else
  warn "Le scheduler n'a pas démarré — tentative forcée..."
  systemctl restart librenms-scheduler.timer || true
fi

# =============================================================================
# 16. LOGROTATE
# =============================================================================
info "Configuration de logrotate..."
cp "$LIBRENMS_DIR/misc/librenms.logrotate" /etc/logrotate.d/librenms
success "Logrotate configuré."

# =============================================================================
# 17. CONFIGURATION RRDCACHED
# =============================================================================
info "Configuration de rrdcached..."
mkdir -p /var/lib/rrdcached/journal/
chown -R librenms:librenms /var/lib/rrdcached/

# Détection du nom du service rrdcached
if systemctl list-unit-files | grep -q "^rrdcached.service"; then
  RRDC_SERVICE="rrdcached"
else
  warn "Service rrdcached non trouvé, création d'un unit systemd custom..."
  cat > /etc/systemd/system/rrdcached.service <<'UNIT_EOF'
[Unit]
Description=RRDtool Cache Daemon
After=network.target

[Service]
Type=forking
User=librenms
Group=librenms
PIDFile=/run/rrdcached.pid
ExecStart=/usr/bin/rrdcached \
  -F \
  -b ${DATA_MOUNT}/librenms/rrd/ \
  -B \
  -j /var/lib/rrdcached/journal/ \
  -l unix:/run/rrdcached.sock \
  -s librenms \
  -m 0660 \
  -t 4 \
  -w 1800 \
  -z 1800 \
  -p /run/rrdcached.pid
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT_EOF
  systemctl daemon-reload
  RRDC_SERVICE="rrdcached"
fi

cat > /etc/default/rrdcached <<'RRDC_EOF'
DAEMON=/usr/bin/rrdcached
DAEMON_USER=librenms
DAEMON_GROUP=librenms
WRITE_TIMEOUT=1800
WRITE_JITTER=1800
BASE_PATH=${DATA_MOUNT}/librenms/rrd/
JOURNAL_PATH=/var/lib/rrdcached/journal/
SOCKFILE=/run/rrdcached.sock
SOCKGROUP=librenms
OPTIONS="-F -b $BASE_PATH -B"
RRDC_EOF

systemctl enable "$RRDC_SERVICE"
systemctl restart "$RRDC_SERVICE"

# Attente que le socket soit créé avant de continuer
info "Attente création du socket rrdcached..."
SOCK_OK=0
for i in $(seq 1 15); do
  if [ -S "/run/rrdcached.sock" ]; then
    SOCK_OK=1
    break
  fi
  sleep 2
done

if [ "$SOCK_OK" -eq 1 ]; then
  success "Socket /run/rrdcached.sock disponible."
else
  # Le service système lit /etc/default/rrdcached mais parfois ignore SOCKFILE
  # On relance avec les options explicites via un override systemd
  warn "Socket non créé, création d'un override systemd pour forcer les options..."
  mkdir -p /etc/systemd/system/rrdcached.service.d/
  cat > /etc/systemd/system/rrdcached.service.d/override.conf <<OVERRIDE_EOF
[Service]
ExecStart=
ExecStart=/usr/bin/rrdcached -F -b ${DATA_MOUNT}/librenms/rrd/ -B -j /var/lib/rrdcached/journal/ -l unix:/run/rrdcached.sock -s librenms -m 0660 -t 4 -w 1800 -z 1800
User=librenms
Group=librenms
OVERRIDE_EOF
  systemctl daemon-reload
  systemctl restart "$RRDC_SERVICE"

  # Nouvelle attente
  for i in $(seq 1 15); do
    if [ -S "/run/rrdcached.sock" ]; then
      SOCK_OK=1
      break
    fi
    sleep 2
  done
  [ "$SOCK_OK" -eq 1 ]     && success "Socket /run/rrdcached.sock disponible après override."     || warn "Socket toujours absent — vérifiez journalctl -u rrdcached"
fi
success "rrdcached configuré et démarré (service : $RRDC_SERVICE)."

# =============================================================================
# 18. MIGRATIONS DB
# =============================================================================
info "Exécution des migrations de la base de données..."
su - librenms -s /bin/bash -c \
  "cd $LIBRENMS_DIR && php artisan migrate --force --no-interaction"
success "Migrations effectuées."

# =============================================================================
# 19. CRÉATION DE L'ADMIN LIBRENMS
# =============================================================================
info "Création de l'administrateur LibreNMS (${ADMIN_USER})..."
# Génération du hash bcrypt du mot de passe via PHP
ADMIN_HASH=$(php -r "echo password_hash('${ADMIN_PASS}', PASSWORD_BCRYPT);" 2>/dev/null)

# Insertion de l'utilisateur en SQL + assignation du rôle admin (role_id=1)
# Le schéma actuel de LibreNMS n'a plus de colonne 'level' — les rôles sont dans model_has_roles
mysql -u root <<SQLADMIN
USE ${DB_NAME};

-- Insertion ou mise à jour de l'utilisateur
INSERT INTO users (username, password, realname, email, descr, can_modify_passwd, auth_type, created_at, updated_at, enabled)
VALUES ('${ADMIN_USER}', '${ADMIN_HASH}', '${ADMIN_USER}', '${ADMIN_USER}@localhost', '', 1, 'mysql', NOW(), NOW(), 1)
ON DUPLICATE KEY UPDATE
  password = '${ADMIN_HASH}',
  updated_at = NOW(),
  enabled = 1;

-- Récupération de l'user_id et assignation du rôle admin (id=1)
SET @uid = (SELECT user_id FROM users WHERE username='${ADMIN_USER}');
INSERT IGNORE INTO model_has_roles (role_id, model_type, model_id)
VALUES (1, 'App\\\\Models\\\\User', @uid);
SQLADMIN

success "Administrateur ${ADMIN_USER} créé avec le rôle admin."

# =============================================================================
# 20. APP_URL DANS .env + vidage du cache
# =============================================================================
info "Mise à jour de APP_URL (${APP_URL}) et vidage du cache..."
sed -i "s|^APP_URL=.*|APP_URL=${APP_URL}|" "$LIBRENMS_DIR/.env"
su - librenms -s /bin/bash -c \
  "cd $LIBRENMS_DIR && php lnms config:cache" 2>/dev/null || true
success "APP_URL défini à ${APP_URL}"

# =============================================================================
# 21. SOCKET RRDCACHED DANS LIBRENMS
# =============================================================================
info "Configuration du socket rrdcached dans LibreNMS..."
su - librenms -s /bin/bash -c \
  "lnms config:set rrdcached 'unix:/run/rrdcached.sock'" 2>/dev/null || true

# S'assurer que le chemin rrd dans LibreNMS pointe vers le chemin réel
su - librenms -s /bin/bash -c \
  "lnms config:set rrd_dir '${DATA_MOUNT}/librenms/rrd'" 2>/dev/null || true
success "Socket rrdcached configuré."

# =============================================================================
# 22. AJOUT DE LA MACHINE LOCALE COMME DEVICE ET PREMIÈRE COLLECTE
#     - Attente que snmpd soit prêt
#     - Ajout 127.0.0.1 en SNMPv2c community public
#     - Découverte initiale (interfaces, OS, capteurs)
#     - Premier poll forcé (génère les RRD pour les graphiques)
# =============================================================================
info "Ajout de la machine locale comme device LibreNMS..."

# Attente que snmpd réponde (OID numérique, pas besoin des MIBs)
SNMP_OK=0
for i in $(seq 1 15); do
  if snmpget -v2c -c "${SNMP_COMMUNITY}" -r 1 -t 3 127.0.0.1 1.3.6.1.2.1.1.5.0 &>/dev/null; then
    SNMP_OK=1
    break
  fi
  warn "Attente snmpd... tentative $i/15"
  sleep 3
done

if [ "$SNMP_OK" -eq 0 ]; then
  warn "snmpd ne répond pas après 45s — device non ajouté automatiquement."
else
  success "snmpd répond, ajout du device..."

  # Ajout du device (lnms refuse de tourner en root, on passe par librenms)
  su - librenms -s /bin/bash -c     "lnms device:add 127.0.0.1 --v2c --community '${SNMP_COMMUNITY}' --force"     && success "Device 127.0.0.1 ajouté."     || warn "Device déjà présent ou erreur à l'ajout, on continue."

  # Récupération de l'ID du device
  DEVICE_ID=$(mysql -u root "${DB_NAME}" -sNe     "SELECT device_id FROM devices WHERE hostname='127.0.0.1' LIMIT 1;" 2>/dev/null)

  if [ -z "$DEVICE_ID" ]; then
    warn "Impossible de récupérer l'ID du device."
  else
    info "Device ID : ${DEVICE_ID}"

    # Découverte initiale — détecte interfaces, OS, ports, capteurs
    info "Lancement de la découverte initiale..."
    su - librenms -s /bin/bash -c       "php /opt/librenms/discovery.php -h 127.0.0.1 2>&1 | tail -5"       && success "Découverte terminée."       || warn "Découverte échouée, elle se relancera via cron."

    # Premier poll forcé — génère les fichiers RRD pour les graphiques
    info "Lancement du premier poll (génération des graphiques)..."
    su - librenms -s /bin/bash -c       "php /opt/librenms/poller.php -h 127.0.0.1 2>&1 | tail -5"       && success "Premier poll terminé — graphiques disponibles."       || warn "Poll échoué, il se relancera via cron dans 5 minutes."
  fi
fi

# =============================================================================
# FIN
# =============================================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  Installation de LibreNMS terminée avec succès !${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "  URL d'accès     : ${BLUE}${APP_URL}${NC}"
echo -e "  Admin LibreNMS  : ${YELLOW}${ADMIN_USER}${NC}"
echo -e "  Utilisateur DB  : ${YELLOW}${DB_USER}${NC}"
echo -e "  SNMP community  : ${YELLOW}${SNMP_COMMUNITY}${NC}"
echo ""
