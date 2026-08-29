#!/usr/bin/env bash
set -Eeuo pipefail

# Komari + Caddy HTTPS installer
# Usage: bash <(curl -fsSL https://raw.githubusercontent.com/jarvan722/komari/main/install-https.sh)

INSTALL_DIR=/opt/komari
BINARY="$INSTALL_DIR/komari"
SERVICE=/etc/systemd/system/komari.service
CADDYFILE=/etc/caddy/Caddyfile
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
echo -e "${CYAN}          Komari + Caddy HTTPS 一键安装${NC}"
echo -e "${CYAN}============================================================${NC}"
echo

info '安装基础依赖...'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl ca-certificates gnupg debian-keyring debian-archive-keyring apt-transport-https iproute2

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

if [[ -f "$BINARY" ]]; then
  cp -a "$BINARY" "$BINARY.backup.$(date +%Y%m%d-%H%M%S)"
fi

info '下载 Komari 最新稳定版...'
curl -fL --retry 5 --retry-delay 2 --connect-timeout 20 \
  "https://github.com/komari-monitor/komari/releases/latest/download/komari-linux-${KARCH}" \
  -o "$BINARY"
chmod 755 "$BINARY"
[[ -x "$BINARY" ]] || die 'Komari 下载失败。'

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
if ! systemctl is-active --quiet komari; then
  journalctl -u komari -n 80 --no-pager
  die 'Komari 启动失败。'
fi
ok 'Komari 已启动。'

if ! command -v caddy >/dev/null 2>&1; then
  info '安装 Caddy...'
  install -m 0755 -d /usr/share/keyrings
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  chmod 0644 /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' -o /etc/apt/sources.list.d/caddy-stable.list
  apt-get update
  apt-get install -y caddy
fi
command -v caddy >/dev/null || die 'Caddy 安装失败。'

mkdir -p /etc/caddy
if [[ -f "$CADDYFILE" && -s "$CADDYFILE" ]]; then
  BACKUP="${CADDYFILE}.backup.$(date +%Y%m%d-%H%M%S)"
  cp -a "$CADDYFILE" "$BACKUP"
  warn "已备份现有 Caddyfile：$BACKUP"
  if grep -Eq "^[[:space:]]*${DOMAIN//./\\.}[[:space:]]*\{" "$CADDYFILE"; then
    warn "检测到同域名已有 Caddy 配置，将替换该 Caddyfile；备份已保留。"
    cat > "$CADDYFILE" <<EOF
${DOMAIN} {
    encode gzip
    reverse_proxy 127.0.0.1:${PORT}
}
EOF
  else
    cat >> "$CADDYFILE" <<EOF

# Komari managed block
${DOMAIN} {
    encode gzip
    reverse_proxy 127.0.0.1:${PORT}
}
EOF
  fi
else
  cat > "$CADDYFILE" <<EOF
${DOMAIN} {
    encode gzip
    reverse_proxy 127.0.0.1:${PORT}
}
EOF
fi

caddy validate --config "$CADDYFILE" --adapter caddyfile
systemctl enable caddy >/dev/null
systemctl restart caddy
sleep 2
systemctl is-active --quiet caddy || { journalctl -u caddy -n 80 --no-pager; die 'Caddy 启动失败。'; }
ok 'Caddy 已启动。'

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
  ufw allow 80/tcp >/dev/null || true
  ufw allow 443/tcp >/dev/null || true
  ok 'UFW 已放行 80/443。'
fi

cat > /usr/local/bin/komari-menu <<'EOF'
#!/usr/bin/env bash
while true; do
  clear
  echo '================================================'
  echo '              Komari 管理菜单'
  echo '================================================'
  echo ' 1. 查看 Komari 状态'
  echo ' 2. 启动 Komari'
  echo ' 3. 停止 Komari'
  echo ' 4. 重启 Komari'
  echo ' 5. 查看 Komari 日志'
  echo ' 6. 查看监听端口'
  echo ' 7. 查看 Caddy 状态'
  echo ' 8. 重启 Caddy'
  echo ' 9. 查看 Caddy 日志'
  echo '10. 查看 Caddy 配置'
  echo '11. 查看 Komari 服务配置'
  echo '12. 重载 Caddy'
  echo ' 0. 退出'
  echo
  read -r -p '请选择 [0-12]: ' C
  case "$C" in
    1) systemctl status komari --no-pager; read -r -p '回车继续...' ;;
    2) systemctl start komari; systemctl status komari --no-pager; read -r -p '回车继续...' ;;
    3) systemctl stop komari; read -r -p '回车继续...' ;;
    4) systemctl restart komari; systemctl status komari --no-pager; read -r -p '回车继续...' ;;
    5) journalctl -u komari -f ;;
    6) ss -lntp; read -r -p '回车继续...' ;;
    7) systemctl status caddy --no-pager; read -r -p '回车继续...' ;;
    8) systemctl restart caddy; systemctl status caddy --no-pager; read -r -p '回车继续...' ;;
    9) journalctl -u caddy -f ;;
    10) cat /etc/caddy/Caddyfile; echo; read -r -p '回车继续...' ;;
    11) cat /etc/systemd/system/komari.service; echo; read -r -p '回车继续...' ;;
    12) caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile; read -r -p '回车继续...' ;;
    0) exit 0 ;;
    *) echo '无效选项'; sleep 1 ;;
  esac
done
EOF
chmod 755 /usr/local/bin/komari-menu

cat > /usr/local/bin/komari-status <<'EOF'
#!/usr/bin/env bash
echo '===== Komari ====='
systemctl status komari --no-pager
echo
echo '===== Caddy ====='
systemctl status caddy --no-pager
EOF
chmod 755 /usr/local/bin/komari-status

if curl -fsS --max-time 10 "http://127.0.0.1:${PORT}" >/dev/null 2>&1; then
  ok 'Komari 本地访问测试正常。'
else
  warn 'Komari 本地 HTTP 测试未返回成功，请检查日志。'
fi

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}                  安装完成${NC}"
echo -e "${GREEN}============================================================${NC}"
echo
printf '面板地址： https://%s\n' "$DOMAIN"
printf 'Komari：   127.0.0.1:%s\n' "$PORT"
printf '服务器IP： %s\n' "${IP:-请确认 VPS IP}"
echo
echo '必须确认：'
echo "  1. ${DOMAIN} 的 A/AAAA 记录已指向 VPS"
echo '  2. VPS/云厂商安全组放行 TCP 80、443'
echo "  3. 不需要开放 Komari ${PORT} 端口"
echo
echo '管理命令： komari-menu'
echo '状态命令： komari-status'
echo '日志命令： journalctl -u komari -f'
echo -e "${GREEN}============================================================${NC}"
