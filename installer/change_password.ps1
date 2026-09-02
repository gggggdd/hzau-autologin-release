#Requires -Version 5.1
<#
只重置校园网密码，不重装：把新密码 DPAPI 加密写入已安装目录的 password.bin。

用法：
  双击 change_password.bat
  或 powershell -ExecutionPolicy Bypass -File .\change_password.ps1
  可选：-InstallDir 指定安装目录（默认 %LOCALAPPDATA%\HZAU-AutoLogin）
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'HZAU-AutoLogin'),
    [switch]$Silent
)

$ErrorActionPreference = 'Stop'
function Pause-End { if (-not $Silent) { Read-Host '按回车键关闭窗口' | Out-Null } }

try {
    if (-not (Test-Path (Join-Path $InstallDir 'config.json'))) {
        throw "未找到安装目录 $InstallDir（缺 config.json），请先运行 install.bat 完成安装"
    }

    $sec = Read-Host '请输入新的校园网密码' -AsSecureString
    Add-Type -AssemblyName System.Security
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        if ([string]::IsNullOrEmpty($plain)) { throw '密码为空' }
        $enc = [System.Security.Cryptography.ProtectedData]::Protect(
            [Text.Encoding]::UTF8.GetBytes($plain), $null,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        [IO.File]::WriteAllText((Join-Path $InstallDir 'password.bin'),
            [Convert]::ToBase64String($enc), [Text.UTF8Encoding]::new($false))
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    Write-Host "新密码已加密保存: $InstallDir\password.bin" -ForegroundColor Green
    Write-Host '下次开机认证或周期巡检即会使用新密码。'

    if (-not $Silent) {
        $exe = Join-Path $InstallDir 'hzau-autologin.exe'
        $go = (Read-Host '是否立即用新密码认证一次？[Y/N]').Trim().ToUpper()
        if ($go -eq 'Y' -and (Test-Path $exe)) {
            # 注意：不能用 -NoNewWindow（会因 http_proxy/HTTP_PROXY 大小写冲突崩溃），
            # 也不能用 & $exe（对 GUI 子系统程序不等待）。
            Start-Process -FilePath $exe -WorkingDirectory $InstallDir -Wait
            $log = Join-Path $InstallDir 'srun_login.log'
            if (Test-Path $log) {
                Write-Host '--- 最近日志 ---' -ForegroundColor DarkGray
                Get-Content $log -Tail 8 -Encoding UTF8
            }
        }
    }
    Pause-End
    exit 0
} catch {
    Write-Host "失败: $($_.Exception.Message)" -ForegroundColor Red
    Pause-End
    exit 1
}
