#!/bin/bash
# Chạy trên máy NFS+DB: 10.10.40.153
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()   { echo -e "${GREEN}[OK]${NC}   $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERR]${NC}  $1"; exit 1; }
title() { echo -e "\n${BLUE}${BOLD}==> $1${NC}"; }
[[ $EUID -ne 0 ]] && error "Cần quyền root"

NFS_EXPORT="/srv/nfs/wordpress"
WEB01_IP="10.10.40.151"
WEB02_IP="10.10.40.152"

title "Bước 1: Cài NFS Server"
if [ -f /etc/debian_version ]; then
    apt update -y && apt install -y nfs-kernel-server nfs-common
else
    dnf install -y nfs-utils && systemctl enable --now rpcbind
fi
log "Cài xong"

title "Bước 2: Tạo thư mục và cài WordPress"
mkdir -p "$NFS_EXPORT"
chown nobody:nogroup "$NFS_EXPORT"
chmod 777 "$NFS_EXPORT"

if [ ! -f "${NFS_EXPORT}/wp-login.php" ]; then
    cd /tmp
    curl -sO https://wordpress.org/latest.tar.gz
    tar -xzf latest.tar.gz
    cp -r wordpress/. "$NFS_EXPORT/"
    chown -R nobody:nogroup "$NFS_EXPORT"
    chmod -R 755 "$NFS_EXPORT"
    log "WordPress đã copy vào ${NFS_EXPORT}"
else
    log "WordPress đã có sẵn"
fi

title "Bước 3: Cấu hình /etc/exports"
cp /etc/exports /etc/exports.bak 2>/dev/null
sed -i "\|${NFS_EXPORT}|d" /etc/exports
cat >> /etc/exports << EXPORTS
${NFS_EXPORT}  ${WEB01_IP}(rw,sync,no_subtree_check,no_root_squash)
${NFS_EXPORT}  ${WEB02_IP}(rw,sync,no_subtree_check,no_root_squash)
EXPORTS
log "exports:"
cat /etc/exports | grep -v "^#" | grep -v "^$"

title "Bước 4: Khởi động NFS"
exportfs -ra && exportfs -v
if [ -f /etc/debian_version ]; then
    systemctl enable nfs-kernel-server && systemctl restart nfs-kernel-server
    systemctl is-active --quiet nfs-kernel-server && log "NFS đang chạy" || error "NFS lỗi"
else
    systemctl enable --now nfs-server && systemctl restart nfs-server
    systemctl is-active --quiet nfs-server && log "NFS đang chạy" || error "NFS lỗi"
fi

title "Bước 5: Mở firewall"
if command -v ufw &>/dev/null && ufw status | grep -q active; then
    ufw allow from "$WEB01_IP" to any port 2049
    ufw allow from "$WEB02_IP" to any port 2049
    log "UFW đã mở port NFS"
elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-service=nfs
    firewall-cmd --permanent --add-service=rpcbind
    firewall-cmd --reload
    log "firewalld đã mở NFS"
fi

echo ""
echo "========================================================"
echo "  NFS SERVER XONG!"
echo "  Export : ${NFS_EXPORT}"
echo "  Cho    : ${WEB01_IP} và ${WEB02_IP}"
echo "  Test   : showmount -e localhost"
echo "========================================================"
