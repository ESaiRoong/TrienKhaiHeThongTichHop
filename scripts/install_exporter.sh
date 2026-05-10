#!/bin/bash
# ============================================================
#  Script cài Exporter trên các máy được giám sát
#  Chạy trên: HAProxy, Web01, Web02, NFS+DB
#  Script tự phát hiện vai trò máy và cài đúng exporter
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()   { echo -e "${GREEN}[OK]${NC}   $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERR]${NC}  $1"; exit 1; }
title() { echo -e "\n${BLUE}${BOLD}==> $1${NC}"; }

[[ $EUID -ne 0 ]] && error "Cần quyền root: sudo bash $0"

# =============================================
#  CẤU HÌNH
# =============================================
MONITOR_IP="10.10.40.165"
HAPROXY_IP="10.10.40.161"
WEB01_IP="10.10.40.162"
WEB02_IP="10.10.40.163"
NFSDB_IP="10.10.40.164"

NODE_VER="1.7.0"
MYSQL_EXPORTER_VER="0.15.1"

# Thông tin MariaDB (chỉ dùng khi cài trên máy NFS+DB)
DB_HOST="localhost"
DB_MONITOR_USER="exporter"
DB_MONITOR_PASS="Exporter@123"
# =============================================

# Lấy IP hiện tại của máy
CURRENT_IP=$(hostname -I | awk '{print $1}')
log "IP máy này: ${CURRENT_IP}"

# Phát hiện OS
if [ -f /etc/debian_version ]; then
    OS="debian"; PKG="apt"
else
    OS="rhel"; PKG="dnf"
fi
log "OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"')"

# =============================================
#  NODE EXPORTER - cài trên TẤT CẢ máy
# =============================================
title "Cài Node Exporter (CPU/RAM/Disk)"
useradd --no-create-home --shell /bin/false node_exporter 2>/dev/null

cd /tmp
wget -q "https://github.com/prometheus/node_exporter/releases/download/v${NODE_VER}/node_exporter-${NODE_VER}.linux-amd64.tar.gz"
tar -xzf "node_exporter-${NODE_VER}.linux-amd64.tar.gz"
cp "node_exporter-${NODE_VER}.linux-amd64/node_exporter" /usr/local/bin/
chown node_exporter:node_exporter /usr/local/bin/node_exporter

cat > /etc/systemd/system/node_exporter.service << SVCEOF
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter
Restart=always

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable node_exporter
systemctl restart node_exporter
systemctl is-active --quiet node_exporter \
    && log "Node Exporter OK (port 9100)" \
    || warn "Node Exporter lỗi"

# =============================================
#  HAPROXY EXPORTER - chỉ cài trên máy HAProxy
# =============================================
if [ "$CURRENT_IP" = "$HAPROXY_IP" ]; then
    title "Phát hiện máy HAProxy — Cài HAProxy Exporter"
    HAPROXY_EXP_VER="0.15.0"
    cd /tmp
    wget -q "https://github.com/prometheus/haproxy_exporter/releases/download/v${HAPROXY_EXP_VER}/haproxy_exporter-${HAPROXY_EXP_VER}.linux-amd64.tar.gz"
    tar -xzf "haproxy_exporter-${HAPROXY_EXP_VER}.linux-amd64.tar.gz"
    cp "haproxy_exporter-${HAPROXY_EXP_VER}.linux-amd64/haproxy_exporter" /usr/local/bin/
    useradd --no-create-home --shell /bin/false haproxy_exporter 2>/dev/null

    cat > /etc/systemd/system/haproxy_exporter.service << SVCEOF
[Unit]
Description=HAProxy Exporter
After=network.target

[Service]
User=haproxy_exporter
Group=haproxy_exporter
Type=simple
ExecStart=/usr/local/bin/haproxy_exporter \
    --haproxy.scrape-uri="unix:/var/lib/haproxy/stats"
Restart=always

[Install]
WantedBy=multi-user.target
SVCEOF

    # Cho haproxy_exporter đọc socket của HAProxy
    usermod -aG haproxy haproxy_exporter 2>/dev/null

    systemctl daemon-reload
    systemctl enable haproxy_exporter
    systemctl restart haproxy_exporter
    systemctl is-active --quiet haproxy_exporter \
        && log "HAProxy Exporter OK (port 9101)" \
        || warn "HAProxy Exporter lỗi"

    # Mở firewall
    if command -v ufw &>/dev/null; then
        ufw allow from "$MONITOR_IP" to any port 9101
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port=9101/tcp && firewall-cmd --reload
    fi
fi

# =============================================
#  NGINX EXPORTER - cài trên Web01 và Web02
# =============================================
if [ "$CURRENT_IP" = "$WEB01_IP" ] || [ "$CURRENT_IP" = "$WEB02_IP" ]; then
    title "Phát hiện máy Webserver — Cài Nginx Exporter"
    NGINX_EXP_VER="1.1.0"
    cd /tmp
    wget -q "https://github.com/nginxinc/nginx-prometheus-exporter/releases/download/v${NGINX_EXP_VER}/nginx-prometheus-exporter_${NGINX_EXP_VER}_linux_amd64.tar.gz"
    tar -xzf "nginx-prometheus-exporter_${NGINX_EXP_VER}_linux_amd64.tar.gz"
    cp nginx-prometheus-exporter /usr/local/bin/
    useradd --no-create-home --shell /bin/false nginx_exporter 2>/dev/null

    # Bật stub_status trong Nginx
    NGINX_STATUS_CONF="/etc/nginx/conf.d/stub_status.conf"
    cat > "$NGINX_STATUS_CONF" << NGINXCFG
server {
    listen 127.0.0.1:8080;
    location /stub_status {
        stub_status on;
        allow 127.0.0.1;
        deny all;
    }
}
NGINXCFG

    nginx -t && systemctl reload nginx && log "Nginx stub_status bật OK"

    cat > /etc/systemd/system/nginx_exporter.service << SVCEOF
[Unit]
Description=Nginx Exporter
After=network.target

[Service]
User=nginx_exporter
Group=nginx_exporter
Type=simple
ExecStart=/usr/local/bin/nginx-prometheus-exporter \
    --nginx.scrape-uri=http://127.0.0.1:8080/stub_status
Restart=always

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable nginx_exporter
    systemctl restart nginx_exporter
    systemctl is-active --quiet nginx_exporter \
        && log "Nginx Exporter OK (port 9113)" \
        || warn "Nginx Exporter lỗi"

    # Mở firewall
    if command -v ufw &>/dev/null; then
        ufw allow from "$MONITOR_IP" to any port 9113
    fi
fi

# =============================================
#  MYSQL EXPORTER - chỉ cài trên máy NFS+DB
# =============================================
if [ "$CURRENT_IP" = "$NFSDB_IP" ]; then
    title "Phát hiện máy NFS+DB — Cài MySQL/MariaDB Exporter"

    # Tạo user monitor trong MariaDB
    mysql -u root -e "
        CREATE USER IF NOT EXISTS '${DB_MONITOR_USER}'@'localhost' IDENTIFIED BY '${DB_MONITOR_PASS}';
        GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO '${DB_MONITOR_USER}'@'localhost';
        FLUSH PRIVILEGES;
    " 2>/dev/null && log "Đã tạo DB user: ${DB_MONITOR_USER}" || warn "Tạo DB user thất bại — tạo thủ công"

    cd /tmp
    wget -q "https://github.com/prometheus/mysqld_exporter/releases/download/v${MYSQL_EXPORTER_VER}/mysqld_exporter-${MYSQL_EXPORTER_VER}.linux-amd64.tar.gz"
    tar -xzf "mysqld_exporter-${MYSQL_EXPORTER_VER}.linux-amd64.tar.gz"
    cp "mysqld_exporter-${MYSQL_EXPORTER_VER}.linux-amd64/mysqld_exporter" /usr/local/bin/
    useradd --no-create-home --shell /bin/false mysql_exporter 2>/dev/null

    # File credentials
    cat > /etc/.mysqld_exporter.cnf << MYCNF
[client]
user=${DB_MONITOR_USER}
password=${DB_MONITOR_PASS}
host=${DB_HOST}
MYCNF
    chmod 600 /etc/.mysqld_exporter.cnf
    chown mysql_exporter:mysql_exporter /etc/.mysqld_exporter.cnf 2>/dev/null

    cat > /etc/systemd/system/mysql_exporter.service << SVCEOF
[Unit]
Description=MySQL/MariaDB Exporter
After=network.target mariadb.service

[Service]
User=mysql_exporter
Group=mysql_exporter
Type=simple
ExecStart=/usr/local/bin/mysqld_exporter \
    --config.my-cnf=/etc/.mysqld_exporter.cnf
Restart=always

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable mysql_exporter
    systemctl restart mysql_exporter
    systemctl is-active --quiet mysql_exporter \
        && log "MySQL Exporter OK (port 9104)" \
        || warn "MySQL Exporter lỗi — kiểm tra DB credentials"

    # Mở firewall
    if command -v ufw &>/dev/null; then
        ufw allow from "$MONITOR_IP" to any port 9104
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port=9104/tcp && firewall-cmd --reload
    fi
fi

# =============================================
#  MỞ PORT NODE EXPORTER CHO MONITOR
# =============================================
title "Mở firewall cho Monitor truy cập"
if command -v ufw &>/dev/null; then
    ufw allow from "$MONITOR_IP" to any port 9100
    ufw reload
elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-port=9100/tcp
    firewall-cmd --reload
fi
log "Đã mở port 9100 cho ${MONITOR_IP}"

echo ""
echo "========================================================"
echo "  EXPORTER CÀI XONG TRÊN: ${CURRENT_IP}"
echo "========================================================"
echo "  Node Exporter  : http://${CURRENT_IP}:9100/metrics"
[ "$CURRENT_IP" = "$HAPROXY_IP" ] && echo "  HAProxy Exporter: http://${CURRENT_IP}:9101/metrics"
[ "$CURRENT_IP" = "$WEB01_IP" ] || [ "$CURRENT_IP" = "$WEB02_IP" ] && \
    echo "  Nginx Exporter : http://${CURRENT_IP}:9113/metrics"
[ "$CURRENT_IP" = "$NFSDB_IP" ] && echo "  MySQL Exporter : http://${CURRENT_IP}:9104/metrics"
echo ""
echo "  Kiểm tra Prometheus nhận được chưa:"
echo "  http://${MONITOR_IP}:9090/targets"
echo "========================================================"
