# Komari 一键 HTTPS 安装脚本

适用于 Debian/Ubuntu + systemd VPS 的 Komari Monitor 一键安装器。

本项目重点针对已经安装 Nginx、Caddy 或其他服务的 VPS 做兼容处理：**优先复用现有 Nginx，避免 Nginx 与 Caddy 同时抢占 80/443 端口。**

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/jarvan722/komari/main/install-https.sh)
```

安装过程中会交互询问：

- Komari 内部端口，默认 `25774`
- HTTPS 自定义域名
- 是否确认安装

例如：

```text
Komari 内部端口 [25774]: 25774
HTTPS 域名（例如 jk.example.com）：jk.example.com
```

## 推荐部署结构

### 已有 Nginx

如果 VPS 已经运行 Nginx，安装器会自动使用 Nginx：

```text
                 Internet
                    │
                    ▼
              Nginx :80/:443
                    │
                    ▼
          https://your-domain.com
                    │
                    ▼
          127.0.0.1:25774
                    │
                    ▼
                  Komari
```

不会再启动 Caddy，因此不会出现：

```text
listen tcp :80: bind: address already in use
```

### 没有 Nginx

如果系统没有正在运行的 Nginx，则自动安装并使用 Caddy：

```text
Internet
   ↓
Caddy :80/:443
   ↓
HTTPS 自动证书
   ↓
127.0.0.1:<自定义端口>
   ↓
Komari
```

## HTTPS

### Nginx 模式

安装器会自动：

1. 创建 Komari Nginx 反向代理配置
2. 安装 Certbot（如果系统没有）
3. 申请 Let's Encrypt 证书
4. 配置 HTTP → HTTPS 跳转
5. 自动 reload Nginx

配置文件：

```text
/etc/nginx/conf.d/komari.conf
```

### Caddy 模式

Caddy 自动申请和续期 HTTPS 证书。

配置文件：

```text
/etc/caddy/Caddyfile
```

## 安全设计

Komari 后端默认只监听：

```text
127.0.0.1:<端口>
```

例如：

```text
127.0.0.1:25774
```

因此**不需要把 25774 开放到公网**。

公网只需要放行：

```text
TCP 80
TCP 443
```

如果启用了 UFW，安装器会自动放行 80/443。

## 管理菜单

安装完成后：

```bash
komari-menu
```

菜单包含：

```text
1. 查看 Komari 状态
2. 启动 Komari
3. 停止 Komari
4. 重启 Komari
5. 查看 Komari 日志
6. 查看监听端口
7. 查看 Web 服务状态
8. 重启 Web 服务
9. 查看 Web 服务日志
10. 查看 HTTPS 配置
11. 查看 Komari 服务配置
```

快速查看状态：

```bash
komari-status
```

## Komari 服务

服务文件：

```text
/etc/systemd/system/komari.service
```

常用命令：

```bash
systemctl status komari --no-pager -l
systemctl restart komari
journalctl -u komari -f
```

## 安装目录

```text
/opt/komari
```

Komari 程序：

```text
/opt/komari/komari
```

## DNS 要求

使用 HTTPS 域名之前，请先将域名解析到 VPS：

```text
your-domain.com → VPS IP
```

如果存在 AAAA 记录，请确保 IPv6 也确实指向该 VPS；否则建议删除错误的 AAAA 记录。

同时确保 VPS 服务商安全组/防火墙允许：

```text
TCP 80
TCP 443
```

## 与现有 Nginx/Caddy 共存

脚本会自动检测 Web 服务：

- 已有 Nginx → 优先使用 Nginx
- 没有 Nginx → 使用 Caddy
- Komari 后端不直接暴露公网
- 修改配置前会尽量创建备份

如果你已经有其他网站，请特别注意域名不要与现有 Nginx/Caddy 网站配置冲突。

## 故障排查

### Komari 状态

```bash
systemctl status komari --no-pager -l
```

### Komari 日志

```bash
journalctl -u komari -n 100 --no-pager
```

### Nginx 状态

```bash
systemctl status nginx --no-pager -l
```

### Nginx 配置检查

```bash
nginx -t
```

### Caddy 配置检查

```bash
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
```

### 查看 80/443/Komari 端口

```bash
ss -lntp | grep -E ':(80|443|25774)[[:space:]]'
```

如果使用了其他自定义端口，将 `25774` 替换成实际端口。

## 隐私

请不要向公开 GitHub 仓库提交：

- 个人域名
- VPS IP
- Komari Agent Token
- 密码
- 私钥
- API Token
- 其他敏感信息

安装时输入的域名和端口不会写入本 README。

## 项目文件

主要安装脚本：

```text
install-https.sh
```

一键安装：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/jarvan722/komari/main/install-https.sh)
```

## License

本仓库中的安装脚本按仓库实际许可证使用。Komari 本身请遵循其上游项目的许可证和使用条款。
