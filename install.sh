#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Komari 一键安装脚本（最终版）
#
# 功能：
#   - 自定义域名/IP
#   - 自定义后端端口
#   - 自定义管理快捷命令
#   - Komari 仅监听 127.0.0.1，避免后端端口暴露公网
#   - 自动配置 Nginx 反向代理
#   - 域名模式自动申请 Let's Encrypt HTTPS（可选择跳过）
#   - HTTP 自动跳转 HTTPS
#   - 保留现有 Nginx / Sing-box 配置，不覆盖其他 server
#   - Agent 一键安装、月流量重置
#   - 状态/启动/停止/重启/日志/更新/卸载
#   - 不使用 sb、ssh 等快捷命令
# ============================================================

set +H

INSTALL_DIR="/opt/komari"
BIN="${INSTALL_DIR}/komari"
SERVICE_FILE="/etc/systemd/system/komari.service"
CONFIG="/etc/komari-install.conf"
NGINX_CONF="/etc/nginx/conf.d/komari.conf"
DEFAULT_PORT=25774
DEFAULT_CMD=km
REPO="komari-monitor/komari"
AGENT_INSTALL="https://raw.githubusercontent.com/komari-monitor/komari-agent/main/install.sh"

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; CYAN='\033[36m'; NC='\033[0m'
info(){ echo -e "${CYAN}[INFO]${NC} $*"; }
ok(){ echo -e "${GREEN}[ OK ]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
die(){ echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

check_root(){ [[ $EUID -eq 0 ]] || die "请使用 root 用户运行。"; }
check_systemd(){ command -v systemctl >/dev/null 2>&1 || die "当前系统没有 systemd。"; }

install_pkg(){
    local pkgs=("$@")
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y "${pkgs[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "${pkgs[@]}"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "${pkgs[@]}"
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache "${pkgs[@]}"
    else
        die "无法识别包管理器，请手动安装：${pkgs[*]}"
    fi
}

prepare_deps(){
    command -v curl >/dev/null 2>&1 || install_pkg curl ca-certificates
    command -v ss >/dev/null 2>&1 || install_pkg iproute2
    command -v nginx >/dev/null 2>&1 || install_pkg nginx
    command -v certbot >/dev/null 2>&1 || install_pkg certbot python3-certbot-nginx || true
}

detect_arch(){
    case "$(uname -m)" in
        x86_64|amd64) ARCH=amd64;;
        aarch64|arm64) ARCH=arm64;;
        i386|i686) ARCH=386;;
        riscv64) ARCH=riscv64;;
        loongarch64|loong64) ARCH=loong64;;
        *) die "不支持的 CPU 架构：$(uname -m)";;
    esac
}

input_domain(){
    while :; do
        read -r -p "请输入 Komari 面板域名/IP： " PANEL_DOMAIN
        PANEL_DOMAIN="${PANEL_DOMAIN#http://}"
        PANEL_DOMAIN="${PANEL_DOMAIN#https://}"
        PANEL_DOMAIN="${PANEL_DOMAIN%%/*}"
        [[ -n "$PANEL_DOMAIN" ]] && break
        warn "域名/IP 不能为空。"
    done
}

input_port(){
    while :; do
        read -r -p "请输入 Komari 后端端口（默认 ${DEFAULT_PORT}）： " PANEL_PORT
        PANEL_PORT="${PANEL_PORT:-$DEFAULT_PORT}"
        [[ "$PANEL_PORT" =~ ^[0-9]+$ ]] && ((PANEL_PORT>=1 && PANEL_PORT<=65535)) || { warn "端口必须是 1-65535。"; continue; }
        if ss -lntH 2>/dev/null | awk '{print $4}' | grep -Eq ":${PANEL_PORT}$|\]:${PANEL_PORT}$"; then
            warn "端口 ${PANEL_PORT} 已被占用。"
            ss -lntp 2>/dev/null | grep -E ":${PANEL_PORT}([[:space:]]|$)" || true
            continue
        fi
        break
    done
}

input_cmd(){
    while :; do
        read -r -p "请输入管理快捷命令（默认 ${DEFAULT_CMD}）： " PANEL_CMD
        PANEL_CMD="${PANEL_CMD:-$DEFAULT_CMD}"
        [[ "$PANEL_CMD" =~ ^[a-zA-Z0-9_-]+$ ]] || { warn "只能使用字母、数字、_、-。"; continue; }
        case "$PANEL_CMD" in ssh|ss|sb|bash|sh|curl|wget) warn "${PANEL_CMD} 是常用命令，请换一个。"; continue;; esac
        if command -v "$PANEL_CMD" >/dev/null 2>&1; then
            warn "${PANEL_CMD} 已存在。"
            read -r -p "是否覆盖这个命令？[y/N]： " A
            [[ "$A" =~ ^[Yy]$ ]] || continue
        fi
        break
    done
}

is_ip(){ [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$1" == *:* ]]; }

save_config(){
    cat > "$CONFIG" <<EOF
PANEL_DOMAIN=$(printf '%q' "$PANEL_DOMAIN")
PANEL_PORT=$(printf '%q' "$PANEL_PORT")
PANEL_CMD=$(printf '%q' "$PANEL_CMD")
INSTALL_DIR=$(printf '%q' "$INSTALL_DIR")
EOF
    chmod 600 "$CONFIG"
}

backup_file(){
    local f="$1"
    [[ -f "$f" ]] && cp -a "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
}

download_komari(){
    mkdir -p "$INSTALL_DIR"
    local tmp url
    tmp="$(mktemp)"
    url="https://github.com/${REPO}/releases/latest/download/komari-linux-${ARCH}"
    info "下载 Komari Stable：$url"
    curl -fL --retry 3 --connect-timeout 15 "$url" -o "$tmp" || { rm -f "$tmp"; die "Komari 下载失败。"; }
    [[ -s "$tmp" ]] || { rm -f "$tmp"; die "下载文件为空。"; }
    [[ -f "$BIN" ]] && cp -a "$BIN" "${BIN}.backup.$(date +%Y%m%d%H%M%S)"
    install -m 0755 "$tmp" "$BIN"
    rm -f "$tmp"
}

create_service(){
    backup_file "$SERVICE_FILE"
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Komari Monitor Panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${BIN} server -l 127.0.0.1:${PANEL_PORT}
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable komari.service >/dev/null
    systemctl restart komari.service
    sleep 2
    systemctl is-active --quiet komari.service || {
        systemctl status komari.service --no-pager -l || true
        journalctl -u komari.service -n 80 --no-pager || true
        die "Komari 启动失败。"
    }
    ok "Komari 已启动，监听 127.0.0.1:${PANEL_PORT}。"
}

configure_nginx(){
    command -v nginx >/dev/null 2>&1 || die "Nginx 未安装。"
    backup_file "$NGINX_CONF"

    cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${PANEL_DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:${PANEL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_buffering off;
        client_max_body_size 50M;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF

    nginx -t || die "Nginx 配置检查失败，未重载 Nginx。"
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl reload nginx || systemctl restart nginx
    ok "Nginx 反向代理已配置。"
}

setup_https(){
    if is_ip "$PANEL_DOMAIN"; then
        warn "当前填写的是 IP，Let's Encrypt 无法为 IP 自动申请证书。"
        echo "当前访问：http://${PANEL_DOMAIN}:80"
        return 0
    fi

    echo
    read -r -p "是否自动申请 HTTPS 证书并启用 HTTP→HTTPS？[Y/n]： " HTTPS_YN
    HTTPS_YN="${HTTPS_YN:-Y}"
    [[ "$HTTPS_YN" =~ ^[Yy]$ ]] || { warn "已跳过 HTTPS。以后可执行：certbot --nginx -d ${PANEL_DOMAIN}"; return 0; }

    if ! command -v certbot >/dev/null 2>&1; then
        warn "Certbot 未安装，尝试自动安装。"
        install_pkg certbot python3-certbot-nginx || install_pkg certbot python3-certbot-nginx
    fi

    local resolved server_ip
    resolved="$(getent ahostsv4 "$PANEL_DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')"
    server_ip="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"

    if [[ -z "$resolved" ]]; then
        warn "无法解析 ${PANEL_DOMAIN}，跳过自动 HTTPS。"
        warn "确认 DNS 解析后执行：certbot --nginx -d ${PANEL_DOMAIN}"
        return 0
    fi

    if [[ -n "$server_ip" && "$resolved" != "$server_ip" ]]; then
        warn "DNS 检查：${PANEL_DOMAIN} → ${resolved}，本机公网 IPv4 → ${server_ip}。"
        warn "DNS 尚未指向本机，跳过 Certbot，避免申请失败。"
        return 0
    fi

    info "申请 Let's Encrypt 证书：${PANEL_DOMAIN}"
    if certbot --nginx -d "$PANEL_DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --redirect; then
        ok "HTTPS 配置成功：https://${PANEL_DOMAIN}"
    else
        warn "Certbot 申请失败。Komari 和 HTTP 反代仍保持可用。"
        warn "DNS/80 端口确认无误后可再次执行：certbot --nginx -d ${PANEL_DOMAIN}"
    fi
}

create_manager(){
    cat > "/usr/local/bin/${PANEL_CMD}" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
CONFIG="/etc/komari-install.conf"
SERVICE="komari.service"
BIN="/opt/komari/komari"
source "$CONFIG" 2>/dev/null || true
pause(){ read -r -p "按回车返回菜单..." _; }
arch(){ case "$(uname -m)" in x86_64|amd64) echo amd64;; aarch64|arm64) echo arm64;; i386|i686) echo 386;; riscv64) echo riscv64;; loongarch64|loong64) echo loong64;; *) return 1;; esac; }
while :; do
 clear 2>/dev/null || true
 echo "============================================================"
 echo "                    Komari 管理菜单"
 echo "============================================================"
 echo " 域名/IP：${PANEL_DOMAIN:-未设置}"
 echo " 后端端口：${PANEL_PORT:-未设置}"
 echo
 echo " 1. 查看 Komari 状态"
 echo " 2. 启动 Komari"
 echo " 3. 重启 Komari"
 echo " 4. 停止 Komari"
 echo " 5. 实时日志"
 echo " 6. 最近日志"
 echo " 7. 查看监听端口"
 echo " 8. 修改后端端口"
 echo " 9. 查看配置"
 echo "10. 安装/配置 Agent"
 echo "11. 查看 Agent 状态"
 echo "12. 重启 Agent"
 echo "13. Agent 日志"
 echo "14. 更新 Komari"
 echo "15. 更新 Agent"
 echo "16. 检查 HTTPS"
 echo "17. 续期 HTTPS"
 echo "18. 卸载 Komari"
 echo " 0. 退出"
 echo "============================================================"
 read -r -p "请选择： " C
 case "$C" in
 1) systemctl status "$SERVICE" --no-pager -l; pause;;
 2) systemctl start "$SERVICE"; systemctl --no-pager status "$SERVICE" -l; pause;;
 3) systemctl restart "$SERVICE"; systemctl --no-pager status "$SERVICE" -l; pause;;
 4) systemctl stop "$SERVICE"; pause;;
 5) echo 'Ctrl+C 退出日志'; journalctl -u "$SERVICE" -f;;
 6) journalctl -u "$SERVICE" -n 100 --no-pager; pause;;
 7) ss -lntp 2>/dev/null | grep -E ":${PANEL_PORT}([[:space:]]|$)" || true; pause;;
 8)
   read -r -p "新的后端端口： " NP
   if [[ "$NP" =~ ^[0-9]+$ ]] && ((NP>=1 && NP<=65535)); then
     if ss -lntH 2>/dev/null | awk '{print $4}' | grep -Eq ":${NP}$|\]:${NP}$"; then echo "端口已占用"; pause; continue; fi
     sed -i "s/^PANEL_PORT=.*/PANEL_PORT=$(printf '%q' "$NP")/" "$CONFIG"
     sed -i -E "s#server -l 127\.0\.0\.1:[0-9]+#server -l 127.0.0.1:${NP}#" /etc/systemd/system/komari.service
     if [[ -f /etc/nginx/conf.d/komari.conf ]]; then sed -i -E "s#proxy_pass http://127\.0\.0\.1:[0-9]+;#proxy_pass http://127.0.0.1:${NP};#" /etc/nginx/conf.d/komari.conf; nginx -t && systemctl reload nginx; fi
     systemctl daemon-reload; systemctl restart "$SERVICE"
     PANEL_PORT="$NP"; echo "已修改为 $NP"; pause
   else echo "端口无效"; pause; fi;;
 9) echo '--- 安装配置 ---'; cat "$CONFIG"; echo; echo '--- systemd ---'; systemctl cat "$SERVICE"; echo; echo '--- Nginx ---'; [[ -f /etc/nginx/conf.d/komari.conf ]] && cat /etc/nginx/conf.d/komari.conf || echo '未配置'; pause;;
10)
   echo; read -r -p "请输入 Agent Token： " TOKEN
   [[ -n "$TOKEN" ]] || { echo "Token 不能为空"; pause; continue; }
   read -r -p "每月哪一天重置流量统计？[默认1，输入0关闭]： " ROTATE
   ROTATE="${ROTATE:-1}"
   bash <(curl -fsSL https://raw.githubusercontent.com/komari-monitor/komari-agent/main/install.sh) -e "https://${PANEL_DOMAIN}" -t "$TOKEN" --month-rotate "$ROTATE"
   pause;;
11) systemctl status komari-agent.service --no-pager -l 2>/dev/null || systemctl status komari-agent --no-pager -l 2>/dev/null || echo 'Agent 未安装'; pause;;
12) systemctl restart komari-agent.service 2>/dev/null || systemctl restart komari-agent 2>/dev/null || true; systemctl status komari-agent.service --no-pager -l 2>/dev/null || true; pause;;
13) journalctl -u komari-agent.service -f 2>/dev/null || journalctl -u komari-agent -f 2>/dev/null;;
14)
   A="$(arch)" || { echo '不支持的架构'; pause; continue; }
   U="https://github.com/komari-monitor/komari/releases/latest/download/komari-linux-${A}"; T="$(mktemp)"
   echo "下载：$U"
   if curl -fL --retry 3 "$U" -o "$T"; then systemctl stop "$SERVICE"; cp -a "$BIN" "${BIN}.backup.$(date +%Y%m%d%H%M%S)"; install -m 0755 "$T" "$BIN"; rm -f "$T"; systemctl start "$SERVICE"; echo '更新完成'; else echo '下载失败'; rm -f "$T"; fi
   systemctl --no-pager status "$SERVICE" -l; pause;;
15)
   echo '使用官方 Agent 安装器更新/重装。'; bash <(curl -fsSL https://raw.githubusercontent.com/komari-monitor/komari-agent/main/install.sh); pause;;
16) command -v curl >/dev/null 2>&1 && curl -Ik "https://${PANEL_DOMAIN}" || true; pause;;
17) command -v certbot >/dev/null 2>&1 && certbot renew --dry-run || true; pause;;
18)
   read -r -p '输入 YES 确认删除 Komari 服务、程序和管理命令（Nginx/证书/数据保留）： ' X
   if [[ "$X" == YES ]]; then
     systemctl disable --now "$SERVICE" 2>/dev/null || true
     rm -f /etc/systemd/system/komari.service
     systemctl daemon-reload
     rm -f "$BIN" "/usr/local/bin/${PANEL_CMD}"
     for F in "/usr/local/bin/${PANEL_CMD}-status" "/usr/local/bin/${PANEL_CMD}-start" "/usr/local/bin/${PANEL_CMD}-stop" "/usr/local/bin/${PANEL_CMD}-restart" "/usr/local/bin/${PANEL_CMD}-log"; do rm -f "$F"; done
     echo 'Komari 主程序和服务已删除。'; echo "数据目录保留：$INSTALL_DIR"; exit 0
   fi;;
 0) exit 0;;
 *) echo '无效选项'; sleep 1;;
esac
done
EOF
    chmod 0755 "/usr/local/bin/${PANEL_CMD}"

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
}

main(){
    check_root
    check_systemd
    prepare_deps
    detect_arch

    clear 2>/dev/null || true
    echo "============================================================"
    echo "              Komari 一键部署最终版"
    echo "============================================================"
    echo "不会修改 ssh_tool.eooce.com、Sing-box 配置。"
    echo "不会覆盖现有 Nginx 的其他站点配置。"
    echo "Komari 后端默认仅监听 127.0.0.1。"
    echo

    input_domain
    input_port
    input_cmd

    echo
    echo "---------------- 安装参数 ----------------"
    echo "域名/IP：$PANEL_DOMAIN"
    echo "后端端口：$PANEL_PORT"
    echo "快捷命令：$PANEL_CMD"
    echo "-------------------------------------------"
    read -r -p "确认安装？[Y/n]： " OKAY
    [[ "$OKAY" =~ ^[Nn]$ ]] && exit 0

    save_config
    download_komari
    create_service
    create_manager
    configure_nginx
    setup_https

    echo
    echo "============================================================"
    ok "Komari 一键部署完成"
    echo "============================================================"
    echo "面板域名： https://${PANEL_DOMAIN}"
    echo "后端监听： 127.0.0.1:${PANEL_PORT}"
    echo "管理命令： ${PANEL_CMD}"
    echo
    echo "常用命令："
    echo "  ${PANEL_CMD}"
    echo "  ${PANEL_CMD}-status"
    echo "  ${PANEL_CMD}-restart"
    echo "  ${PANEL_CMD}-log"
    echo
    echo "Agent：进入 ${PANEL_CMD} → 10"
    echo "============================================================"
}

main "$@"
