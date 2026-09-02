#Requires -Version 5.1
<#
HZAU-AutoLogin 一键诊断工具

用途：收集"无法自动认证"时排障所需的全部信息，供开发者远程定位。
重要：请用【自己平时登录 Windows 的账号】直接双击 diagnose.bat 运行，
      不要右键"以管理员身份运行"——普通身份才能检测出配置是否装错了用户。
用法：powershell -NoProfile -ExecutionPolicy Bypass -File .\diagnose.ps1
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'HZAU-AutoLogin')
)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$script:lines = New-Object System.Collections.Generic.List[string]

function Say([string]$msg, [string]$color = 'Gray') {
    Write-Host $msg -ForegroundColor $color
    $script:lines.Add($msg)
}
function SayOk($msg)   { Say $msg 'Green' }
function SayWarn($msg) { Say $msg 'Yellow' }
function SayBad($msg)  { Say $msg 'Red' }
function SayStep($msg) { Say ("`n=== " + $msg + " ===") 'Cyan' }

function Test-TcpPort {
    param([string]$HostName, [int]$Port, [int]$TimeoutMs = 8000)
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect($HostName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return '连接超时' }
        $c.EndConnect($iar)
        return 'OK'
    } catch {
        $m = $_.Exception.Message
        if ($_.Exception.InnerException) { $m = $_.Exception.InnerException.Message }
        return '失败: ' + $m
    } finally { $c.Close() }
}

# ================================================================
Say '================================================'
Say '   HZAU-AutoLogin 一键诊断'
Say '================================================'
Say ('  时间    : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Say ('  计算机  : ' + $env:COMPUTERNAME)
Say ('  当前用户: ' + $env:USERDOMAIN + '\' + $env:USERNAME)
$isAdmin = $false
try {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }
Say ('  管理员  : ' + $(if ($isAdmin) {'是'} else {'否'}) + $(if ($isAdmin) {'  （普通用户登录时这里应显示"否"）'} else {'  （正常，普通身份）'}))
Say ('  目标目录: ' + $InstallDir)

# ---------- 1. 安装目录 ----------
SayStep '1) 检查安装目录与文件'
if (-not (Test-Path $InstallDir)) {
    SayBad '未找到安装目录（说明安装可能没成功，或装到了别的 Windows 用户下）。'
    SayWarn '常见原因：安装时 UAC 窗口里登录的是【管理员账号】，配置被写进了那个账号的目录；'
    SayWarn '         你平时登录的却是普通账号，于是找不到、也不会自动运行。'
    SayWarn '解决办法：用平时登录 Windows 的账号重新双击 install.bat 完整安装一次。'
    Say '请把本窗口内容发给开发者。'
    $reportFile = Join-Path $env:TEMP ('hzau-diagnose-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
    try { [IO.File]::WriteAllLines($reportFile, $script:lines, (New-Object System.Text.UTF8Encoding($false))) } catch { }
    Say ('诊断报告已保存: ' + $reportFile)
    exit 1
}
Say ('目录存在: ' + $InstallDir)
foreach ($f in @('hzau-autologin.exe', 'config.json', 'password.bin', 'srun_login.log')) {
    $p = Join-Path $InstallDir $f
    if (Test-Path $p) {
        $sz = (Get-Item $p).Length
        $note = ''
        if ($f -eq 'hzau-autologin.exe' -and $sz -lt 100000) { $note = '  <-- exe 异常偏小，可能复制不完整' }
        Say ('  [存在] ' + $f + '  (' + $sz + ' B)' + $note)
    } else {
        SayWarn ('  [缺失] ' + $f)
    }
}
$exe = Join-Path $InstallDir 'hzau-autologin.exe'
if (-not (Test-Path $exe)) {
    SayBad '缺少主程序 hzau-autologin.exe，请重跑 install.bat 安装。'
    exit 1
}

# ---------- 2. 配置 ----------
SayStep '2) 配置内容 config.json'
try {
    $raw = Get-Content (Join-Path $InstallDir 'config.json') -Raw -Encoding UTF8
    $cfg = $raw | ConvertFrom-Json
    Say ('  server   = ' + $cfg.server)
    Say ('  ac_id    = ' + $cfg.ac_id)
    Say ('  username = ' + $cfg.username)
    $dom = $cfg.domain
    Say ('  domain   = ' + $(if ([string]::IsNullOrEmpty($dom)) {'(空)'} else {$dom}))
    if ([string]::IsNullOrEmpty($cfg.username)) { SayWarn '  username 为空 —— 安装时学号没填上，请重跑 install.bat' }
    if ($cfg.username -match '@') { SayWarn '  username 里带了 @xxx —— 应把 @后缀放到 domain 字段，否则认证会失败' }
    if (-not [string]::IsNullOrEmpty($dom)) {
        SayWarn ('  填了运营商后缀 ' + $dom + ' —— 请确认账号确实是运营商宽带账号；普通校园网账号这里应留空。')
    }
} catch {
    SayBad ('  config.json 读取或解析失败: ' + $_.Exception.Message)
}

# ---------- 3. DPAPI ----------
SayStep '3) 密码 password.bin 能否用当前用户解密'
$pwPath = Join-Path $InstallDir 'password.bin'
if (Test-Path $pwPath) {
    Add-Type -AssemblyName System.Security
    try {
        $bytes = [Convert]::FromBase64String((Get-Content $pwPath -Raw).Trim())
        $plain = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        $pwLen = [System.Text.Encoding]::UTF8.GetString($plain).Length
        SayOk ('  解密成功，密码长度 ' + $pwLen + ' 位（不会显示密码本身）')
        if ($pwLen -eq 0) { SayWarn '  密码为空 —— 请运行安装目录里的 change_password.bat 重新填写' }
    } catch {
        SayBad ('  解密失败: ' + $_.Exception.Message)
        SayWarn '  原因：password.bin 是用【另一个 Windows 用户】保存的（常见于安装时 UAC 登录了管理员账号），或换过用户。'
        SayWarn '  解决：用平时登录的账号重跑 install.bat（会覆盖安装并重新保存密码）。'
    }
} else {
    SayWarn '  password.bin 不存在 —— 尚未保存过密码，请运行 install.bat 或 change_password.bat'
}

# ---------- 4. 本机网络 ----------
SayStep '4) 本机网络状态'
$gotNet = $false
try {
    $nets = Get-NetIPConfiguration -ErrorAction Stop | Where-Object { $_.IPv4DefaultGateway }
    foreach ($n in $nets) {
        $gotNet = $true
        $ips  = ($n.IPv4Address | ForEach-Object { $_.IPAddress }) -join ', '
        $gw   = $n.IPv4DefaultGateway.NextHop
        $dns  = ($n.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses }) -join ', '
        Say ('  网卡: ' + $n.InterfaceAlias + '  状态: ' + $n.NetAdapter.Status)
        Say ('    IPv4: ' + $ips + '   网关: ' + $gw)
        Say ('    DNS : ' + $dns)
        foreach ($a in $n.IPv4Address) {
            if ($a.IPAddress -like '169.254.*') {
                SayWarn '    警告：IP 为 169.254.x.x（DHCP 失败的自配地址），等于没真正连上网，脚本会一直等待/修复直到超时。'
            }
        }
    }
    if (-not $gotNet) { SayWarn '  未找到带默认网关的 IPv4 网络 —— 可能没连网，或连的是纯 APIPA。' }
} catch {
    SayWarn '  读取网络配置失败（老系统可能没有 Get-NetIPConfiguration），改用 ipconfig 输出：'
    ipconfig | Out-String -Width 200 | ForEach-Object { Say $_ }
}

# ---------- 5. 服务器连通性 ----------
SayStep '5) 认证服务器连通性 rz.hzau.edu.cn'
$dnsOk = $null
try {
    $dnsOk = ([Net.Dns]::GetHostAddresses('rz.hzau.edu.cn') | ForEach-Object { $_.IPAddressToString }) -join ', '
} catch { }
if ($dnsOk) {
    Say ('  DNS 解析: ' + $dnsOk)
} else {
    SayWarn '  DNS 解析失败 —— 未连校园网？或 DNS 被劫持/拦截（未认证状态下部分网络环境只放行认证域名）。'
}
$t443 = Test-TcpPort 'rz.hzau.edu.cn' 443
if ($t443 -eq 'OK') { SayOk '  TCP 443(https): 可达' } else { SayWarn ('  TCP 443(https): ' + $t443) }

# ---------- 6. 实际运行 ----------
SayStep '6) 实际运行一次自动认证'
$run = $true
if ($t443 -ne 'OK') {
    $ans = Read-Host '  服务器 443 不可达，直接运行会等待网络最长约 5 分钟。仍要运行？[Y/N]'
    if ($ans.Trim().ToUpper() -ne 'Y') { $run = $false }
}
if ($run) {
    Say '  正在运行 hzau-autologin.exe（无窗口；网络不通时最长约 5 分钟，可关闭本窗口中止）...'
    try {
        $p = Start-Process -FilePath $exe -WorkingDirectory $InstallDir -Wait -PassThru
        $code = $p.ExitCode
        switch ($code) {
            0 { SayOk  '  退出码: 0 —— 认证成功，或本来就已经在线' }
            1 { SayWarn '  退出码: 1 —— 环境/配置类问题（结合下方日志判断）' }
            2 { SayBad  '  退出码: 2 —— 认证失败（结合下方日志与"=》"提示判断）' }
            default { Say ('  退出码: ' + $code + '（未知）') }
        }
    } catch {
        SayBad ('  启动失败: ' + $_.Exception.Message)
    }
}

# ---------- 7. 日志 ----------
SayStep '7) 运行日志尾部 srun_login.log'
$log = Join-Path $InstallDir 'srun_login.log'
if (Test-Path $log) {
    Get-Content $log -Tail 35 -Encoding UTF8 | ForEach-Object { Say $_ }
} else {
    SayWarn '  尚无日志文件 —— 程序可能从未成功启动过（或被安全软件拦截）。'
}

# ---------- 汇总 ----------
$reportFile = Join-Path $InstallDir ('diagnose-' + $env:COMPUTERNAME + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
try {
    [IO.File]::WriteAllLines($reportFile, $script:lines, (New-Object System.Text.UTF8Encoding($false)))
    SayOk ('诊断报告已保存: ' + $reportFile)
} catch {
    SayWarn ('报告写入失败: ' + $_.Exception.Message + ' —— 请直接截图本窗口')
}
Say ''
Say '请把【本窗口完整内容】或【上面的诊断报告文件】发给开发者，即可定位原因。'
