#Requires -Version 5.1
<#
HZAU 校园网自动认证 - 一键安装 / 卸载

用法（三选一）：
  1) 双击 install.bat（推荐，会自动申请管理员权限）
  2) PowerShell： powershell -ExecutionPolicy Bypass -File .\install.ps1
  3) 一行命令装（无需先下载仓库）：
     irm https://raw.githubusercontent.com/gggggdd/hzau-autologin-release/main/installer/install.ps1 | iex

卸载：
  双击 uninstall.bat，或 powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$Username,                 # 学号（不给则交互式询问）
    [SecureString]$Password,           # 校园网密码（建议留空，交互输入）
    [string]$Domain = '',              # 用户名后缀，如 @cmcc / @unicom
    [string]$SourceExe,                # 本地 exe 路径（不给则自动找，找不到从 Release 下载）
    [int]$HeartbeatMinutes = 30,       # 断线重连检查间隔（分钟）
    [switch]$NoHeartbeat,              # 只保留"登录时"触发，不装周期任务
    [switch]$Uninstall,
    [switch]$Silent                    # 非交互：结尾不暂停、不询问
)

$ErrorActionPreference = 'Stop'

$TaskLogon  = 'HZAU-AutoLogin'
$TaskBeat   = 'HZAU-AutoLogin-Reconnect'
$InstallDir = Join-Path $env:LOCALAPPDATA 'HZAU-AutoLogin'
$ExeName    = 'hzau-autologin.exe'
$ExeUrl     = 'https://github.com/gggggdd/hzau-autologin-release/releases/latest/download/hzau-autologin.exe'
$StageDir   = if ($PSScriptRoot) { $PSScriptRoot } else { Join-Path $env:TEMP 'HZAU-AutoLogin-Setup' }

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Test-Admin {
    try { return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { return $false }
}
function Pause-End { if (-not $Silent) { Read-Host '按回车键关闭窗口' | Out-Null } }

# ---------------------------------------------------------------- 卸载
function Invoke-Uninstall {
    Write-Step '卸载 HZAU-AutoLogin'
    foreach ($t in @($TaskLogon, $TaskBeat)) {
        $existing = Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
        if ($existing) {
            Unregister-ScheduledTask -TaskName $t -Confirm:$false
            Write-Host "  已移除计划任务: $t"
        }
    }
    $startupCmd = Join-Path ([Environment]::GetFolderPath('Startup')) 'HZAU-AutoLogin.cmd'
    if (Test-Path $startupCmd) { Remove-Item $startupCmd -Force; Write-Host "  已移除旧启动项: $startupCmd" }

    if (Test-Path $InstallDir) {
        $ans = if ($Silent) { 'Y' } else { (Read-Host "  删除安装目录（含配置与加密密码）$InstallDir ? [Y/N]").Trim().ToUpper() }
        if ($ans -eq 'Y') { Remove-Item $InstallDir -Recurse -Force; Write-Host '  已删除安装目录' }
        else { Write-Host '  保留安装目录（可手动删除）' }
    }
    Write-Host "`n卸载完成。" -ForegroundColor Green
}

# ---------------------------------------------------------------- 定位 exe
function Resolve-SourceExe {
    param([string]$Hint)
    $candidates = @()
    if ($Hint) { $candidates += $Hint }
    if ($PSScriptRoot) {
        $candidates += (Join-Path $PSScriptRoot $ExeName)
        $candidates += (Join-Path (Split-Path $PSScriptRoot -Parent) "dist/$ExeName")
    }
    $candidates += (Join-Path $InstallDir $ExeName)
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return (Resolve-Path $c).Path }
    }
    return $null
}

function Get-ReleaseExe {
    Write-Host "  本地未找到 $ExeName，尝试从 GitHub Release 下载..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Force -Path $StageDir | Out-Null
    $dest = Join-Path $StageDir $ExeName
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $ExeUrl -OutFile $dest -UseBasicParsing
    } catch {
        throw "下载失败：$($_.Exception.Message)`n请手动从 Releases 页面下载 $ExeName 放到本脚本同目录后重试。"
    }
    if ((Get-Item $dest).Length -lt 100KB) { throw '下载到的文件异常（过小），请检查 Release 资产。' }
    return $dest
}

# ---------------------------------------------------------------- 保存凭证
function Save-PasswordBin {
    param([SecureString]$SecurePassword, [string]$Path)
    Add-Type -AssemblyName System.Security
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        if ([string]::IsNullOrEmpty($plain)) { throw '密码为空' }
        $enc = [System.Security.Cryptography.ProtectedData]::Protect(
            [Text.Encoding]::UTF8.GetBytes($plain), $null,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        [IO.File]::WriteAllText($Path, [Convert]::ToBase64String($enc), [Text.UTF8Encoding]::new($false))
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Save-Config {
    param([string]$User, [string]$Dom, [string]$Path)
    $cfg = [ordered]@{
        server                  = 'https://rz.hzau.edu.cn'
        ac_id                   = '5'
        username                = $User
        domain                  = $Dom
        max_attempts            = 3
        retry_interval          = 3
        network_wait_seconds    = 300
        repair_interval_seconds = 60
    }
    $json = $cfg | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

# ================================================================ 主流程
try {
    if ($Uninstall) { Invoke-Uninstall; Pause-End; exit 0 }

    # 1. 提权（计划任务要以最高权限运行，才能做 DHCP 续租）
    if (-not (Test-Admin)) {
        Write-Host '正在申请管理员权限（请在 UAC 窗口点"是"）...' -ForegroundColor Yellow
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
        if ($Username)     { $argList += @('-Username', "`"$Username`"") }
        if ($Domain)       { $argList += @('-Domain', "`"$Domain`"") }
        if ($SourceExe)    { $argList += @('-SourceExe', "`"$SourceExe`"") }
        if ($NoHeartbeat)  { $argList += '-NoHeartbeat' }
        $elevatedOk = $false
        try {
            Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -Wait
            $elevatedOk = $true
        } catch {
            # 极少数机器上 Start-Process 会因环境变量大小写冲突（http_proxy / HTTP_PROXY）失败，
            # 改用 ShellExecute 兜底再试一次。
            try {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = 'powershell.exe'
                $psi.Arguments = $argList -join ' '
                $psi.Verb = 'runas'
                $psi.UseShellExecute = $true
                ([System.Diagnostics.Process]::Start($psi)).WaitForExit()
                $elevatedOk = $true
            } catch { }
        }
        if ($elevatedOk) { exit 0 }

        Write-Host '未获得管理员权限。将以"普通权限"安装：开机可自动认证，但拿不到 IP 时无法自动执行 DHCP 续租。' -ForegroundColor Yellow
        if (-not $Silent) {
            $go = (Read-Host '继续安装？[Y/N]').Trim().ToUpper()
            if ($go -ne 'Y') { Write-Host '已取消。'; exit 1 }
        }
    }
    $elevated = Test-Admin

    # 2. 准备安装目录与 exe
    Write-Step '准备安装目录'
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $src = Resolve-SourceExe -Hint $SourceExe
    if (-not $src) { $src = Get-ReleaseExe }
    $dest = Join-Path $InstallDir $ExeName
    Copy-Item $src $dest -Force
    Write-Host "  安装目录: $InstallDir"
    Write-Host "  程序: $dest"

    # 附带改密码小工具：以后改密码直接双击安装目录里的 change_password.bat，无需重装
    if ($PSScriptRoot) {
        foreach ($f in @('change_password.ps1', 'change_password.bat')) {
            $p = Join-Path $PSScriptRoot $f
            if (Test-Path $p) { Copy-Item $p $InstallDir -Force }
        }
    }

    # 3. 收集账号信息
    Write-Step '配置账号'
    if (-not $Username) {
        $Username = (Read-Host '请输入学号').Trim()
        if (-not $Username) { throw '学号不能为空' }
    }
    $Username = $Username -replace '@.*$', ''      # 后缀统一走 domain 字段
    if (-not $PSBoundParameters.ContainsKey('Domain') -and -not $Silent) {
        $d = (Read-Host '运营商宽带后缀（校园网账号直接回车，如移动填 @cmcc）').Trim()
        if ($d) { $Domain = $d }
    }
    if (-not $Password) {
        $Password = Read-Host '请输入校园网密码' -AsSecureString
    }
    if ($Silent -and -not $Password) { throw '静默模式必须通过 -Password 传入密码' }

    Save-Config -User $Username -Dom $Domain -Path (Join-Path $InstallDir 'config.json')
    Save-PasswordBin -SecurePassword $Password -Path (Join-Path $InstallDir 'password.bin')
    Write-Host "  已保存 config.json 与 DPAPI 加密的 password.bin" -ForegroundColor Green

    # 4. 注册计划任务
    Write-Step '注册计划任务'
    $action   = New-ScheduledTaskAction -Execute $dest -WorkingDirectory $InstallDir
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -Hidden -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 20)
    $principal = if ($elevated) {
        New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
    } else {
        New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
    }
    Register-ScheduledTask -TaskName $TaskLogon -Action $action -Principal $principal `
        -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME) `
        -Settings $settings -Force | Out-Null
    Write-Host "  已注册: $TaskLogon（登录时触发，权限: $(if ($elevated) {'最高'} else {'普通'})）"

    if (-not $NoHeartbeat) {
        $beatTrigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(2)) `
            -RepetitionInterval (New-TimeSpan -Minutes $HeartbeatMinutes) `
            -RepetitionDuration (New-TimeSpan -Days 3650)
        Register-ScheduledTask -TaskName $TaskBeat -Action $action -Principal $principal `
            -Trigger $beatTrigger -Settings $settings -Force | Out-Null
        Write-Host "  已注册: $TaskBeat（每 $HeartbeatMinutes 分钟检查一次，断线自动重连）"
    }

    # 5. 清理旧的安装方式
    $startupCmd = Join-Path ([Environment]::GetFolderPath('Startup')) 'HZAU-AutoLogin.cmd'
    if (Test-Path $startupCmd) { Remove-Item $startupCmd -Force; Write-Host "  已移除旧启动项: $startupCmd" }

    # 6. 立即试跑一次（这一步失败不算安装失败）
    $doTest = 'Y'
    if (-not $Silent) { $doTest = (Read-Host "`n是否现在立即认证一次以验证配置？[Y/N]").Trim().ToUpper() }
    if ($doTest -eq 'Y') {
        Write-Step '正在认证...'
        try {
        # 两个坑：
        # 1) 不能加 -NoNewWindow —— 它走 UseShellExecute=false 分支并重建环境变量字典，
        #    若机器上同时存在 http_proxy 与 HTTP_PROXY（装了 Clash 一类代理工具很常见），
        #    会直接抛"已添加项。字典中的关键字..."。
        # 2) 不能用调用运算符 & $dest —— 对 GUI 子系统程序它不等待，进程还没写出日志就往下走了。
        #    另外日志由 Python 以 UTF-8 写入，读取时必须指定 -Encoding UTF8。
            Start-Process -FilePath $dest -WorkingDirectory $InstallDir -Wait
        } catch {
            Write-Host "  试运行未能启动：$($_.Exception.Message)" -ForegroundColor Yellow
        }
        $log = Join-Path $InstallDir 'srun_login.log'
        if (Test-Path $log) {
            Write-Host "`n--- 最近日志 ---" -ForegroundColor DarkGray
            Get-Content $log -Tail 12 -Encoding UTF8
            Write-Host "完整日志: $log" -ForegroundColor DarkGray
        }
    }

    Write-Host @"

安装完成。以后开机联网后会自动认证，无需任何操作。
  安装目录: $InstallDir
  卸载: 运行 uninstall.bat
"@ -ForegroundColor Green
    Pause-End
    exit 0
} catch {
    Write-Host "`n安装失败: $($_.Exception.Message)" -ForegroundColor Red
    Pause-End
    exit 1
}
