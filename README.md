# Komari 一键 HTTPS 安装脚本

适用于 Debian/Ubuntu + systemd VPS 的 Komari Monitor 一键安装器。

**最终部署方案：VLESS Reality 独占 TCP 443；Komari 后端仅监听 127.0.0.1；Caddy 固定提供 HTTPS 2087。**  
如果系统已有运行中的 Nginx，安装器使用 Nginx 的 80 端口辅助 Let's Encrypt HTTP-01 验证；不会修改 Nginx 的 443。

## 一键安装

推荐直接执行：

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/jarvan722/komari/main/install-https.sh?v=$(date +%s)")
```

如果遇到 CDN/缓存导致脚本版本异常，也可以使用：

```bash
curl -fsSL -H 'Cache-Control: no-cache' "https://raw.githubusercontent.com/jarvan722/komari/main/install-https.sh?$(date +%s%N)" -o /tmp/komari-install.sh
bash /tmp/komari-install.sh
```

安装过程中会询问：

- Komari 内部端口，默认 `25774`
- HTTPS 域名
- 是否确认安装

脚本已针对 `curl | bash` / 进程替换场景使用 `/dev/tty` 读取交互输入，避免域名输入被管道 stdin 干扰。

## 最终架构

```text
Internet
   │
   ├── TCP 443 ── VLESS Reality
   │
   └── TCP 2087 ── Caddy HTTPS
                       │
                       ▼
                 127.0.0.1:25774
                       │
                       ▼
                    Komari

TCP 80：仅用于 ACME/证书验证
```

### 端口职责

| 端口 | 用途 | Komari 是否占用 |
|---|---|---|
| 80 | Let's Encrypt HTTP-01 / Nginx 或 Caddy ACME | 间接使用 |
| 443 | VLESS Reality | **否** |
| 2087 | Komari HTTPS | **是** |
| 25774 | Komari 后端 | **仅本机** |

**注意：安装器不会接管、配置或放行 443。443 保留给你的 VLESS Reality。**

## HTTPS / 证书

### 已运行 Nginx

如果检测到 Nginx 正在运行：

1. 安装 Certbot
2. 创建 `/etc/nginx/conf.d/komari-acme.conf`
3. Nginx 在 80 提供指定域名的 ACME 验证目录
4. Certbot 申请 Let's Encrypt 证书
5. Caddy 使用该证书在 2087 提供 HTTPS
6. Certbot 自动续期后 reload Caddy

Nginx **不会**被配置为 Komari 反向代理，也不会接管 443。

### 没有运行 Nginx

由 Caddy 负责：

- 80：ACME / HTTP
- 2087：HTTPS
- 443：完全不使用

Caddy 配置：

```text
/etc/caddy/Caddyfile
```

如果系统检测到**正在运行的 Caddy**，安装器会停止继续执行，以避免覆盖其他网站的 Caddy 配置。

## 安全设计

Komari systemd 服务：

```text
127.0.0.1:<端口>
```

默认：

```text
127.0.0.1:25774
```

因此无需向公网开放 Komari 后端端口。

如果 UFW 已启用，安装器仅自动放行：

```text
TCP 80
TCP 2087
```

不会自动放行 TCP 443。

云服务器安全组同样建议按实际用途开放 80/2087，并由你现有的 Reality 配置负责 443。

## DNS 要求

使用 HTTPS 域名之前：

1. 将域名 A 记录解析到 VPS IPv4。
2. 如果有 AAAA 记录，确保 IPv6 确实可用且指向该 VPS；否则删除错误 AAAA。
3. 确保公网 TCP 80 和 2087 可访问。
4. 443 由 VLESS Reality 使用，不要让其他服务抢占。

安装完成后的面板：

```text
https://你的域名:2087
```

例如：

```text
https://jk.ddmk.kdns.fr:2087
```

## 管理命令

安装完成后：

```bash
komari-menu
```

菜单：

```text
 1. Komari 状态
 2. 启动 Komari
 3. 停止 Komari
 4. 重启 Komari
 5. Komari 日志
 6. 查看监听端口
 7. Web 服务状态
 8. 重启 Web 服务
 9. Web 服务日志
10. 查看 Komari 服务配置
11. 查看 Web 配置
12. 测试 HTTPS
 0. 退出
```

快速状态：

```bash
komari-status
```

## 常用排障

### Komari

```bash
systemctl status komari --no-pager -l
journalctl -u komari -n 100 --no-pager
```

### Caddy

```bash
systemctl status caddy --no-pager -l
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
journalctl -u caddy -n 100 --no-pager
```

### Nginx

```bash
systemctl status nginx --no-pager -l
nginx -t
```

### 查看关键端口

```bash
ss -lntp | grep -E ':(80|443|2087|25774)[[:space:]]'
```

正常情况下：

- `25774` → Komari，仅 127.0.0.1
- `2087` → Caddy
- `80` → Nginx 或 Caddy，用于 ACME
- `443` → VLESS Reality

如果你使用自定义 Komari 端口，将命令中的 `25774` 替换成实际端口。

## 重装 / 重复执行

脚本在替换 Komari 二进制和 systemd 服务文件前会创建带时间戳的备份。

Caddy 如果已经处于运行状态，脚本不会接管，避免破坏已有网站。

## 安装目录

```text
/opt/komari
/etc/systemd/system/komari.service
/etc/caddy/Caddyfile
```

## 隐私

请不要向公开 GitHub 仓库提交：

- VPS IP
- 密码
- 私钥
- Komari Agent Token
- API Token
- 其他敏感信息

安装时输入的域名、IP 和端口不会写入仓库。

## 项目文件

- `install-https.sh`：一键安装脚本
- `README.md`：使用说明

## License

本仓库中的安装脚本按仓库实际许可证使用。Komari 本身请遵循其上游项目的许可证和使用条款。
