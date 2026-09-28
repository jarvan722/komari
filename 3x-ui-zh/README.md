# 3X-UI 中文一键安装器

这是一个基于官方 MHSanaei/3x-ui 安装程序的中文一键安装脚本。

官方 3X-UI 当前已经原生提供简体中文界面，因此本项目不修改官方核心二进制或前端文件，避免破坏官方升级机制。

## 一键安装

    bash <(curl -Ls https://raw.githubusercontent.com/jarvan722/komari/main/3x-ui-zh/install.sh)

安装指定稳定版本：

    bash <(curl -Ls https://raw.githubusercontent.com/jarvan722/komari/main/3x-ui-zh/install.sh) v3.7.0

安装官方开发版：

    bash <(curl -Ls https://raw.githubusercontent.com/jarvan722/komari/main/3x-ui-zh/install.sh) dev-latest

## 安装后

官方安装程序继续负责安装 3X-UI、systemd 服务和 x-ui 管理命令，并生成随机登录凭据与访问路径。

本脚本额外提供：

    x-ui-zh

用于中文管理菜单、服务状态、安装结果、重启和版本查看。

## 中文界面

官方项目当前支持 13 种界面语言，其中包含中文（简体）和中文（繁體）。

首次进入面板后，在语言菜单选择“中文（简体）”即可。

## 上游

官方项目：MHSanaei/3x-ui
官方安装脚本：https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh

本项目仅提供中文安装包装层，不替代官方 3X-UI 核心项目。
