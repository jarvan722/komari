#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Komari 独立一键安装脚本
# 与 ssh_tool.eooce.com / sing-box / 现有 Nginx / Caddy 隔离
# ============================================================

INSTALL_DIR="/opt/komari"
BIN="${INSTALL_DIR}/komari"
SERVICE="/etc/systemd/system/komari.service"
CONFIG="/etc/komari-install.conf"
DEFAULT_PORT=25774
DEFAULT_CMD=km
REPO="komari-monitor/komari"

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; CYAN='\033[36m'; NC='\033[0m'
info(){ echo -e "${CYAN}[INFO]${NC} $*"; }
ok(){ echo -e "${GREEN}[ OK ]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
die(){ echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "请使用 root 用户运行。"
command -v systemctl >/dev/null 2>&1 || die "当前系统没有 systemd，不支持本脚本。"
command -v curl >/dev/null 2>&1 || {
  if command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y curl ca-certificates; \
  elif command -v dnf >/dev/null 2>&1; then dnf install -y curl ca-certificates; \
  elif command -v yum >/dev/null 2>&1; then yum install -y curl ca-certificates; \
  elif command -v apk >/dev/null 2>&1; then apk add --no-cache curl ca-certificates; \
  else die "找不到 curl，也无法识别包管理器。"; fi
}
command -v ss >/dev/null 2>&1 || {
  if command -v apt-get >/dev/null 2>&1; then apt-get install -y iproute2; \
  elif command -v dnf >/dev/null 2>&1; then dnf install -y iproute; \
  elif command -v yum >/dev/null 2>&1; then yum install -y iproute; \
  elif command -v apk >/dev/null 2>&1; then apk add --no-cache iproute2; fi
}

ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64|amd64) ARCH=amd64;;
  aarch64|arm64) ARCH=arm64;;
  i386|i686) ARCH=386;;
  riscv64) ARCH=riscv64;;
  loongarch64|loong64) ARCH=loong64;;
  *) die "不支持的 CPU 架构：$ARCH_RAW";;
esac

# 如果已安装，默认保留数据，只重新配置/覆盖二进制前先提示
if [[ -f "$CONFIG" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG" || true
fi

clear 2>/dev/null || true
echo "============================================================"
echo "             Komari 独立一键安装程序"
echo "============================================================"
echo
 echo "不会修改 ssh_tool.eooce.com、sing-box 配置或服务。"
echo "不会主动安装/接管 Nginx、Caddy，也不会占用 80/443。"
echo

read -r -p "请输入 Komari 面板域名/IP（例如 monitor.example.com）： " PANEL_DOMAIN
PANEL_DOMAIN="${PANEL_DOMAIN#http://}"; PANEL_DOMAIN="${PANEL_DOMAIN#https://}"; PANEL_DOMAIN="${PANEL_DOMAIN%%/*}"
[[ -n "$PANEL_DOMAIN" ]] || die "域名/IP 不能为空。"

while :; do
  read -r -p "请输入面板端口（默认 ${DEFAULT_PORT}）： " PANEL_PORT
  PANEL_PORT="${PANEL_PORT:-$DEFAULT_PORT}"
  [[ "$PANEL_PORT" =~ ^[0-9]+$ ]] && ((PANEL_PORT>=1 && PANEL_PORT<=65535)) || { warn "端口必须是 1-65535 的数字。"; continue; }
  if command -v ss >/dev/null 2>&1 && ss -lntH 2>/dev/null | awk '{print $4}' | grep -Eq ":${PANEL_PORT}$|\]:${PANEL_PORT}$"; then
    warn "端口 ${PANEL_PORT} 已被占用，请换一个。"; ss -lntp 2>/dev/null | grep -E ":${PANEL_PORT}([[:space:]]|$)" || true; continue
  fi
  break
done

while :; do
  read -r -p "请输入管理快捷命令（默认 ${DEFAULT_CMD}）： " PANEL_CMD
  PANEL_CMD="${PANEL_CMD:-$DEFAULT_CMD}"
  [[ "$PANEL_CMD" =~ ^[a-zA-Z0-9_-]+$ ]] || { warn "快捷命令只能包含字母、数字、_、-。"; continue; }
  case "$PANEL_CMD" in ssh|ss|sb|bash|sh) warn "${PANEL_CMD} 是常用命令，建议换一个。"; continue;; esac
  break
done

# 询问是否自动打开 UFW/Firewalld 端口；默认不改防火墙，避免影响用户现有规则
OPEN_FW="n"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
  read -r -p "检测到 UFW 已启用，是否放行 ${PANEL_PORT}/tcp？[y/N]： " OPEN_FW
elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -q running; then
  read -r -p "检测到 firewalld 已启用，是否放行 ${PANEL_PORT}/tcp？[y/N]： " OPEN_FW
fi

echo
echo "---------------- 安装参数 ----------------"
echo "域名/IP   : $PANEL_DOMAIN"
echo "监听端口  : $PANEL_PORT"
echo "快捷命令  : $PANEL_CMD"
echo "安装目录  : $INSTALL_DIR"
echo "服务名称  : komari.service"
echo "--------------------------------------------"
read -r -p "确认安装？[Y/n]： " CONFIRM
[[ "$CONFIRM" =~ ^[Nn]$ ]] && { echo "已取消。"; exit 0; }

mkdir -p "$INSTALL_DIR"
TMP="$(mktemp)"
URL="https://github.com/${REPO}/releases/latest/download/komari-linux-${ARCH}"
info "下载 Komari：$URL"
curl -fL --retry 3 --connect-timeout 15 "$URL" -o "$TMP" || { rm -f "$TMP"; die "Komari 下载失败。"; }
[[ -s "$TMP" ]] || { rm -f "$TMP"; die "下载文件为空。"; }
install -m 0755 "$TMP" "$BIN"
rm -f "$TMP"
ok "Komari 二进制安装完成。"

# 备份现有自定义服务文件（如果是本脚本以前创建的服务）
if [[ -f "$SERVICE" ]]; then cp -a "$SERVICE" "${SERVICE}.bak.$(date +%Y%m%d%H%M%S)"; fi

cat > "$SERVICE" <<EOF
[Unit]
Description=Komari Monitor Panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${BIN} server -l 0.0.0.0:${PANEL_PORT}
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

cat > "$CONFIG" <<EOF
PANEL_DOMAIN=$(printf '%q' "$PANEL_DOMAIN")
PANEL_PORT=$(printf '%q' "$PANEL_PORT")
PANEL_CMD=$(printf '%q' "$PANEL_CMD")
INSTALL_DIR=$(printf '%q' "$INSTALL_DIR")
EOF
chmod 600 "$CONFIG"

systemctl daemon-reload
systemctl enable komari.service >/dev/null
systemctl restart komari.service
sleep 2
systemctl is-active --quiet komari.service || {
  systemctl status komari.service --no-pager -l || true
  journalctl -u komari.service -n 80 --no-pager || true
  die "Komari 启动失败。"
}
ok "Komari 服务启动成功。"

# 管理菜单：独立命令，不覆盖 sb/ssh 等命令
cat > "/usr/local/bin/${PANEL_CMD}" <<EOF
#!/usr/bin/env bash
set -e
CONFIG="$CONFIG"
source "\$CONFIG" 2>/dev/null || true
SERVICE=komari.service

pause(){ read -r -p "按回车返回菜单..." _; }
while :; do
 clear 2>/dev/null || true
 echo "============================================================"
 echo "                    Komari 管理菜单"
 echo "============================================================"
 echo " 域名/IP：\${PANEL_DOMAIN:-$PANEL_DOMAIN}"
 echo " 端口：   \${PANEL_PORT:-$PANEL_PORT}"
 echo ""
 echo " 1. 查看状态"
 echo " 2. 启动"
 echo " 3. 重启"
 echo " 4. 停止"
 echo " 5. 实时日志"
 echo " 6. 最近日志"
 echo " 7. 查看端口"
 echo " 8. 修改端口"
 echo " 9. 查看配置"
 echo "10. 更新 Komari"
 echo "11. 卸载 Komari"
 echo " 0. 退出"
 echo "============================================================"
 read -r -p "请选择： " C
 case "\$C" in
 1) systemctl status "\$SERVICE" --no-pager -l; pause;;
 2) systemctl start "\$SERVICE"; systemctl --no-pager status "\$SERVICE" -l; pause;;
 3) systemctl restart "\$SERVICE"; systemctl --no-pager status "\$SERVICE" -l; pause;;
 4) systemctl stop "\$SERVICE"; pause;;
 5) echo 'Ctrl+C 退出日志'; journalctl -u "\$SERVICE" -f;;
 6) journalctl -u "\$SERVICE" -n 100 --no-pager; pause;;
 7) ss -lntp 2>/dev/null | grep -E ":\${PANEL_PORT}([[:space:]]|$)" || true; pause;;
 8)
   read -r -p "新的端口： " NP
   if [[ "\$NP" =~ ^[0-9]+$ ]] && ((NP>=1 && NP<=65535)); then
     if ss -lntH 2>/dev/null | awk '{print \$4}' | grep -Eq ":\${NP}$|\]:\${NP}$"; then echo '端口已占用'; pause; continue; fi
     sed -i "s/^PANEL_PORT=.*/PANEL_PORT=\$(printf '%q' "\$NP")/" "\$CONFIG"
     sed -i -E "s#(server -l 0\.0\.0\.0:)[0-9]+#\\1\$NP#" /etc/systemd/system/komari.service
     systemctl daemon-reload; systemctl restart komari.service
     echo "已修改为 \$NP"; pause
   else echo '端口无效'; pause; fi;;
 9) cat "\$CONFIG"; echo; systemctl cat "\$SERVICE"; pause;;
10)
   ARCH_RAW="\$(uname -m)"; case "\$ARCH_RAW" in x86_64|amd64) A=amd64;; aarch64|arm64) A=arm64;; i386|i686) A=386;; riscv64) A=riscv64;; loongarch64|loong64) A=loong64;; *) echo '不支持架构'; pause; continue;; esac
   U="https://github.com/komari-monitor/komari/releases/latest/download/komari-linux-\${A}"; T="\$(mktemp)"
   echo "下载：\$U"; curl -fL --retry 3 "\$U" -o "\$T" && systemctl stop "\$SERVICE" && cp -a "$BIN" "${BIN}.bak.\$(date +%Y%m%d%H%M%S)" && install -m 0755 "\$T" "$BIN" && rm -f "\$T" && systemctl start "\$SERVICE"; systemctl --no-pager status "\$SERVICE" -l; pause;;
11)
   read -r -p '输入 YES 确认删除 Komari 服务和程序（数据目录保留）： ' X
   if [[ "\$X" == YES ]]; then systemctl disable --now komari.service 2>/dev/null || true; rm -f /etc/systemd/system/komari.service; systemctl daemon-reload; rm -f "$BIN" "/usr/local/bin/${PANEL_CMD}"; echo 'Komari 服务和程序已删除。'; echo "数据目录仍保留：$INSTALL_DIR"; exit 0; fi;;
0) exit 0;;
*) echo '无效选项'; sleep 1;;
esac
done
EOF
chmod 0755 "/usr/local/bin/${PANEL_CMD}"

# 常用快捷子命令
for action in status start stop restart; do
  cat > "/usr/local/bin/${PANEL_CMD}-${action}" <<EOF
#!/usr/bin/env bash
systemctl ${action} komari.service
EOF
  chmod 0755 "/usr/local/bin/${PANEL_CMD}-${action}"
done
cat > "/usr/local/bin/${PANEL_CMD}-log" <<EOF
#!/usr/bin/env bash
journalctl -u komari.service -f
EOF
chmod 0755 "/usr/local/bin/${PANEL_CMD}-log"

# 防火墙：仅在用户明确同意时修改
if [[ "$OPEN_FW" =~ ^[Yy]$ ]]; then
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then ufw allow "${PANEL_PORT}/tcp"; fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -q running; then firewall-cmd --permanent --add-port="${PANEL_PORT}/tcp"; firewall-cmd --reload; fi
fi

IP="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"
echo
echo "============================================================"
ok "Komari 安装完成"
echo "============================================================"
echo "面板地址： http://${PANEL_DOMAIN}:${PANEL_PORT}"
echo "IP 地址：  http://${IP}:${PANEL_PORT}"
echo "管理命令： ${PANEL_CMD}"
echo "状态：     ${PANEL_CMD}-status"
echo "重启：     ${PANEL_CMD}-restart"
echo "日志：     ${PANEL_CMD}-log"
echo
echo "systemd：  systemctl status komari"
echo "安装目录： ${INSTALL_DIR}"
echo "============================================================"
echo
