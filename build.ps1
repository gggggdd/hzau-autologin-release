# HZAU-AutoLogin 本地打包脚本
# 产物：dist\hzau-autologin.exe 与 dist\hzau-autologin-<日期>-win64.zip（可直接发给同学的压缩包）
#
# 用法： powershell -ExecutionPolicy Bypass -File .\build.ps1
#       （可选）.\build.ps1 -Python 'C:\Python312\python.exe'

[CmdletBinding()]
param(
    [string]$Python = 'python'
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$dist = Join-Path $root 'dist'
$stamp = Get-Date -Format 'yyyyMMdd'
$zipName = "hzau-autologin-$stamp-win64.zip"

Write-Host "==> 安装 PyInstaller" -ForegroundColor Cyan
& $Python -m pip install --upgrade pyinstaller

Write-Host "==> 打包 srun_login.py" -ForegroundColor Cyan
Push-Location $root
try {
    & $Python -m PyInstaller `
        --noconsole --onefile --noupx --clean `
        --name hzau-autologin `
        --exclude-module tkinter `
        srun_login.py
} finally {
    Pop-Location
}

$exe = Join-Path $dist 'hzau-autologin.exe'
if (-not (Test-Path $exe)) { throw "打包失败：未找到 $exe" }

Write-Host "==> 组装发布包 $zipName" -ForegroundColor Cyan
$staging = Join-Path $dist 'staging'
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
New-Item -ItemType Directory -Path $staging | Out-Null
Copy-Item $exe $staging
Copy-Item (Join-Path $root 'installer\*') $staging
Copy-Item (Join-Path $root 'README.md') $staging
Copy-Item (Join-Path $root 'config.example.json') $staging

$zip = Join-Path $dist $zipName
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zip
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash
[IO.File]::WriteAllText("$zip.sha256", "$hash  $zipName`r`n")

Write-Host @"

打包完成：
  $exe
  $zip
  SHA256: $hash

把 zip 发给同学即可：解压 -> 双击 install.bat -> 输入学号和密码。
"@ -ForegroundColor Green
