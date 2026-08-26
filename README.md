# Komari 独立一键安装脚本

这是一个独立的 Komari 安装器，目标是与现有 `ssh_tool.eooce.com`、sing-box、Nginx、Caddy 等环境尽量隔离。

## 一键安装

```bash
bash <(curl -Ls https://raw.githubusercontent.com/jarvan722/komari/main/install.sh)
```

安装时会询问：

- Komari 面板域名/IP
- 面板监听端口（默认 25774）
- 管理快捷命令（默认 `km`）

例如：

```text
域名：monitor.example.com
端口：25774
快捷命令：km
```

安装完成后：

```bash
km
```

进入管理菜单。

## 常用命令

```bash
km
km-status
km-start
km-stop
km-restart
km-log
```

## 服务

```bash
systemctl status komari
systemctl restart komari
journalctl -u komari -f
```

## 安装目录

```text
/opt/komari
```

## 说明

脚本不会主动安装或接管 Nginx/Caddy，也不会使用 80/443，因此可以将 Komari 监听在独立端口，再由你现有的反向代理提供 HTTPS。

脚本不会修改 sing-box 配置，也不会创建 `sb`、`ssh` 等快捷命令。
