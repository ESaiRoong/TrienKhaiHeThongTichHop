#!/bin/bash
# ============================================================
#  Script Restore Website + Database - Nhiệm vụ 5
#  Kịch bản restore:
#  1. Chọn bản backup muốn restore
#  2. Restore DB trước
#  3. Restore file web sau
#  4. Kiểm tra website hoạt động
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()   { echo -e "${GREEN}[OK]${NC}   $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERR]${NC}  $1"; exit 1; }
title() { echo -e "\n${BLUE}${BOLD}--- $1 ---${NC}"; }

[[ $EUID -ne 0 ]] && error "Cần quyền root"

# =============================================
#  CẤU HÌNH
# =============================================
LOCAL_BACKUP_DIR="/backup/nhom05"
WEB_DIR="/var/www/html"
DB_HOST="10.10.40.164"
DB_USER="moodleuser"
DB_PASS="Moodle@123"
DB_NAME="moodle"
# =============================================

title "DANH SÁCH BACKUP CÓ SẴN"

echo ""
echo "  === File Web ==="
ls -lht "${LOCAL_BACKUP_DIR}/web/"*.tar.gz 2>/dev/null | \
    awk '{print NR".", $9, "("$5")"}' | head -10

echo ""
echo "  === File Database ==="
ls -lht "${LOCAL_BACKUP_DIR}/db/"*.sql.gz 2>/dev/null | \
    awk '{print NR".", $9, "("$5")"}' | head -10

echo ""

# Chọn file backup web
read -p "Nhập đường dẫn file web backup muốn restore: " WEB_BACKUP
read -p "Nhập đường dẫn file DB backup muốn restore : " DB_BACKUP

# Xác nhận
echo ""
echo "  Sẽ restore:"
echo "  Web: $WEB_BACKUP"
echo "  DB : $DB_BACKUP"
echo ""
read -p "Xác nhận restore? Dữ liệu hiện tại sẽ bị ghi đè! (yes/no): " CONFIRM
[ "$CONFIRM" != "yes" ] && { warn "Đã huỷ restore"; exit 0; }

# =============================================
#  RESTORE DATABASE
# =============================================
title "RESTORE DATABASE"

# Backup DB hiện tại trước khi restore (an toàn)
PRE_RESTORE_DB="/backup/nhom05/db/pre_restore_$(date +%Y%m%d_%H%M%S).sql.gz"
mysqldump -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" \
    --single-transaction "$DB_NAME" 2>/dev/null | gzip > "$PRE_RESTORE_DB"
log "Đã backup DB hiện tại trước restore: $PRE_RESTORE_DB"

# Drop và recreate database
mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" << SQLEOF
DROP DATABASE IF EXISTS ${DB_NAME};
CREATE DATABASE ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
SQLEOF
log "Đã xoá và tạo lại database ${DB_NAME}"

# Restore DB từ file backup
if [[ "$DB_BACKUP" == *.gz ]]; then
    gunzip -c "$DB_BACKUP" | mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME"
else
    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" < "$DB_BACKUP"
fi

[ $? -eq 0 ] && log "Restore DB thành công" || error "Restore DB thất bại"

# =============================================
#  RESTORE FILE WEB
# =============================================
title "RESTORE FILE WEB"

# Backup thư mục web hiện tại
PRE_RESTORE_WEB="/backup/nhom05/web/pre_restore_$(date +%Y%m%d_%H%M%S).tar.gz"
tar -czf "$PRE_RESTORE_WEB" "$WEB_DIR" 2>/dev/null
log "Đã backup web hiện tại: $PRE_RESTORE_WEB"

# Xoá thư mục web cũ
rm -rf "${WEB_DIR:?}"/*
log "Đã xoá file web cũ"

# Giải nén file backup vào thư mục web
tar -xzf "$WEB_BACKUP" -C / 2>/dev/null
[ $? -eq 0 ] && log "Giải nén web thành công" || error "Giải nén thất bại"

# Phân quyền lại
chown -R www-data:www-data "$WEB_DIR"
chmod -R 755 "$WEB_DIR"
log "Phân quyền xong"

# =============================================
#  KIỂM TRA SAU RESTORE
# =============================================
title "KIỂM TRA SAU RESTORE"

# Restart web server
if systemctl is-active --quiet lsws; then
    /usr/local/lsws/bin/lswsctrl restart
    log "Đã restart OpenLiteSpeed"
elif systemctl is-active --quiet nginx; then
    systemctl restart nginx
    log "Đã restart Nginx"
elif systemctl is-active --quiet apache2; then
    systemctl restart apache2
    log "Đã restart Apache"
fi

# Test website
WEB_IP=$(hostname -I | awk '{print $1}')
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 5 "http://${WEB_IP}/" 2>/dev/null)

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "302" ]; then
    log "Website phản hồi HTTP ${HTTP_CODE} — Restore thành công!"
else
    warn "Website trả về HTTP ${HTTP_CODE} — Kiểm tra lại cấu hình"
fi

echo ""
echo "================================================="
echo "  RESTORE HOÀN TẤT!"
echo "================================================="
echo "  DB restore từ : $DB_BACKUP"
echo "  Web restore từ: $WEB_BACKUP"
echo "  Backup trước restore:"
echo "    DB : $PRE_RESTORE_DB"
echo "    Web: $PRE_RESTORE_WEB"
echo "================================================="
