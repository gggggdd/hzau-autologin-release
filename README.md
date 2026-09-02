# HZAU Campus Network Auto Login（一键安装版）

华中农业大学校园网（深澜 Srun 认证系统）开机自动认证工具 —— **打包分发版**。

本仓库是 [hzau-autologin](https://github.com/gggggdd/hzau-autologin) 的发行仓库：
协议实现与源码分析在原仓库，本仓库专注交付一个 **不需要 Python 环境、双击即可部署** 的版本。

> 仅供学习交流，请遵守学校网络使用相关规定。

## 一键安装（华农学生适用）

1. 从 [Releases](https://github.com/gggggdd/hzau-autologin-release/releases) 下载
   `hzau-autologin-*-win64.zip`，解压到任意位置
2. 双击 `install.bat`（会自动申请管理员权限，仅需一次 UAC）
3. 按提示输入学号和校园网密码，装完立即认证一次验证配置

不想下 zip 也可以在 PowerShell 里一行安装（自动下载最新 Release 的 exe）：

```powershell
irm https://raw.githubusercontent.com/gggggdd/hzau-autologin-release/main/installer/install.ps1 | iex
```

装好后无需任何操作：登录 Windows 自动认证，并每 30 分钟巡检一次，断线自动重连。

- **SmartScreen 提示"未知发布者"**：点 **更多信息 → 仍要运行**（未签名的自编译程序都会这样，
  Release 附了 SHA256 可自行比对）
- **改密码 / 换电脑**：重新运行一次 `install.bat` 即可（密码 DPAPI 加密，绑定"本机 + 当前 Windows 用户"）
- **卸载**：双击 `uninstall.bat`

## 特性

- 零依赖：单文件 exe，不需要安装 Python
- 开机静默自动认证：计划任务触发，无窗口、一次性进程、不常驻
- 断线自动重连：每 30 分钟巡检一次（安装时可关闭）
- 自动网络修复：DHCP 续租 + 刷新 DNS（等效火绒"网络修复"的核心动作）
- 密码 DPAPI 加密存储，仅本机当前用户可解密，不落明文
- 一键卸载，不残留

## 安装到哪里了

| 内容 | 位置 |
|---|---|
| 程序与配置 | `%LOCALAPPDATA%\HZAU-AutoLogin\` |
| 运行日志 | 同目录下 `srun_login.log` |
| 计划任务 | `HZAU-AutoLogin`（登录时）、`HZAU-AutoLogin-Reconnect`（每 30 分钟） |

## 配置项（%LOCALAPPDATA%\HZAU-AutoLogin\config.json）

| 键 | 默认 | 含义 |
|---|---|---|
| `server` | `https://rz.hzau.edu.cn` | 认证服务器 |
| `ac_id` | `"5"` | 深澜 AC id |
| `username` | - | 学号（走运营商宽带则加 `@cmcc` 等后缀到 `domain`） |
| `domain` | `""` | 用户名后缀 |
| `network_wait_seconds` | `300` | 开机后最多等待网络就绪的时间 |
| `repair_interval_seconds` | `60` | 两次网络修复的最小间隔 |
| `max_attempts` / `retry_interval` | `3` / `3` | 登录请求重试次数与间隔 |

## 常见问题

- **改了校园网密码**：重新运行 `install.bat`。
- **E2620 / 在线数超限**：到 zizhu.hzau.edu.cn 自助服务下线其他设备。
- **装好/写好密码后仍无法认证**：双击解压目录或安装目录里的 **`diagnose.bat`**（用平时登录的
  账号运行，不要"以管理员身份"），它会汇总配置、密码能否解密、网络状态、服务器连通性与运行
  日志，把窗口内容或生成的报告发给作者即可定位；也可直接查看安装目录
  `%LOCALAPPDATA%\HZAU-AutoLogin\srun_login.log` 最后几行（日志会给出中文提示）。
- **在非校园网环境开机**：等待约 45 秒并尝试一次修复后继续等待，超时自动放弃，无副作用。
- **卸载**：双击 `uninstall.bat`；或管理员 PowerShell 执行
  `Unregister-ScheduledTask -TaskName 'HZAU-AutoLogin' -Confirm:$false`。

## 给开发者：发布新版本

打 tag 即可，GitHub Actions 会自动构建 exe、组装 zip、计算 SHA256 并发布 Release：

```bash
git tag v1.1.0
git push origin main --tags
```

本地构建：`powershell -ExecutionPolicy Bypass -File .\build.ps1`（需要 Python + PyInstaller）。
打包方案、方案对比与踩坑记录见 [docs/PACKAGING.md](docs/PACKAGING.md)。

## 目录结构

```
srun_login.py                 主脚本（纯标准库；含 PyInstaller frozen 环境适配）
build.ps1                     本地构建 exe 与分发 zip
installer/
  ├─ install.bat              双击安装（自动提权、绕过执行策略）
  ├─ install.ps1              安装/卸载全部逻辑
  ├─ diagnose.bat / .ps1      双击一键诊断（无法认证时运行，输出报告）
  └─ uninstall.bat            双击卸载
.github/workflows/release.yml 推送 v* tag 自动构建并发布 Release
docs/PACKAGING.md             打包与分发方案说明
```
