#!/usr/bin/env bash
set -Eeuo pipefail

# Komari HTTPS installer - automatically prefers existing Nginx, otherwise Caddy
# Debian/Ubuntu | custom port/domain | HTTPS | management menu

INSTALL_DIR=/opt/komari
BINARY="$INSTALL_DIR/komari"
SERVICE=/etc/systemd/system/komari.service
DEFAULT_PORT=25774
PORT=""
DOMAIN=""

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; CYAN='\033[36m'; NC='\033[0m'
info(){ echo -e "${CYAN}[INFO]${NC} $*"; }
ok(){ echo -e "${GREEN}[OK]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
die(){ echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $EUID -eq 0 ]] || die '请使用 root 用户运行。'
[[ -f /etc/os-release ]] || die '无法识别 Linux 系统。'
. /etc/os-release
[[ "${ID:-}" == debian || "${ID:-}" == ubuntu ]] || warn "当前系统 ${PRETTY_NAME:-unknown} 未重点测试。"
command -v systemctl >/dev/null || die '需要 systemd。'

clear 2>/dev/null || true
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}     Komari + Nginx/Caddy HTTPS 智能一键安装${NC}"
echo -e "${CYAN}============================================================${NC}"
echo

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl ca-certificates gnupg iproute2

ARCH=$(uname -m)
case "$ARCH" in
  x86_64) KARCH=amd64;;
  aarch64|arm64) KARCH=arm64;;
  i386|i686) KARCH=386;;
  riscv64) KARCH=riscv64;;
  loongarch64|loong64) KARCH=loong64;;
  *) die "不支持的 CPU 架构：$ARCH";;
esac

while true; do
  read -r -p "Komari 内部端口 [${DEFAULT_PORT}]: " PORT
  PORT=${PORT:-$DEFAULT_PORT}
  [[ "$PORT" =~ ^[0-9]+$ ]] && ((PORT>=1 && PORT<=65535)) && break
  warn '端口必须为 1-65535。'
done

if ss -lnt 2>/dev/null | grep -Eq ":${PORT}[[:space:]]"; then
  warn "端口 ${PORT} 已被占用："
  ss -lntp 2>/dev/null | grep -E ":${PORT}[[:space:]]" || true
  read -r -p '仍然继续？[y/N]: ' A
  [[ "$A" =~ ^[Yy]$ ]] || die '已取消。'
fi

while true; do
  read -r -p 'HTTPS 域名（例如 jk.example.com）： ' DOMAIN
  DOMAIN=${DOMAIN#http://}; DOMAIN=${DOMAIN#https://}; DOMAIN=${DOMAIN%/}
  [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] && break
  warn '域名格式不正确。'
done

echo
echo "Komari：127.0.0.1:${PORT}"
echo "面板：https://${DOMAIN}"
echo
read -r -p '确认安装？[Y/n]: ' CONFIRM
CONFIRM=${CONFIRM:-Y}
[[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 0

mkdir -p "$INSTALL_DIR"
systemctl stop komari 2>/dev/null || true
[[ -f "$BINARY" ]] && cp -a "$BINARY" "$BINARY.backup.$(date +%Y%m%d-%H%M%S)"
[[ -f "$SERVICE" ]] && cp -a "$SERVICE" "$SERVICE.backup.$(date +%Y%m%d-%H%M%S)"

info '下载 Komari 最新稳定版...'
curl -fL --retry 5 --retry-delay 2 --connect-timeout 20 \
  "https://github.com/komari-monitor/komari/releases/latest/download/komari-linux-${KARCH}" \
  -o "$BINARY"
chmod 755 "$BINARY"

cat > "$SERVICE" <<EOF
[Unit]
Description=Komari Monitor Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${BINARY} server -l 127.0.0.1:${PORT}
Restart=always
RestartSec=3
LimitNOFILE=65535
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable komari >/dev/null
systemctl restart komari
sleep 2
systemctl is-active --quiet komari || { journalctl -u komari -n 80 --no-pager; die 'Komari 启动失败。'; }
ok "Komari 已启动：127.0.0.1:${PORT}"

# If Nginx is already active, use it and do NOT start Caddy.
USE_NGINX=0
if command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then USE_NGINX=1; fi

if (( USE_NGINX )); then
  info '检测到 Nginx 正在使用 80 端口，使用 Nginx 反代，不启动 Caddy。'
  apt-get install -y certbot python3-certbot-nginx
  mkdir -p /var/www/html/.well-known/acme-challenge /etc/nginx/conf.d
  NCONF="/etc/nginx/conf.d/komari.conf"
  [[ -f "$NCONF" ]] && cp -a "$NCONF" "$NCONF.backup.$(date +%Y%m%d-%H%M%S)"
  cat > "$NCONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        proxy_pass http://127.0.0.1:${PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
  nginx -t
  systemctl reload nginx
  info '申请 HTTPS 证书...'
  certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --redirect
  nginx -t
  systemctl reload nginx
  ok 'Nginx HTTPS 配置完成。'
  WEB_SERVICE=nginx
else
  info '未检测到运行中的 Nginx，使用 Caddy 自动 HTTPS。'
  if ! command -v caddy >/dev/null 2>&1; then
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
    install -m 0755 -d /usr/share/keyrings
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    chmod 0644 /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' -o /etc/apt/sources.list.d/caddy-stable.list
    apt-get update
    apt-get install -y caddy
  fi
  CADDYFILE=/etc/caddy/Caddyfile
  mkdir -p /etc/caddy
  [[ -f "$CADDYFILE" ]] && cp -a "$CADDYFILE" "$CADDYFILE.backup.$(date +%Y%m%d-%H%M%S)"
  cat > "$CADDYFILE" <<EOF
${DOMAIN} {
    encode gzip
    reverse_proxy 127.0.0.1:${PORT}
}
EOF
  caddy validate --config "$CADDYFILE" --adapter caddyfile
  systemctl enable caddy >/dev/null
  systemctl restart caddy
  sleep 2
  systemctl is-active --quiet caddy || { journalctl -u caddy -n 80 --no-pager; die 'Caddy 启动失败。'; }
  ok 'Caddy HTTPS 配置完成。'
  WEB_SERVICE=caddy
fi

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
  ufw allow 80/tcp >/dev/null || true
  ufw allow 443/tcp >/dev/null || true
  ok 'UFW 已放行 80/443。'
fi

cat > /usr/local/bin/komari-menu <<EOF
#!/usr/bin/env bash
while true; do
 clear
 echo '================================================'
 echo '              Komari 管理菜单'
 echo '================================================'
 echo ' 1. Komari 状态'
 echo ' 2. 启动 Komari'
 echo ' 3. 停止 Komari'
 echo ' 4. 重启 Komari'
 echo ' 5. Komari 日志'
 echo ' 6. 查看监听端口'
 echo ' 7. Web 服务状态'
 echo ' 8. 重启 Web 服务'
 echo ' 9. Web 服务日志'
 echo '10. 查看 Komari 服务配置'
 echo '11. 查看 Web 配置'
 echo '12. 测试 HTTPS'
 echo ' 0. 退出'
 echo
 read -r -p '请选择 [0-12]: ' C
 case "\$C" in
  1) systemctl status komari --no-pager -l; read -r -p '回车继续...' ;;
  2) systemctl start komari; read -r -p '回车继续...' ;;
  3) systemctl stop komari; read -r -p '回车继续...' ;;
  4) systemctl restart komari; read -r -p '回车继续...' ;;
  5) journalctl -u komari -f ;;
  6) ss -lntp; read -r -p '回车继续...' ;;
  7) systemctl status ${WEB_SERVICE} --no-pager -l; read -r -p '回车继续...' ;;
  8) systemctl restart ${WEB_SERVICE}; read -r -p '回车继续...' ;;
  9) journalctl -u ${WEB_SERVICE} -f ;;
 10) cat /etc/systemd/system/komari.service; read -r -p '回车继续...' ;;
 11) if [[ '${WEB_SERVICE}' == nginx ]]; then cat /etc/nginx/conf.d/komari.conf; else cat /etc/caddy/Caddyfile; fi; read -r -p '回车继续...' ;;
 12) curl -I -L --max-time 15 https://${DOMAIN} || true; read -r -p '回车继续...' ;;
  0) exit 0 ;;
  *) echo '无效选项'; sleep 1 ;;
 esac
done
EOF
chmod 755 /usr/local/bin/komari-menu

cat > /usr/local/bin/komari-status <<EOF
#!/usr/bin/env bash
echo '===== Komari ====='
systemctl status komari --no-pager -l
echo
echo '===== ${WEB_SERVICE} ====='
systemctl status ${WEB_SERVICE} --no-pager -l
echo
echo '===== Ports ====='
ss -lntp | grep -E ':(80|443|${PORT})[[:space:]]' || true
EOF
chmod 755 /usr/local/bin/komari-status

if curl -fsS --max-time 10 "http://127.0.0.1:${PORT}" >/dev/null 2>&1; then ok 'Komari 本地访问正常。'; else warn 'Komari 本地测试未返回成功，请检查日志。'; fi

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}                    安装完成${NC}"
echo -e "${GREEN}============================================================${NC}"
echo "面板：https://${DOMAIN}"
echo "Komari：127.0.0.1:${PORT}"
echo "Web：${WEB_SERVICE}"
echo "IP：${IP:-请确认}"
echo
echo '管理：komari-menu'
echo '状态：komari-status'
echo "注意：DNS ${DOMAIN} 必须解析到此 VPS，安全组放行 TCP 80/443。"
echo -e "${GREEN}============================================================${NC}"
