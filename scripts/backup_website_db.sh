#!/bin/bash
# ============================================================
#  Script Backup Website + Database - Nhiệm vụ 5
#  - Backup local
#  - Backup qua server khác (rsync/SSH)
#  - Backup lên Google Drive (rclone)
#  - Lập lịch cron
#  Chạy trên: Web01 (10.10.40.162) hoặc Web02 (10.10.40.172)
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()   { echo -e "${GREEN}[OK]${NC}   $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERR]${NC}  $1"; }
title() { echo -e "\n${BLUE}${BOLD}--- $1 ---${NC}"; }

# =============================================
#  CẤU HÌNH
# =============================================
# --- Thông tin website ---
WEB_DIR="/var/www/html"            # Thư mục web
SITE_NAME="nhom05"                 # Tên nhận dạng

# --- Thông tin Database ---
DB_HOST="10.10.40.164"            # IP máy MariaDB
DB_USER="moodleuser"              # User DB
DB_PASS="Moodle@123"              # Mật khẩu DB
DB_NAME="moodle"                  # Tên database
DB_NAME_WP="wordpress"            # Database WordPress (nếu có)

# --- Backup Local ---
LOCAL_BACKUP_DIR="/backup/${SITE_NAME}"
KEEP_DAYS=7                        # Giữ backup 7 ngày

# --- Backup Remote Server ---
ENABLE_REMOTE=false               # Đổi true khi có máy nhận
REMOTE_USER="backupuser"
REMOTE_HOST="10.10.40.165"        # IP máy backup server
REMOTE_DIR="/backup/${SITE_NAME}"
SSH_KEY="/root/.ssh/id_rsa"

# --- Backup Google Drive ---
ENABLE_GDRIVE=false               # Đổi true sau khi cài rclone
RCLONE_REMOTE="gdrive"
RCLONE_PATH="backup/${SITE_NAME}"
# =============================================

DATE=$(date +%Y%m%d_%H%M%S)
DATE_READABLE=$(date '+%Y-%m-%d %H:%M:%S')
LOG_FILE="/var/log/backup_${SITE_NAME}.log"

# Ghi log vào file
exec > >(tee -a "$LOG_FILE") 2>&1

echo "================================================="
echo "  BACKUP BẮT ĐẦU: ${DATE_READABLE}"
echo "  Máy: $(hostname -I | awk '{print $1}')"
echo "================================================="

# Tạo thư mục backup
mkdir -p "${LOCAL_BACKUP_DIR}/web"
mkdir -p "${LOCAL_BACKUP_DIR}/db"
mkdir -p "${LOCAL_BACKUP_DIR}/logs"

# =============================================
#  PHẦN 1: BACKUP LOCAL
# =============================================
title "1. BACKUP LOCAL"

# --- Backup thư mục Website ---
WEB_BACKUP="${LOCAL_BACKUP_DIR}/web/website_${DATE}.tar.gz"
if [ -d "$WEB_DIR" ] && [ "$(ls -A $WEB_DIR)" ]; then
    tar -czf "$WEB_BACKUP" \
        --exclude="*.log" \
        --exclude="*/cache/*" \
        --exclude="*/tmp/*" \
        "$WEB_DIR" 2>/dev/null
    WEB_SIZE=$(du -sh "$WEB_BACKUP" | cut -f1)
    log "Website backup: $WEB_BACKUP ($WEB_SIZE)"
else
    warn "Thư mục web trống hoặc không tồn tại: $WEB_DIR"
fi

# --- Backup Database Moodle ---
DB_BACKUP="${LOCAL_BACKUP_DIR}/db/${DB_NAME}_${DATE}.sql.gz"
if mysqldump -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" \
    --single-transaction \
    --routines \
    --triggers \
    --events \
    "$DB_NAME" 2>/dev/null | gzip > "$DB_BACKUP"; then
    DB_SIZE=$(du -sh "$DB_BACKUP" | cut -f1)
    log "DB Moodle backup: $DB_BACKUP ($DB_SIZE)"
else
    warn "Backup DB Moodle thất bại — kiểm tra kết nối ${DB_HOST}"
fi

# --- Backup Database WordPress (nếu có) ---
WP_DB_BACKUP="${LOCAL_BACKUP_DIR}/db/${DB_NAME_WP}_${DATE}.sql.gz"
if mysqldump -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" \
    --single-transaction \
    "$DB_NAME_WP" 2>/dev/null | gzip > "$WP_DB_BACKUP"; then
    WP_SIZE=$(du -sh "$WP_DB_BACKUP" | cut -f1)
    log "DB WordPress backup: $WP_DB_BACKUP ($WP_SIZE)"
else
    warn "Backup DB WordPress thất bại hoặc không tồn tại"
    rm -f "$WP_DB_BACKUP"
fi

# --- Xoá backup cũ ---
DELETED=$(find "$LOCAL_BACKUP_DIR" -type f \
    \( -name "*.tar.gz" -o -name "*.sql.gz" \) \
    -mtime +${KEEP_DAYS} -print -delete | wc -l)
[ "$DELETED" -gt 0 ] && log "Đã xoá $DELETED file cũ hơn ${KEEP_DAYS} ngày"

# --- Thống kê ---
TOTAL_SIZE=$(du -sh "$LOCAL_BACKUP_DIR" | cut -f1)
TOTAL_FILES=$(find "$LOCAL_BACKUP_DIR" -type f | wc -l)
log "Tổng: $TOTAL_FILES files, dung lượng: $TOTAL_SIZE tại $LOCAL_BACKUP_DIR"

# =============================================
#  PHẦN 2: BACKUP QUA SERVER KHÁC
# =============================================
title "2. BACKUP QUA SERVER KHÁC (rsync/SSH)"

if [ "$ENABLE_REMOTE" = false ]; then
    warn "Đã tắt (ENABLE_REMOTE=false)"
    echo "  Để bật:"
    echo "  1. ssh-keygen -t rsa -b 4096 -N '' -f ${SSH_KEY}"
    echo "  2. ssh-copy-id ${REMOTE_USER}@${REMOTE_HOST}"
    echo "  3. Sửa ENABLE_REMOTE=true trong script"
else
    if ssh -o ConnectTimeout=5 -o BatchMode=yes \
           -i "$SSH_KEY" \
           "${REMOTE_USER}@${REMOTE_HOST}" \
           "mkdir -p ${REMOTE_DIR}/web ${REMOTE_DIR}/db" 2>/dev/null; then

        rsync -avz --delete \
            "${LOCAL_BACKUP_DIR}/" \
            "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/" \
            2>/dev/null \
            && log "Sync sang ${REMOTE_HOST}:${REMOTE_DIR} thành công" \
            || warn "rsync thất bại — backup local vẫn an toàn"
    else
        warn "Không SSH được tới ${REMOTE_HOST}"
    fi
fi

# =============================================
#  PHẦN 3: BACKUP LÊN GOOGLE DRIVE
# =============================================
title "3. BACKUP LÊN GOOGLE DRIVE (rclone)"

if [ "$ENABLE_GDRIVE" = false ]; then
    warn "Đã tắt (ENABLE_GDRIVE=false)"
    echo "  Để bật:"
    echo "  1. curl https://rclone.org/install.sh | sudo bash"
    echo "  2. rclone config   → chọn Google Drive"
    echo "  3. rclone ls gdrive:   → test kết nối"
    echo "  4. Sửa ENABLE_GDRIVE=true trong script"
else
    if command -v rclone &>/dev/null; then
        # Upload file backup mới nhất lên GDrive
        rclone copy "${LOCAL_BACKUP_DIR}/web/website_${DATE}.tar.gz" \
            "${RCLONE_REMOTE}:${RCLONE_PATH}/web/" 2>/dev/null \
            && log "Upload website lên Google Drive OK"

        rclone copy "${LOCAL_BACKUP_DIR}/db/" \
            "${RCLONE_REMOTE}:${RCLONE_PATH}/db/" \
            --include "*${DATE}*" 2>/dev/null \
            && log "Upload DB lên Google Drive OK"

        # Xoá file cũ trên GDrive
        rclone delete "${RCLONE_REMOTE}:${RCLONE_PATH}" \
            --min-age ${KEEP_DAYS}d 2>/dev/null
        log "Đã dọn file cũ trên Google Drive"
    else
        error "rclone chưa cài: curl https://rclone.org/install.sh | sudo bash"
    fi
fi

echo ""
echo "================================================="
echo "  BACKUP XONG: ${DATE_READABLE}"
echo "  Local: ${LOCAL_BACKUP_DIR}"
echo "  Log  : ${LOG_FILE}"
echo "================================================="
