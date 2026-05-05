#!/bin/bash
# ============================================================
#  Lập lịch backup tự động bằng cron
# ============================================================

SCRIPT_PATH="/root/backup_website_db.sh"

# Copy script backup về /root
cp /root/backup_website_db.sh "$SCRIPT_PATH" 2>/dev/null
chmod +x "$SCRIPT_PATH"

echo "Lập lịch backup:"
echo "  1. Mỗi ngày lúc 2h sáng"
echo "  2. Mỗi 6 tiếng"
echo "  3. Tuỳ chọn"
read -p "Chọn (1/2/3): " CHOICE

case $CHOICE in
    1)
        CRON="0 2 * * * bash ${SCRIPT_PATH} >> /var/log/backup_nhom05.log 2>&1"
        ;;
    2)
        CRON="0 */6 * * * bash ${SCRIPT_PATH} >> /var/log/backup_nhom05.log 2>&1"
        ;;
    3)
        read -p "Nhập cron expression (VD: 0 2 * * *): " CRON_EXP
        CRON="${CRON_EXP} bash ${SCRIPT_PATH} >> /var/log/backup_nhom05.log 2>&1"
        ;;
esac

# Thêm vào crontab
(crontab -l 2>/dev/null | grep -v "backup_website_db"; echo "$CRON") | crontab -

echo ""
echo "Đã lập lịch cron:"
crontab -l | grep backup
echo ""
echo "Chạy backup thử ngay:"
echo "  bash ${SCRIPT_PATH}"
echo ""
echo "Xem log backup:"
echo "  tail -f /var/log/backup_nhom05.log"
