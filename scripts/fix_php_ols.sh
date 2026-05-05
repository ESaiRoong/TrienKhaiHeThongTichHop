#!/bin/bash
# ============================================================
#  Fix lỗi PHP 8.1 cho OpenLiteSpeed
#  Chạy trên Web02 (10.10.40.152) Ubuntu 22.04
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()   { echo -e "${GREEN}[OK]${NC}   $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERR]${NC}  $1"; exit 1; }
title() { echo -e "\n${BLUE}${BOLD}==> $1${NC}"; }

[[ $EUID -ne 0 ]] && error "Cần quyền root"

title "Bước 1: Thêm repo OpenLiteSpeed đúng cách"
# Xoá repo cũ nếu có lỗi
rm -f /etc/apt/sources.list.d/ols.list 2>/dev/null

# Thêm repo chính thức OpenLiteSpeed
wget -O /usr/share/keyrings/lst_repo.gpg \
    https://repo.litespeed.sh/lst_repo.gpg 2>/dev/null \
    || curl -fsSL https://repo.litespeed.sh/lst_repo.gpg \
    -o /usr/share/keyrings/lst_repo.gpg

echo "deb [signed-by=/usr/share/keyrings/lst_repo.gpg] \
http://rpms.litespeedtech.com/debian/ jammy main" \
    > /etc/apt/sources.list.d/ols.list

apt update -y
log "Repo OpenLiteSpeed OK"

title "Bước 2: Kiểm tra PHP versions có sẵn"
apt-cache search lsphp | grep "^lsphp" | awk '{print $1}' | head -20
echo ""

title "Bước 3: Cài PHP 8.1 từ repo đúng"
apt install -y \
    lsphp81 \
    lsphp81-common \
    lsphp81-mysql \
    lsphp81-curl \
    lsphp81-imap \
    lsphp81-intl \
    lsphp81-opcache

# Một số package tên khác trong repo OLS
apt install -y lsphp81-dev 2>/dev/null || true

log "Cài lsphp81 core xong"

title "Bước 4: Cài thêm extension qua PHP PECL / apt thường"
# Cài php8.1 thường để lấy extension, rồi link sang OLS
add-apt-repository -y ppa:ondrej/php 2>/dev/null || true
apt update -y

apt install -y \
    php8.1-gd \
    php8.1-xml \
    php8.1-mbstring \
    php8.1-zip \
    php8.1-soap \
    php8.1-xmlrpc \
    php8.1-intl 2>/dev/null || true

log "Cài PHP 8.1 extensions xong"

title "Bước 5: Tạo symlink PHP"
# Tìm đường dẫn PHP OLS
PHP_BIN=$(find /usr/local/lsws -name "php" -type f 2>/dev/null | head -1)
if [ -n "$PHP_BIN" ]; then
    ln -sf "$PHP_BIN" /usr/bin/php
    log "PHP binary: $PHP_BIN"
    php -v
else
    # Dùng PHP thường nếu OLS PHP không tìm thấy
    ln -sf /usr/bin/php8.1 /usr/bin/php 2>/dev/null
    log "Dùng PHP thường: $(php -v | head -1)"
fi

title "Bước 6: Tìm php.ini đúng và cấu hình"
# Tìm tất cả php.ini của OLS
PHP_INI=$(find /usr/local/lsws -name "php.ini" 2>/dev/null | head -1)

if [ -n "$PHP_INI" ]; then
    log "Tìm thấy php.ini: $PHP_INI"
else
    # Dùng php.ini thường
    PHP_INI="/etc/php/8.1/cli/php.ini"
    warn "Dùng php.ini thường: $PHP_INI"
fi

# Cấu hình php.ini
sed -i 's/^max_execution_time.*/max_execution_time = 300/'       "$PHP_INI" 2>/dev/null
sed -i 's/^memory_limit.*/memory_limit = 256M/'                  "$PHP_INI" 2>/dev/null
sed -i 's/^post_max_size.*/post_max_size = 100M/'                "$PHP_INI" 2>/dev/null
sed -i 's/^upload_max_filesize.*/upload_max_filesize = 100M/'    "$PHP_INI" 2>/dev/null
sed -i 's|^;date.timezone.*|date.timezone = Asia/Ho_Chi_Minh|'  "$PHP_INI" 2>/dev/null
log "Cấu hình php.ini tại: $PHP_INI"

title "Bước 7: Restart OpenLiteSpeed"
systemctl restart lsws
systemctl is-active --quiet lsws \
    && log "OpenLiteSpeed đang chạy" \
    || warn "OLS chưa chạy — kiểm tra: systemctl status lsws"

title "Kết quả"
echo ""
echo "  PHP version: $(php -v 2>/dev/null | head -1)"
echo "  PHP modules: $(php -m 2>/dev/null | tr '\n' ' ' | head -c 200)"
echo ""
echo "  Kiểm tra OLS: https://$(hostname -I | awk '{print $1}'):7080"
echo ""
