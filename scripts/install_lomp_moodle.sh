#!/bin/bash
# ============================================================
#  Script cài đặt LOMP Stack + Moodle
#  Web02: 10.10.40.151 (Ubuntu 22.04)
#  Database: Remote MariaDB 10.10.40.153
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()   { echo -e "${GREEN}[OK]${NC}   $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERR]${NC}  $1"; exit 1; }
title() { echo -e "\n${BLUE}${BOLD}==> $1${NC}"; }

[[ $EUID -ne 0 ]] && error "Cần chạy với quyền root: sudo bash $0"

# =============================================
#  CẤU HÌNH
# =============================================
WEB02_IP="10.10.40.151"
DB_HOST="10.10.40.153"
DB_NAME="moodle"
DB_USER="moodleuser"
DB_PASS="Moodle@123"
MOODLE_DIR="/var/www/html/moodle"
MOODLE_DATA="/var/moodledata"
PHP_VER="81"                       # 81 = PHP 8.1 cho OLS
OLS_ADMIN_PASS="Admin@123"
# =============================================

title "Bước 1: Cập nhật hệ thống"
apt update -y && apt upgrade -y
log "Cập nhật xong"

title "Bước 2: Cài OpenLiteSpeed"
wget -qO - https://repo.litespeed.sh | bash
apt update -y
apt install -y openlitespeed
log "Cài OpenLiteSpeed xong"

# Đặt mật khẩu WebAdmin
echo -e "admin\n${OLS_ADMIN_PASS}\n${OLS_ADMIN_PASS}" | \
    /usr/local/lsws/admin/misc/admpass.sh &>/dev/null
log "WebAdmin: admin / ${OLS_ADMIN_PASS}"

title "Bước 3: Cài PHP 8.1 cho OpenLiteSpeed"
apt install -y \
    lsphp${PHP_VER} \
    lsphp${PHP_VER}-common \
    lsphp${PHP_VER}-mysql \
    lsphp${PHP_VER}-curl \
    lsphp${PHP_VER}-xml \
    lsphp${PHP_VER}-mbstring \
    lsphp${PHP_VER}-zip \
    lsphp${PHP_VER}-gd \
    lsphp${PHP_VER}-intl \
    lsphp${PHP_VER}-soap \
    lsphp${PHP_VER}-opcache

ln -sf /usr/local/lsws/lsphp${PHP_VER}/bin/php /usr/bin/php
log "PHP: $(php -v | head -1)"

title "Bước 4: Cấu hình PHP cho Moodle"
PHP_INI="/usr/local/lsws/lsphp${PHP_VER}/etc/php/8.1/litespeed/php.ini"
sed -i 's/^max_execution_time.*/max_execution_time = 300/'       "$PHP_INI"
sed -i 's/^memory_limit.*/memory_limit = 256M/'                  "$PHP_INI"
sed -i 's/^post_max_size.*/post_max_size = 100M/'                "$PHP_INI"
sed -i 's/^upload_max_filesize.*/upload_max_filesize = 100M/'    "$PHP_INI"
sed -i 's|^;date.timezone.*|date.timezone = Asia/Ho_Chi_Minh|'  "$PHP_INI"
log "Cấu hình PHP xong"

title "Bước 5: Kiểm tra kết nối Database"
apt install -y mariadb-client
if mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "SELECT 1;" &>/dev/null; then
    log "Kết nối DB OK: ${DB_HOST}"
else
    warn "Chưa kết nối được DB!"
    echo ""
    echo "  Chạy các lệnh sau trên máy DB (${DB_HOST}):"
    echo "  -----------------------------------------------"
    echo "  mysql -u root -p"
    echo "  CREATE DATABASE ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    echo "  CREATE USER '${DB_USER}'@'${WEB02_IP}' IDENTIFIED BY '${DB_PASS}';"
    echo "  GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'${WEB02_IP}';"
    echo "  FLUSH PRIVILEGES;"
    echo "  EXIT;"
    echo "  -----------------------------------------------"
    echo ""
    read -p "Đã tạo DB xong? Nhấn Enter để tiếp tục..."
fi

title "Bước 6: Tải Moodle"
apt install -y git curl unzip
cd /var/www/html
git clone -b MOODLE_403_STABLE --depth 1 \
    https://github.com/moodle/moodle.git moodle
log "Tải Moodle xong"

mkdir -p "$MOODLE_DATA"
chown -R www-data:www-data "$MOODLE_DIR" "$MOODLE_DATA"
chmod -R 755 "$MOODLE_DIR"
chmod -R 777 "$MOODLE_DATA"
log "Thư mục web: $MOODLE_DIR"
log "Thư mục data: $MOODLE_DATA"

title "Bước 7: Cấu hình Virtual Host OpenLiteSpeed"
VHOST_DIR="/usr/local/lsws/conf/vhosts/moodle"
mkdir -p "${VHOST_DIR}/conf" "${VHOST_DIR}/logs"

cat > "${VHOST_DIR}/conf/vhconf.conf" << 'VHCONF'
docRoot                   /var/www/html/moodle
enableGzip                1

index {
  useServer               0
  indexFiles              index.php, index.html
  autoIndex               0
}

scripthandler {
  add lsapi:lsphp81 php
}

rewrite {
  enable                  1
  autoLoadHtaccess        1
}

context / {
  type                    NULL
  location                /var/www/html/moodle
  allowBrowse             1
  rewrite {
    enable                1
    rules                 <<<END_RULES
RewriteEngine On
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule ^(.*)$ /index.php [QSA,L]
END_RULES
  }
}
VHCONF

log "Virtual Host config OK"

# Thêm vhost vào httpd_config.conf
OLS_CONF="/usr/local/lsws/conf/httpd_config.conf"
cp "$OLS_CONF" "${OLS_CONF}.bak"

cat >> "$OLS_CONF" << OLSCONF

virtualhost moodle {
  vhRoot                  ${VHOST_DIR}
  configFile              ${VHOST_DIR}/conf/vhconf.conf
  allowSymbolLink         1
  enableScript            1
  restrained              0
}
OLSCONF
log "Đã thêm vhost vào OLS config"

title "Bước 8: Mở firewall"
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 7080/tcp
log "Đã mở port 80, 443, 7080"

title "Bước 9: Khởi động OpenLiteSpeed"
systemctl enable lsws
systemctl restart lsws
systemctl is-active --quiet lsws \
    && log "OpenLiteSpeed đang chạy" \
    || error "OpenLiteSpeed không khởi động được"

title "Bước 10: Cài Moodle qua CLI"
php "${MOODLE_DIR}/admin/cli/install.php" \
    --lang=vi \
    --wwwroot="http://${WEB02_IP}/moodle" \
    --dataroot="${MOODLE_DATA}" \
    --dbtype=mariadb \
    --dbhost="${DB_HOST}" \
    --dbname="${DB_NAME}" \
    --dbuser="${DB_USER}" \
    --dbpass="${DB_PASS}" \
    --dbport=3306 \
    --prefix=mdl_ \
    --fullname="Moodle Nhom 05" \
    --shortname="nhom05" \
    --adminuser=admin \
    --adminpass="Admin@Moodle123" \
    --adminemail="admin@nhom05.local" \
    --non-interactive \
    --agree-license

if [ $? -eq 0 ]; then
    log "Cài Moodle CLI thành công!"
else
    warn "Cài CLI chưa xong — vào web để hoàn tất: http://${WEB02_IP}/moodle"
fi

chown -R www-data:www-data "$MOODLE_DIR" "$MOODLE_DATA"

title "Bước 11: Lập lịch Moodle Cron"
CRON_JOB="*/1 * * * * www-data /usr/bin/php ${MOODLE_DIR}/admin/cli/cron.php > /dev/null 2>&1"
echo "$CRON_JOB" > /etc/cron.d/moodle
log "Đã thêm cron job Moodle"

echo ""
echo "========================================================"
echo "  HOÀN TẤT!"
echo "========================================================"
echo "  Moodle        : http://${WEB02_IP}/moodle"
echo "  Admin         : admin / Admin@Moodle123"
echo "  OLS WebAdmin  : https://${WEB02_IP}:7080"
echo "  OLS Admin     : admin / ${OLS_ADMIN_PASS}"
echo "  Database      : ${DB_NAME} @ ${DB_HOST}"
echo "  Moodledata    : ${MOODLE_DATA}"
echo "========================================================"
