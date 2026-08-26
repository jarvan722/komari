# Komari 独立一键安装脚本

这是一个面向 Debian/Ubuntu 等 systemd Linux 的 Komari 一键部署脚本。

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

如果输入域名，例如：

```text
jk.ddmk.kdns.fr
```

脚本会将 Komari 后端绑定到：

```text
127.0.0.1:25774
```

并配置：

```text
HTTPS 域名
   ↓
Nginx 443
   ↓
127.0.0.1:25774
   ↓
Komari
```

域名模式下会尝试自动使用 Certbot/Let's Encrypt 配置 HTTPS，并将 HTTP 重定向到 HTTPS。

如果 DNS 尚未指向本机，HTTPS 会跳过，待 DNS 生效后可手动执行：

```bash
certbot --nginx -d your-domain.example
```

## 与现有环境的兼容性

- 不修改 `ssh_tool.eooce.com` 的脚本。
- 不修改 sing-box 配置或服务。
- 不覆盖其他 Nginx `server` 配置，只创建 `/etc/nginx/conf.d/komari.conf`。
- 如果系统没有 Nginx，会安装 Nginx；如果已有 Nginx，则直接复用。
- Komari 后端默认只监听 `127.0.0.1`，不会直接暴露后端端口。
- 不使用 `sb`、`ssh`、`bash`、`sh` 等常用快捷命令。

## 管理菜单

默认快捷命令：

```bash
km
```

菜单支持：

1. 查看状态
2. 启动
3. 重启
4. 停止
5. 实时日志
6. 最近日志
7. 查看监听端口
8. 修改后端端口
9. 查看配置
10. 安装/配置 Agent
11. 查看 Agent 状态
12. 重启 Agent
13. Agent 日志
14. 更新 Komari
15. 更新 Agent
16. 检查 HTTPS
17. 测试 HTTPS 续期
18. 卸载 Komari

## Agent

在 `km` 菜单选择 `10`，输入 Komari 面板生成的 Agent Token。

脚本使用官方 Komari Agent 安装器，并支持设置每月流量统计重置日期。

例如默认每月 1 日重置：

```text
1
```

输入 `0` 可关闭月度重置。

## 常用快捷命令

```bash
km
km-status
km-start
km-stop
km-restart
km-log
```

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

如果服务器已有 Nginx 站点，脚本不会删除其他配置；配置失败时会停止在 `nginx -t`，避免加载错误配置。
