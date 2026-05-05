#!/bin/bash
# ============================================================
#  Script thêm export Moodle trên NFS Server
#  NFS Server: 10.10.40.153
#  Dành cho Web02 (Moodle): 10.10.40.152
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()   { echo -e "${GREEN}[OK]${NC}   $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERR]${NC}  $1"; exit 1; }
title() { echo -e "\n${BLUE}${BOLD}==> $1${NC}"; }

[[ $EUID -ne 0 ]] && error "Cần quyền root: sudo bash $0"

# =============================================
NFS_MOODLE="/srv/nfs/moodle"
NFS_WORDPRESS="/srv/nfs/wordpress"
WEB01_IP="10.10.40.162"
WEB02_IP="10.10.40.163"
# =============================================

title "Bước 1: Kiểm tra NFS server đã cài chưa"
if ! command -v exportfs &>/dev/null; then
    log "Chưa cài NFS server, đang cài..."
    if [ -f /etc/debian_version ]; then
        apt update -y && apt install -y nfs-kernel-server nfs-common
    else
        dnf install -y nfs-utils && systemctl enable --now rpcbind
    fi
    log "Cài NFS server xong"
else
    log "NFS server đã có sẵn"
fi

title "Bước 2: Tạo thư mục export cho Moodle"
mkdir -p "$NFS_MOODLE"
chown nobody:nogroup "$NFS_MOODLE"
chmod 777 "$NFS_MOODLE"
log "Thư mục: $NFS_MOODLE"

title "Bước 3: Cấu hình /etc/exports"
# Backup
cp /etc/exports /etc/exports.bak

# Xoá entry cũ nếu có
sed -i "\|${NFS_MOODLE}|d" /etc/exports

# Thêm export mới cho Moodle
echo "${NFS_MOODLE}  ${WEB02_IP}(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
log "Đã thêm export Moodle cho ${WEB02_IP}"

# Hiển thị toàn bộ exports hiện tại
echo ""
echo "  /etc/exports hiện tại:"
cat /etc/exports | grep -v "^#" | grep -v "^$"
echo ""

title "Bước 4: Apply export"
exportfs -ra
exportfs -v
log "Export apply xong"

title "Bước 5: Restart NFS server"
if [ -f /etc/debian_version ]; then
    systemctl restart nfs-kernel-server
    systemctl is-active --quiet nfs-kernel-server \
        && log "NFS server đang chạy" \
        || error "NFS server lỗi"
else
    systemctl restart nfs-server
    systemctl is-active --quiet nfs-server \
        && log "NFS server đang chạy" \
        || error "NFS server lỗi"
fi

title "Bước 6: Mở firewall cho Web02"
if command -v ufw &>/dev/null && ufw status | grep -q active; then
    ufw allow from "$WEB02_IP" to any port 2049
    ufw reload
    log "UFW đã mở port NFS cho ${WEB02_IP}"
elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=${WEB02_IP} port port=2049 protocol=tcp accept"
    firewall-cmd --reload
    log "firewalld đã mở NFS cho ${WEB02_IP}"
fi

title "Bước 7: Kiểm tra"
echo ""
echo "  Danh sách export:"
showmount -e localhost
echo ""

echo "========================================================"
echo "  NFS SERVER SETUP XONG!"
echo "========================================================"
echo "  WordPress export : ${NFS_WORDPRESS} → ${WEB01_IP}"
echo "  Moodle export    : ${NFS_MOODLE}    → ${WEB02_IP}"
echo ""
echo "  Tiếp theo: Chạy mount_nfs_web02.sh trên Web02 (${WEB02_IP})"
echo "========================================================"
