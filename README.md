# Komari 独立一键安装脚本

一个面向 Debian/Ubuntu 等 systemd Linux 的 Komari 一键部署脚本。

## 一键安装

```bash
bash <(curl -Ls https://raw.githubusercontent.com/jarvan722/komari/main/install.sh)
```

安装时会询问：

- Komari 面板域名/IP
- Komari 后端端口（默认 `25774`）
- 管理快捷命令（默认 `km`）
- 是否自动申请 HTTPS

## 最终部署结构

输入你自己的域名，例如 `monitor.example.com`，脚本会将 Komari 后端绑定到：

```text
127.0.0.1:<自定义端口>
```

并配置：

```text
HTTPS 域名
   ↓
Nginx 443
   ↓
127.0.0.1:<自定义端口>
   ↓
Komari
```

域名模式下会尝试自动使用 Certbot/Let's Encrypt 配置 HTTPS，并将 HTTP 重定向到 HTTPS。

## 隐私与兼容性

- 仓库不包含任何用户个人域名、IP、Token 或密码。
- 域名、端口和快捷命令只保存在安装目标服务器的 `/etc/komari-install.conf`。
- 不修改其他 Nginx `server` 配置，只创建或更新 `/etc/nginx/conf.d/komari.conf`。
- 如果系统没有 Nginx，会安装 Nginx；如果已有 Nginx，则直接复用。
- Komari 后端默认只监听 `127.0.0.1`，不会直接暴露后端端口。
- 不使用 `sb`、`ssh`、`bash`、`sh` 等常用快捷命令作为默认管理命令。

## 管理菜单

默认快捷命令：

```bash
km
```

菜单支持状态、启动、停止、重启、日志、端口管理、Agent、更新、HTTPS 检查/续期和卸载等操作。

## Agent

在 `km` 菜单选择 Agent 安装/配置，并输入 Komari 面板生成的 Agent Token。支持设置每月流量统计重置日期。

## 服务管理

```bash
systemctl status komari --no-pager -l
systemctl restart komari
journalctl -u komari -f
```

## 安装目录

```text
/opt/komari
```

## 注意

第一次使用域名部署时，请确保 DNS A/AAAA 记录已经指向服务器，并且公网 TCP 80/443 可访问，否则 Let's Encrypt 无法完成 HTTP 验证。

本仓库是通用安装器。请勿在公开仓库提交自己的域名、IP、Token、密码或其他敏感信息。
