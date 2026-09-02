# 打包与分发方案

> 本仓库是 [hzau-autologin](https://github.com/gggggdd/hzau-autologin) 的打包分发版，
> 本文档记录把源码形态改造成"同学双击即用"的完整思路。第一节描述的痛点指原仓库的源码形态。

目标：让同学**不需要装 Python、不需要懂 PowerShell**，下载后双击就能用。

## 一、当前形态的痛点

| 痛点 | 影响面 | 说明 |
|---|---|---|
| 必须自备 Python 3.8+ | **最大** | 非计算机专业同学基本没有 Python，装 Python 比装这个工具还难 |
| 三步手动操作 | 大 | 复制 config → 右键运行加密脚本 → 管理员运行注册脚本，每步都可能做错 |
| PowerShell 执行策略 | 中 | 很多机器默认是 `Restricted`，右键"使用 PowerShell 运行"会闪退或一闪而过 |
| `install_scheduled_task.ps1` 里硬编码 `C:\miniconda3\pythonw.exe` | 中 | 是你自己机器的路径，别人机器上会走 fallback，但读起来像 bug |
| 只在"登录时"触发 | 中 | WiFi 断线重连、睡眠唤醒后不会重新认证 |
| 无卸载入口 | 小 | 同学想删掉时不知道要清计划任务 |

结论：**核心矛盾不是代码，是分发形态**。Python 脚本这个形态决定了它只能给会配环境的人用。

## 二、方案对比

| 方案 | 同学要做的事 | 体积 | 优点 | 缺点 |
|---|---|---|---|---|
| **A. PyInstaller 单文件 exe + 一键安装器（推荐）** | 解压 → 双击 install.bat → 输学号密码 | ~10 MB | 零依赖、真正的双击即用、可自动化发布 | 未签名 exe 会触发 SmartScreen / 杀软误报 |
| B. embeddable Python 便携包 | 同上 | ~15 MB | 没有 exe，杀软友好 | 目录里一堆 dll，不像成品；启动器仍需写 |
| C. 纯脚本 + 一行命令安装 | 需先装 Python | 几 KB | 维护成本 0 | 门槛没降，等于没解决 |
| D. Scoop / winget 包 | `scoop install` 两条命令 | 小 | 极客友好、易升级 | 同学还得先装 Scoop，本末倒置 |

**选 A**：门槛最低，且能用 GitHub Actions 全自动出包，你打一个 tag 就发布。

## 三、已落地的东西

```
build.ps1                        本地一键构建 exe + 可直接分发的 zip
.github/workflows/release.yml    推送 v* tag 自动构建并发布 Release
installer/install.bat            双击入口，自动申请管理员权限、绕过执行策略
installer/install.ps1            安装/卸载全部逻辑（也支持 irm 一行命令远程装）
installer/uninstall.bat          双击卸载
```

上述流程已在本机完整实测：构建 exe（8.7 MB）→ 安装（注册 2 个任务、试跑一次认证成功）
→ 卸载（任务与目录清除干净），全程退出码 0、无残留。打包坑位见文末「实测踩到的三个坑」。

### 一键安装命令（连仓库都不用下）

```powershell
irm https://raw.githubusercontent.com/gggggdd/hzau-autologin-release/main/installer/install.ps1 | iex
```

### 安装器做了什么

1. 自行申请管理员权限（UAC 一次），拿不到就降级为普通权限继续装并明确告知
2. 把 exe 安装到 `%LOCALAPPDATA%\HZAU-AutoLogin\`（固定位置，同学删了解压目录也不失效）
3. 交互式问学号 / 密码 / 运营商后缀，生成 `config.json` + DPAPI 加密的 `password.bin`
4. 注册两个计划任务：
   - `HZAU-AutoLogin` —— 登录时触发，最高权限
   - `HZAU-AutoLogin-Reconnect` —— 每 30 分钟巡检一次，断线自动重连（`-NoHeartbeat` 可关）
5. 清理旧的启动文件夹方式，避免重复运行
6. 立即试跑一次并打印日志，装好就知道成没成

### 发布流程

```bash
git add -A && git commit -m "release: v1.1.0"
git tag v1.1.0
git push origin main --tags
```

Actions 会构建 exe、打包 `hzau-autologin-v1.1.0-win64.zip`（exe + 安装器 + README + 配置模板）、算 SHA256 并建 Release。

## 四、几个必须知道的坑

**SmartScreen / 杀软误报**
未签名的 PyInstaller 程序几乎必然被拦。缓解：
- `--noupx` 已加上（UPX 压缩是误报重灾区）
- Release 里附 SHA256，README 里写清"点更多信息 → 仍要运行"
- 想要彻底解决只能买代码签名证书（个人 OV 证书一年约几百元，学生项目一般没必要）

**为什么装到 `%LOCALAPPDATA%` 而不是 `Program Files`**
`Program Files` 不可写，脚本要写 `srun_login.log`；用户目录可写且不需要管理员权限就能写，卸载干净。

**DPAPI 的边界**
`password.bin` 绑"本机 + 当前 Windows 用户"。换电脑、重装系统、换 Windows 账号都要重跑安装器，**这点要在给同学的使用说明里写死**，否则最常见的问题是"换了电脑就一直认证失败"。

**周期巡检任务**
`config.json` 里 `network_wait_seconds` 默认 300 秒，巡检间隔 30 分钟，不会重叠（任务已设 `MultipleInstances IgnoreNew`）。如果同学主要是笔记本带出校园网，可以把间隔调大或加 `-NoHeartbeat`。

## 五、实测踩到的三个坑（都已修，别再踩回去）

打包流程在本机完整跑通（构建 → 安装 → 认证 → 卸载），过程中发现三个只在运行时才暴露的问题：

**1. 单文件 exe 的 `__file__` 指向临时目录**
`os.path.dirname(os.path.abspath(__file__))` 在 `--onefile` 模式下拿到的是
`C:\Users\...\Temp\_MEIxxxxxx`，config / password / log 全都找错地方，表现为「明明配好了却读不到 config」。
修法：用 `getattr(sys, 'frozen', False)` 判断，打包时用 `sys.executable` 取真实目录。

**2. `Start-Process -NoNewWindow` 在部分机器上必崩**
会抛 `已添加项。字典中的关键字:"http_proxy"所添加的关键字:"HTTP_PROXY"`。
原因是它走 `UseShellExecute=false` 分支并重建环境变量字典，而装了 Clash 一类代理工具的机器上
`http_proxy` / `HTTP_PROXY` 会同时存在（大小写不同）。本机实测三种调用方式：

| 调用方式 | 结果 |
|---|---|
| `& $exe`（调用运算符） | 能启动，但**不等待** GUI 程序 |
| `Start-Process -NoNewWindow` | 崩溃 |
| `Start-Process -Wait`（不带 `-NoNewWindow`） | 正常且会等待 |

所以试跑那一步用 `Start-Process -Wait`；提权用的 `-Verb RunAs` 走 `UseShellExecute=true`，不受影响。

**3. 中文编码的两个坑**
- PowerShell 5.1 默认按 ANSI 读 `.ps1`，UTF-8 **无 BOM** 的中文会乱码，严重时 GBK 误解码会吞掉引号导致语法直接崩。两个 ps1 都必须存成 **UTF-8 with BOM**。
- Python 写的日志是 UTF-8，安装器读取时必须 `Get-Content -Encoding UTF8`，否则控制台一片乱码。

## 六、可以再做的（按性价比排序）

1. **给安装器加个 tkinter GUI**（托盘小工具）：学号/密码框 + "立即认证"按钮 + "查看日志" + "卸载"。纯标准库，加几十行，对同学的友好度提升最大。
2. **改密码入口**：现在改密码要重跑整个安装器，做个 `改密码.bat` 只重跑加密步骤更自然。
3. **README 顶部放"一键安装"大按钮**：把 Releases 最新版的 zip 链接放最显眼位置，源码安装章节折叠到下面。
4. **原仓库的旧脚本归档**：`encrypt_password.ps1` / `install_scheduled_task.ps1` / `install_autostart.ps1`
   仍留在原仓库 `hzau-autologin`，建议在原仓库 README 顶部加一行指向本仓库，避免同学走老路。
