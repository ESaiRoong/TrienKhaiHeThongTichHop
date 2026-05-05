#!/bin/bash

# ===== CONFIG =====
DB_NAME="wordpress"
DB_USER="wpuser"
DB_PASS="StrongPass123!"

WEB_ROOT="/usr/local/lsws/Example/html"

# ===== UPDATE =====
apt update -y && apt upgrade -y

# ===== INSTALL =====
apt install -y wget curl unzip software-properties-common

# ===== INSTALL MariaDB =====
apt install -y mariadb-server
systemctl start mariadb
systemctl enable mariadb

# ===== AUTO CONFIG DB =====
mysql <<EOF
CREATE DATABASE $DB_NAME;
CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

# ===== INSTALL OpenLiteSpeed =====
wget -O - https://repo.litespeed.sh | bash
apt install -y openlitespeed

# ===== INSTALL PHP =====
apt install -y lsphp81 lsphp81-mysql lsphp81-common lsphp81-curl lsphp81-opcache

# ===== LINK PHP =====
ln -sf /usr/local/lsws/lsphp81/bin/lsphp /usr/local/lsws/fcgi-bin/lsphp5

# ===== START OLS =====
systemctl start lsws
systemctl enable lsws

# ===== DOWNLOAD WORDPRESS =====
cd /tmp
wget https://wordpress.org/latest.zip
unzip latest.zip

# ===== DEPLOY =====
rm -rf $WEB_ROOT/*
cp -r wordpress/* $WEB_ROOT/

# ===== PERMISSION =====
chown -R nobody:nogroup $WEB_ROOT
chmod -R 755 $WEB_ROOT

# ===== CONFIG WORDPRESS =====
cp $WEB_ROOT/wp-config-sample.php $WEB_ROOT/wp-config.php

sed -i "s/database_name_here/$DB_NAME/" $WEB_ROOT/wp-config.php
sed -i "s/username_here/$DB_USER/" $WEB_ROOT/wp-config.php
sed -i "s/password_here/$DB_PASS/" $WEB_ROOT/wp-config.php
sed -i "s/localhost/localhost/" $WEB_ROOT/wp-config.php

# ===== FIREWALL =====
ufw allow 80
ufw allow 443
ufw allow 7080

# ===== RESTART =====
systemctl restart lsws

echo "=============================="
echo "DONE!"
echo "Web: http://IP-server"
echo "Admin OLS: http://IP-server:7080"
echo "DB User: $DB_USER"
echo "DB Pass: $DB_PASS"
echo "=============================="
