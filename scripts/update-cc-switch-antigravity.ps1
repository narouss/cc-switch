<#
.SYNOPSIS
    CC Switch Antigravity 版本一键升级维护脚本
.DESCRIPTION
    本脚本专用于保持 Antigravity 定制分支与官方 upstream/main 同步：
    1. 严格检查本地 Git 状态，防止丢失未提交内容
    2. 拉取官方 upstream 最新提交，判断是否已原生支持 Antigravity
    3. 将 main 分支对齐 upstream/main 并推送到个人 origin/main
    4. 将 antigravity 分支 rebase 到最新 main
    5. 智能拦截与报告代码冲突
    6. 执行前端类型检查与构建验证
    7. 输出最终产物路径或触发 GitHub Actions 云端构建
.NOTES
    要求环境：PowerShell 7+ (pwsh)
#>

[CmdletBinding()]
param (
    [switch]$SkipBuild,
    [switch]$ForceRebase
)

# 强制要求 PowerShell 7
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Error "【错误】本脚本必须使用 PowerShell 7+ (pwsh) 运行。当前版本为 $($PSVersionTable.PSVersion)。"
    exit 1
}

$ErrorActionPreference = 'Stop'

# 设置 UTF-8 编码以防中文路径或 Git 输出乱码
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# 切换到 Git 仓库根目录
if ($PSScriptRoot) {
    $repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
} else {
    $repoRoot = (Resolve-Path ".").Path
}
Set-Location $repoRoot

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "         CC Switch Antigravity 一键升级维护工具                 " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "仓库目录: $repoRoot" -ForegroundColor Gray

# -------------------------------------------------------------
# 步骤 1：工作区安全检查
# -------------------------------------------------------------
Write-Host "`n>>> [步骤 1/6] 检查 Git 工作区状态..." -ForegroundColor Cyan
$dirty = git status --porcelain
if ($dirty) {
    Write-Error "【终止】工作区存在未提交的改动或新增未跟踪文件：`n$dirty`n为防止意外覆盖，升级已终止。请先提交或暂存 (git stash) 改动后重试。"
    exit 1
}
Write-Host "√ 工作区状态干净，安全检查通过。" -ForegroundColor Green

# -------------------------------------------------------------
# 步骤 2：检查并配置远程仓库 (upstream & origin)
# -------------------------------------------------------------
Write-Host "`n>>> [步骤 2/6] 校验远程仓库配置..." -ForegroundColor Cyan
$remotes = git remote
if ($remotes -notcontains "upstream") {
    Write-Host "未找到 upstream 远程，自动添加: https://github.com/farion1231/cc-switch.git" -ForegroundColor Yellow
    git remote add upstream https://github.com/farion1231/cc-switch.git
}
if ($remotes -notcontains "origin") {
    Write-Error "【终止】未检测到 origin 远程配置，请先关联个人 Fork 仓库。"
    exit 1
}
$originUrl = git remote get-url origin
$upstreamUrl = git remote get-url upstream
Write-Host "  - origin   : $originUrl" -ForegroundColor Gray
Write-Host "  - upstream : $upstreamUrl" -ForegroundColor Gray
Write-Host "√ 远程仓库配置正确。" -ForegroundColor Green

# -------------------------------------------------------------
# 步骤 3：拉取 upstream 并检测官方原生支持状态
# -------------------------------------------------------------
Write-Host "`n>>> [步骤 3/6] 获取 upstream/main 最新代码与提交..." -ForegroundColor Cyan
git fetch upstream --quiet
$upstreamHead = git rev-parse --short upstream/main
Write-Host "√ 官方最新提交: $upstreamHead" -ForegroundColor Green

# 检查官方是否已原生合并 Antigravity 统计
$hasNativeAntigravity = git grep -q "antigravity_session" upstream/main:src-tauri/src/services/ 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "----------------------------------------------------------------" -ForegroundColor Magenta
    Write-Host "【重要通知】官方 CC Switch (upstream/main) 已经原生支持 Antigravity 使用量统计！" -ForegroundColor Magenta
    Write-Host "您可以直接切换回官方版本，无需继续维护此自定义补丁分支。" -ForegroundColor Magenta
    Write-Host "切回官方命令: git checkout main" -ForegroundColor Magenta
    Write-Host "----------------------------------------------------------------" -ForegroundColor Magenta
}

# -------------------------------------------------------------
# 步骤 4：同步本地 main 并推送到 origin/main
# -------------------------------------------------------------
Write-Host "`n>>> [步骤 4/6] 同步本地 main 分支至 upstream/main..." -ForegroundColor Cyan
git checkout main --quiet
git reset --hard upstream/main --quiet
Write-Host "√ 本地 main 已对齐 upstream/main ($upstreamHead)。" -ForegroundColor Green

try {
    Write-Host "正在推送更新至 origin/main..." -ForegroundColor Gray
    git push origin main --quiet
    Write-Host "√ origin/main 已完成同步。" -ForegroundColor Green
} catch {
    Write-Warning "推送到 origin/main 失败（可能缺少推送权限或网络抖动），但不影响本地升级流程。"
}

# -------------------------------------------------------------
# 步骤 5：变基 antigravity 分支
# -------------------------------------------------------------
Write-Host "`n>>> [步骤 5/6] 将 antigravity 分支变基 (rebase) 到最新 main..." -ForegroundColor Cyan
git checkout antigravity --quiet

$rebaseSuccess = $true
try {
    git rebase main
} catch {
    $rebaseSuccess = $false
}

if (-not $rebaseSuccess -or $LASTEXITCODE -ne 0) {
    Write-Host "`n================================================================" -ForegroundColor Red
    Write-Host "【冲突警告】git rebase 过程中检测到代码冲突！" -ForegroundColor Red
    Write-Host "冲突文件列表：" -ForegroundColor Yellow
    $conflicts = git diff --name-only --diff-filter=U
    $conflicts | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }
    Write-Host "`n【推荐处置方案】" -ForegroundColor Yellow
    Write-Host "1. 打开上述冲突文件，保留 Antigravity 核心解析与用量统计逻辑，融合官方新代码；"
    Write-Host "2. 标记冲突解决: git add <文件路径>"
    Write-Host "3. 继续变基流程: git rebase --continue"
    Write-Host "4. 若需放弃本次变基并恢复原状: git rebase --abort"
    Write-Host "================================================================" -ForegroundColor Red
    exit 1
}

$currentHead = git rev-parse --short HEAD
Write-Host "√ antigravity 分支变基成功！最新提交: $currentHead" -ForegroundColor Green

# -------------------------------------------------------------
# 步骤 6：构建与验证
# -------------------------------------------------------------
if ($SkipBuild) {
    Write-Host "`n>>> [步骤 6/6] 跳过构建步骤 (-SkipBuild)。" -ForegroundColor Yellow
    Write-Host "`n升级完成！当前 antigravity 分支已成功基于 upstream/main ($upstreamHead)。" -ForegroundColor Green
    exit 0
}

Write-Host "`n>>> [步骤 6/6] 执行构建与验证..." -ForegroundColor Cyan

# 运行前端类型检查
Write-Host "正在运行前端类型检查 (pnpm typecheck)..." -ForegroundColor Gray
pnpm typecheck
if ($LASTEXITCODE -ne 0) {
    Write-Error "【错误】前端类型检查未通过，请检查 TypeScript 类型定义。"
    exit 1
}
Write-Host "√ 前端类型检查通过。" -ForegroundColor Green

# 检查本地 Rust 和 MSVC C++ 链接器
$hasRust = Get-Command cargo -ErrorAction SilentlyContinue
if (-not $hasRust -and (Test-Path "C:\Users\hantengfei\scoop\persist\rustup\.cargo\bin\cargo.exe")) {
    $env:PATH = "C:\Users\hantengfei\scoop\persist\rustup\.cargo\bin;C:\Users\hantengfei\scoop\shims;" + $env:PATH
    $hasRust = Get-Command cargo -ErrorAction SilentlyContinue
}
$hasLinker = Get-Command link.exe -ErrorAction SilentlyContinue

if ($hasRust -and $hasLinker) {
    Write-Host "检测到本地具备完整 Rust + MSVC 编译环境，开始本地 Windows x64 构建..." -ForegroundColor Cyan
    $confModified = $false
    if (-not $env:TAURI_SIGNING_PRIVATE_KEY) {
        $confPath = "src-tauri/tauri.conf.json"
        $conf = Get-Content $confPath -Raw | ConvertFrom-Json
        if ($conf.plugins) {
            $conf.plugins.PSObject.Properties.Remove('updater')
            $conf | ConvertTo-Json -Depth 30 | Set-Content $confPath
            $confModified = $true
        }
    }
    try {
        pnpm tauri build
    } finally {
        if ($confModified) {
            git checkout -- src-tauri/tauri.conf.json 2>$null
        }
    }
    if ($LASTEXITCODE -eq 0) {
        Write-Host "√ 本地构建成功！" -ForegroundColor Green
        Write-Host "`n================================================================" -ForegroundColor Green
        Write-Host "【构建产物信息】" -ForegroundColor Green
        Write-Host "官方版本基础 : upstream/main ($upstreamHead)"
        Write-Host "当前补丁提交 : $currentHead"
        Write-Host "安装包文件路径:"
        $bundles = Get-ChildItem -Path "src-tauri/target/release/bundle/nsis/*.exe", "src-tauri/target/release/bundle/msi/*.msi" -ErrorAction SilentlyContinue
        $bundles | ForEach-Object { Write-Host " - $($_.FullName)" -ForegroundColor Yellow }
        Write-Host "================================================================" -ForegroundColor Green
    } else {
        Write-Error "【错误】本地 Tauri 构建失败，请查看上方编译日志。"
        exit 1
    }
} else {
    Write-Host "提示: 本机缺少 MSVC C++ 链接器 (link.exe)，将自动推送至 origin/antigravity 并触发 GitHub Actions 云端构建..." -ForegroundColor Yellow
    git push -f origin antigravity
    Write-Host "√ 代码已成功推送至 origin/antigravity" -ForegroundColor Green

    $hasGh = Get-Command gh -ErrorAction SilentlyContinue
    if ($hasGh) {
        Write-Host "正在触发 GitHub Actions 构建工作流 (build-windows.yml)..." -ForegroundColor Cyan
        gh workflow run build-windows.yml --ref antigravity
        Write-Host "√ GitHub Actions 构建任务已成功触发！" -ForegroundColor Green
        $slug = ($originUrl -replace '^https://github.com/', '') -replace '\.git$', ''
        Write-Host "构建进度与安装包下载链接: https://github.com/$slug/actions" -ForegroundColor Cyan
    } else {
        Write-Host "请访问您的 GitHub 仓库 Actions 页面查看构建并下载 Windows x64 安装包 Artifact。" -ForegroundColor Cyan
    }
}

Write-Host "`n升级及构建流程完成！" -ForegroundColor Green
