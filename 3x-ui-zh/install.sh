#!/usr/bin/env bash
set -Eeuo pipefail
readonly OFFICIAL_INSTALL="https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh"
readonly INSTALL_RESULT="/etc/x-ui/install-result.env"
log(){ printf '\033[1;32m[3X-UI 中文版]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }
[[ "$(id -u)" -eq 0 ]] || die "请使用 root 运行。"
if ! command -v curl >/dev/null 2>&1; then
  log "正在安装 curl..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y curl ca-certificates
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl ca-certificates
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl ca-certificates
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache curl ca-certificates bash
  else
    die "无法自动安装 curl，请先安装 curl 后重试。"
  fi
fi
VERSION="${1:-latest}"
case "$VERSION" in
  latest|"") OFFICIAL_ARGS=() ;;
  dev-latest) OFFICIAL_ARGS=(dev-latest) ;;
  v[0-9]*) OFFICIAL_ARGS=("$VERSION") ;;
  *) die "版本参数无效：$VERSION。示例：latest、dev-latest、v3.7.0" ;;
esac
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
log "正在获取官方 3X-UI 安装脚本..."
curl -fL --retry 3 --connect-timeout 15 "$OFFICIAL_INSTALL" -o "$TMP" || die "无法下载官方安装脚本。"
grep -Eq '3x-ui|3X-UI|MHSanaei' "$TMP" || die "下载内容校验失败，已停止安装。"
log "开始安装官方 3X-UI：$VERSION"
bash "$TMP" "${OFFICIAL_ARGS[@]}"
cat >/usr/local/bin/x-ui-zh <<'EOF'
#!/usr/bin/env bash
set -e
echo "=============================================="
echo "           3X-UI 中文管理助手"
echo "=============================================="
echo "1) 打开 3X-UI 管理菜单"
echo "2) 查看服务状态"
echo "3) 查看安装结果"
echo "4) 重启 3X-UI"
echo "5) 查看版本"
echo "0) 退出"
read -r -p "请选择 [0-5]: " n
case "$n" in
  1) exec x-ui ;;
  2) systemctl status x-ui --no-pager ;;
  3) [[ -f /etc/x-ui/install-result.env ]] && cat /etc/x-ui/install-result.env || echo "未找到安装结果文件。" ;;
  4) systemctl restart x-ui && systemctl --no-pager --full status x-ui ;;
  5) x-ui version 2>/dev/null || /usr/local/x-ui/x-ui version 2>/dev/null || echo "请在面板中查看版本。" ;;
  0) exit 0 ;;
  *) echo "无效选择。" ;;
esac
EOF
chmod +x /usr/local/bin/x-ui-zh
echo
log "安装完成。"
echo "官方 3X-UI 已原生提供简体中文界面。首次打开面板后，在语言菜单选择：中文（简体）。"
echo "中文管理助手：x-ui-zh"
echo "官方管理命令：x-ui"
if [[ -f "$INSTALL_RESULT" ]]; then
  echo
  echo "========== 官方安装结果 =========="
  cat "$INSTALL_RESULT"
fi
