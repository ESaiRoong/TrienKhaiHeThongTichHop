#!/bin/bash
# ============================================================
#  Script mount NFS cho Web02 (Moodle)
#  Web02: 10.10.40.152
#  NFS Server: 10.10.40.153
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()   { echo -e "${GREEN}[OK]${NC}   $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERR]${NC}  $1"; exit 1; }
title() { echo -e "\n${BLUE}${BOLD}==> $1${NC}"; }

[[ $EUID -ne 0 ]] && error "Cần quyền root: sudo bash $0"

# =============================================
NFS_SERVER="10.10.40.164"
NFS_EXPORT="/srv/nfs/moodle"       # Thư mục riêng cho Moodle trên NFS
LOCAL_MOUNT="/var/www/html/moodle"
WEB02_IP="10.10.40.163"
# =============================================

title "Bước 1: Cài NFS client"
apt update -y && apt install -y nfs-common
log "Cài xong"

title "Bước 2: Kiểm tra NFS server"
if showmount -e "$NFS_SERVER" &>/dev/null; then
    log "Kết nối NFS server ${NFS_SERVER} OK"
    log "Danh sách export:"
    showmount -e "$NFS_SERVER"
else
    error "Không kết nối được NFS server ${NFS_SERVER}"
fi

title "Bước 3: Thêm export Moodle trên NFS server (nếu chưa có)"
# Kiểm tra NFS server đã export thư mục moodle chưa
if showmount -e "$NFS_SERVER" | grep -q "moodle"; then
    log "NFS server đã export thư mục moodle"
else
    warn "NFS server chưa export thư mục moodle"
    echo ""
    echo "  Chạy các lệnh sau trên máy NFS server (${NFS_SERVER}):"
    echo "  -----------------------------------------------"
    echo "  mkdir -p /srv/nfs/moodle"
    echo "  chown nobody:nogroup /srv/nfs/moodle"
    echo "  chmod 777 /srv/nfs/moodle"
    echo "  echo \"/srv/nfs/moodle  ${WEB02_IP}(rw,sync,no_subtree_check,no_root_squash)\" >> /etc/exports"
    echo "  exportfs -ra"
    echo "  -----------------------------------------------"
    echo ""
    read -p "Đã thêm export xong? Nhấn Enter để tiếp tục..."
fi

title "Bước 4: Backup thư mục Moodle hiện tại (nếu có)"
if [ -d "$LOCAL_MOUNT" ] && [ "$(ls -A $LOCAL_MOUNT 2>/dev/null)" ]; then
    BACKUP="/root/moodle_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    tar -czf "$BACKUP" "$LOCAL_MOUNT" 2>/dev/null
    log "Đã backup: $BACKUP"
else
    log "Thư mục trống, không cần backup"
fi

title "Bước 5: Unmount nếu đang mount"
mountpoint -q "$LOCAL_MOUNT" && umount "$LOCAL_MOUNT" && log "Đã unmount cũ"

title "Bước 6: Tạo thư mục và mount NFS"
mkdir -p "$LOCAL_MOUNT"
mount -t nfs -o rw,sync,hard,intr \
    "${NFS_SERVER}:${NFS_EXPORT}" "$LOCAL_MOUNT"

if mountpoint -q "$LOCAL_MOUNT"; then
    log "Mount thành công: ${NFS_SERVER}:${NFS_EXPORT} → ${LOCAL_MOUNT}"
else
    error "Mount thất bại! Kiểm tra lại NFS server"
fi

title "Bước 7: Thêm vào /etc/fstab (tự mount sau reboot)"
FSTAB_LINE="${NFS_SERVER}:${NFS_EXPORT}  ${LOCAL_MOUNT}  nfs  rw,sync,hard,intr,_netdev  0  0"
if grep -q "${NFS_SERVER}:${NFS_EXPORT}" /etc/fstab; then
    warn "Đã có trong /etc/fstab rồi"
else
    echo "$FSTAB_LINE" >> /etc/fstab
    log "Đã thêm vào /etc/fstab"
fi

mount -a 2>/dev/null && log "fstab hợp lệ" || warn "Kiểm tra lại /etc/fstab"

title "Bước 8: Phân quyền"
chown -R www-data:www-data "$LOCAL_MOUNT"
find "$LOCAL_MOUNT" -type d -exec chmod 755 {} \;
find "$LOCAL_MOUNT" -type f -exec chmod 644 {} \;
log "Phân quyền xong"

title "Bước 9: Test ghi/đọc"
TEST="${LOCAL_MOUNT}/.test_$(date +%s)"
if touch "$TEST" 2>/dev/null; then
    rm -f "$TEST"
    log "Ghi/đọc NFS bình thường"
else
    warn "NFS có thể read-only — kiểm tra /etc/exports trên server"
fi

echo ""
echo "========================================================"
echo "  MOUNT NFS WEB02 XONG!"
echo "========================================================"
echo "  NFS   : ${NFS_SERVER}:${NFS_EXPORT}"
echo "  Mount : ${LOCAL_MOUNT}"
echo ""
echo "  Kiểm tra:"
echo "  df -h | grep nfs"
echo "  mount | grep nfs"
echo "========================================================"
