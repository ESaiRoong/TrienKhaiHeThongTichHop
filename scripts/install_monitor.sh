#!/bin/bash
# ============================================================
#  Script cài Prometheus + Grafana
#  Máy Monitor: Ubuntu 22.04
#  Giám sát: HAProxy, Web01, Web02, NFS+DB, Monitor (5 máy)
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()   { echo -e "${GREEN}[OK]${NC}   $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERR]${NC}  $1"; exit 1; }
title() { echo -e "\n${BLUE}${BOLD}==> $1${NC}"; }

[[ $EUID -ne 0 ]] && error "Cần quyền root: sudo bash $0"

# =============================================
#  CẤU HÌNH - chỉnh IP cho đúng nhóm
# =============================================
MONITOR_IP="10.10.40.164"
HAPROXY_IP="10.10.40.161"
WEB01_IP="10.10.40.162"
WEB02_IP="10.10.40.163"
NFSDB_IP="10.10.40.153"

PROMETHEUS_VERSION="2.51.0"
GRAFANA_PORT="3000"
PROMETHEUS_PORT="9090"
NODE_EXPORTER_PORT="9100"
NGINX_EXPORTER_PORT="9113"
MYSQL_EXPORTER_PORT="9104"
HAPROXY_EXPORTER_PORT="9101"

GRAFANA_ADMIN_PASS="Admin@123"
# =============================================

title "Bước 1: Cập nhật hệ thống"
apt update -y && apt install -y curl wget tar git
log "Xong"

# =============================================
#  CÀI PROMETHEUS
# =============================================
title "Bước 2: Tạo user Prometheus"
useradd --no-create-home --shell /bin/false prometheus 2>/dev/null
mkdir -p /etc/prometheus /var/lib/prometheus
log "User và thư mục OK"

title "Bước 3: Tải và cài Prometheus ${PROMETHEUS_VERSION}"
cd /tmp
wget -q "https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz"
tar -xzf "prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz"
cd "prometheus-${PROMETHEUS_VERSION}.linux-amd64"

cp prometheus promtool /usr/local/bin/
cp -r consoles/ console_libraries/ /etc/prometheus/
chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus
chown prometheus:prometheus /usr/local/bin/prometheus /usr/local/bin/promtool
log "Prometheus ${PROMETHEUS_VERSION} cài xong"

title "Bước 4: Viết file cấu hình Prometheus"
cat > /etc/prometheus/prometheus.yml << PROMCFG
# Prometheus Configuration - Nhom 05
global:
  scrape_interval:     15s   # Thu thập metrics mỗi 15 giây
  evaluation_interval: 15s   # Đánh giá rules mỗi 15 giây

# Alertmanager (tuỳ chọn, bỏ qua nếu chưa cài)
# alerting:
#   alertmanagers:
#     - static_configs:
#         - targets: ['localhost:9093']

scrape_configs:

  # Prometheus tự giám sát chính nó
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:${PROMETHEUS_PORT}']
        labels:
          instance: 'monitor'
          role: 'monitor'

  # Node Exporter - CPU/RAM/Disk tất cả máy
  - job_name: 'node_exporter'
    static_configs:
      - targets:
          - '${HAPROXY_IP}:${NODE_EXPORTER_PORT}'
          - '${WEB01_IP}:${NODE_EXPORTER_PORT}'
          - '${WEB02_IP}:${NODE_EXPORTER_PORT}'
          - '${NFSDB_IP}:${NODE_EXPORTER_PORT}'
          - '${MONITOR_IP}:${NODE_EXPORTER_PORT}'
        labels:
          job: 'node'
      - targets: ['${HAPROXY_IP}:${NODE_EXPORTER_PORT}']
        labels:
          instance: 'haproxy-node'
          role: 'loadbalancer'
      - targets: ['${WEB01_IP}:${NODE_EXPORTER_PORT}']
        labels:
          instance: 'web01-node'
          role: 'webserver'
      - targets: ['${WEB02_IP}:${NODE_EXPORTER_PORT}']
        labels:
          instance: 'web02-node'
          role: 'webserver'
      - targets: ['${NFSDB_IP}:${NODE_EXPORTER_PORT}']
        labels:
          instance: 'nfsdb-node'
          role: 'database'
      - targets: ['${MONITOR_IP}:${NODE_EXPORTER_PORT}']
        labels:
          instance: 'monitor-node'
          role: 'monitor'

  # HAProxy Exporter
  - job_name: 'haproxy'
    static_configs:
      - targets: ['${HAPROXY_IP}:${HAPROXY_EXPORTER_PORT}']
        labels:
          instance: 'haproxy'
          role: 'loadbalancer'

  # Nginx Exporter - Web01, Web02
  - job_name: 'nginx'
    static_configs:
      - targets:
          - '${WEB01_IP}:${NGINX_EXPORTER_PORT}'
          - '${WEB02_IP}:${NGINX_EXPORTER_PORT}'

  # MySQL/MariaDB Exporter
  - job_name: 'mariadb'
    static_configs:
      - targets: ['${NFSDB_IP}:${MYSQL_EXPORTER_PORT}']
        labels:
          instance: 'mariadb'
          role: 'database'
PROMCFG

chown prometheus:prometheus /etc/prometheus/prometheus.yml
log "Cấu hình prometheus.yml OK"

title "Bước 5: Tạo systemd service Prometheus"
cat > /etc/systemd/system/prometheus.service << SVCEOF
[Unit]
Description=Prometheus Monitoring
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/prometheus \\
    --config.file=/etc/prometheus/prometheus.yml \\
    --storage.tsdb.path=/var/lib/prometheus/ \\
    --web.console.templates=/etc/prometheus/consoles \\
    --web.console.libraries=/etc/prometheus/console_libraries \\
    --web.listen-address=0.0.0.0:${PROMETHEUS_PORT} \\
    --storage.tsdb.retention.time=30d
Restart=always

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable prometheus
systemctl start prometheus
systemctl is-active --quiet prometheus \
    && log "Prometheus đang chạy tại port ${PROMETHEUS_PORT}" \
    || error "Prometheus không khởi động được"

# =============================================
#  CÀI NODE EXPORTER trên chính máy Monitor
# =============================================
title "Bước 6: Cài Node Exporter trên máy Monitor"
NODE_VER="1.7.0"
cd /tmp
wget -q "https://github.com/prometheus/node_exporter/releases/download/v${NODE_VER}/node_exporter-${NODE_VER}.linux-amd64.tar.gz"
tar -xzf "node_exporter-${NODE_VER}.linux-amd64.tar.gz"
cp "node_exporter-${NODE_VER}.linux-amd64/node_exporter" /usr/local/bin/
useradd --no-create-home --shell /bin/false node_exporter 2>/dev/null
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
systemctl start node_exporter
systemctl is-active --quiet node_exporter \
    && log "Node Exporter chạy tại port ${NODE_EXPORTER_PORT}" \
    || warn "Node Exporter lỗi"

# =============================================
#  CÀI GRAFANA
# =============================================
title "Bước 7: Cài Grafana"
apt install -y apt-transport-https software-properties-common
wget -q -O /usr/share/keyrings/grafana.key https://apt.grafana.com/gpg.key
echo "deb [signed-by=/usr/share/keyrings/grafana.key] https://apt.grafana.com stable main" \
    > /etc/apt/sources.list.d/grafana.list
apt update -y
apt install -y grafana
log "Grafana cài xong"

title "Bước 8: Cấu hình Grafana"
cat > /etc/grafana/grafana.ini << GRAFCFG
[server]
http_port = ${GRAFANA_PORT}
domain = ${MONITOR_IP}

[security]
admin_user = admin
admin_password = ${GRAFANA_ADMIN_PASS}

[users]
allow_sign_up = false

[auth.anonymous]
enabled = false
GRAFCFG

systemctl daemon-reload
systemctl enable grafana-server
systemctl start grafana-server
systemctl is-active --quiet grafana-server \
    && log "Grafana chạy tại port ${GRAFANA_PORT}" \
    || error "Grafana không khởi động được"

title "Bước 9: Thêm Prometheus làm datasource Grafana (tự động)"
sleep 5  # Chờ Grafana khởi động xong
curl -s -X POST \
    -H "Content-Type: application/json" \
    -d "{
        \"name\": \"Prometheus\",
        \"type\": \"prometheus\",
        \"url\": \"http://localhost:${PROMETHEUS_PORT}\",
        \"access\": \"proxy\",
        \"isDefault\": true
    }" \
    "http://admin:${GRAFANA_ADMIN_PASS}@localhost:${GRAFANA_PORT}/api/datasources" \
    && log "Đã thêm Prometheus datasource vào Grafana" \
    || warn "Thêm datasource thất bại — vào Grafana làm thủ công"

title "Bước 10: Mở firewall"
ufw allow ${PROMETHEUS_PORT}/tcp
ufw allow ${GRAFANA_PORT}/tcp
ufw allow ${NODE_EXPORTER_PORT}/tcp
log "Đã mở port ${PROMETHEUS_PORT}, ${GRAFANA_PORT}, ${NODE_EXPORTER_PORT}"

echo ""
echo "========================================================"
echo "  CÀI ĐẶT HOÀN TẤT!"
echo "========================================================"
echo "  Prometheus  : http://${MONITOR_IP}:${PROMETHEUS_PORT}"
echo "  Grafana     : http://${MONITOR_IP}:${GRAFANA_PORT}"
echo "  Grafana login: admin / ${GRAFANA_ADMIN_PASS}"
echo ""
echo "  Dashboard gợi ý (import trong Grafana):"
echo "  Node Exporter : ID 1860"
echo "  HAProxy       : ID 367"
echo "  Nginx         : ID 9614"
echo "  MySQL/MariaDB : ID 7362"
echo ""
echo "  Tiếp theo: Chạy install_exporter.sh trên CÁC MÁY CÒN LẠI"
echo "  HAProxy : ${HAPROXY_IP}"
echo "  Web01   : ${WEB01_IP}"
echo "  Web02   : ${WEB02_IP}"
echo "  NFS+DB  : ${NFSDB_IP}"
echo "========================================================"
