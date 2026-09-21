<#
.SYNOPSIS
    Shirone 博客一键启动脚本（内容分离 / 双仓模式）。

.DESCRIPTION
    把「设置 CONTENT_DIR -> content:sync -> dev」三步固化成一个命令：

      1. 解析内容仓目录：-ContentDir 参数 > 环境变量 CONTENT_DIR > 同级目录自动探测；
      2. 把结果写入当前进程的 CONTENT_DIR（优先级最高，覆盖 .env 与清单文件）；
      3. 执行 pnpm content:sync，把文章 / 数据 / 配置物化进代码仓；
      4. 执行 pnpm dev 启动本地预览（默认 http://localhost:4321/）。

    内容仓不存在时不会硬失败：脚本给出提示，由 content:sync 自行回退到
    .env / shirone.content.json / 单仓（local）模式。

.PARAMETER ContentDir
    内容仓根目录的绝对路径。省略时依次尝试环境变量与同级目录探测。

.PARAMETER Port
    本地预览端口，默认 4321。

.PARAMETER Watch
    额外在新窗口启动 pnpm content:watch，实现「边写边看」的实时同步。

.PARAMETER SkipSync
    跳过脚本内显式的 content:sync（pnpm dev 自身仍会同步一次）。

.EXAMPLE
    .\scripts\start-blog.ps1

.EXAMPLE
    .\scripts\start-blog.ps1 -ContentDir "D:\Code\my-blog-content" -Watch
#>
[CmdletBinding()]
param(
	[string]$ContentDir,
	[int]$Port = 4321,
	[switch]$Watch,
	[switch]$SkipSync
)

$ErrorActionPreference = "Stop"

function Write-Step {
	param([string]$Message)
	Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Info {
	param([string]$Message)
	Write-Host "    $Message" -ForegroundColor DarkGray
}

function Write-Warn2 {
	param([string]$Message)
	Write-Host "[!] $Message" -ForegroundColor Yellow
}

function Fail {
	param([string]$Message)
	Write-Host "[x] $Message" -ForegroundColor Red
	exit 1
}

# ── 定位代码仓根目录（本脚本位于 <repo>\scripts\ 下）───────────────────────
$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot "package.json") -PathType Leaf)) {
	Fail "未能在 $RepoRoot 找到 package.json，请确认脚本位于代码仓的 scripts 目录内。"
}
Set-Location -LiteralPath $RepoRoot

# ── 选择包管理器命令（Windows 上使用 .cmd 版本）─────────────────────────
$Pnpm = if (Get-Command "pnpm.cmd" -ErrorAction SilentlyContinue) {
	"pnpm.cmd"
} elseif (Get-Command "pnpm" -ErrorAction SilentlyContinue) {
	"pnpm"
} else {
	Fail "未找到 pnpm，请先安装 pnpm（npm i -g pnpm）或启用 corepack。"
}

# ── 解析内容仓目录 ───────────────────────────────────────────────────────
function Test-ContentRepo {
	param([string]$Path)
	if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
	if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
	# 内容仓的最低特征：存在 content/ 目录（文章 / 说说 / 系列 / 特殊页）
	return (Test-Path -LiteralPath (Join-Path $Path "content") -PathType Container)
}

$WorkspaceRoot = Split-Path -Parent $RepoRoot
$Candidates = [System.Collections.Generic.List[string]]::new()

if (-not [string]::IsNullOrWhiteSpace($ContentDir)) { $Candidates.Add($ContentDir) }
if (-not [string]::IsNullOrWhiteSpace($env:CONTENT_DIR)) { $Candidates.Add($env:CONTENT_DIR) }

# 自动探测：代码仓同级的常见内容仓命名，再回退到文档里出现的默认位置
foreach ($Name in @("my-blog-content", "shirone-content", "Shirone-Content", "blog-content")) {
	$Candidates.Add((Join-Path $WorkspaceRoot $Name))
}
$Candidates.Add("D:\Code\my-blog-content")

$ResolvedContentDir = $null
foreach ($Candidate in $Candidates) {
	if (Test-ContentRepo -Path $Candidate) {
		$ResolvedContentDir = (Resolve-Path -LiteralPath $Candidate).Path
		break
	}
}

Write-Host ""
Write-Host "Shirone 本地开发启动器" -ForegroundColor Magenta
Write-Info "代码仓：$RepoRoot"

if ($ResolvedContentDir) {
	# 进程环境变量优先级最高：覆盖 .env、.env.local 与 shirone.content.json
	$env:CONTENT_DIR = $ResolvedContentDir
	Write-Info "内容仓：$ResolvedContentDir"
	Write-Info "模式：external（双仓内容分离，CONTENT_DIR 已注入当前进程）"
} else {
	Write-Warn2 "未找到内容仓目录，交由 content:sync 回退到 .env / shirone.content.json / local 单仓模式。"
	Write-Warn2 "可用 -ContentDir <路径> 显式指定内容仓位置。"
}

# 站点可能部署在子路径下（内容仓 config/site.yaml 的 base），本地预览地址要跟着带上：
# 例如 GitHub Pages 项目页对应 base: "/Shirone/"，本地就是 http://localhost:4321/Shirone/
$SiteBase = "/"
if ($ResolvedContentDir) {
	$SiteYaml = Join-Path $ResolvedContentDir "config/site.yaml"
	if (Test-Path -LiteralPath $SiteYaml) {
		$BaseMatch = Select-String -Path $SiteYaml -Pattern '^\s*base:\s*"?([^"#\s]+)"?' |
			Select-Object -First 1
		if ($BaseMatch) { $SiteBase = $BaseMatch.Matches[0].Groups[1].Value }
	}
}
if (-not $SiteBase.StartsWith("/")) { $SiteBase = "/$SiteBase" }
if (-not $SiteBase.EndsWith("/")) { $SiteBase = "$SiteBase/" }
$PreviewUrl = "http://localhost:$Port$SiteBase"
if ($SiteBase -ne "/") { Write-Info "站点子路径：$SiteBase（来自 site.yaml 的 base）" }

# ── 1) 物化同步内容 ─────────────────────────────────────────────────────
if (-not $SkipSync) {
	Write-Step "同步内容：$Pnpm content:sync"
	& $Pnpm content:sync
	if ($LASTEXITCODE -ne 0) {
		Fail "内容同步失败（退出码 $LASTEXITCODE）。可先运行 `"$Pnpm content:validate`" 排查配置问题。"
	}
} else {
	Write-Info "已按 -SkipSync 跳过显式同步（pnpm dev 仍会同步一次）。"
}

# ── 2) 可选的实时监听 ───────────────────────────────────────────────────
if ($Watch) {
	Write-Step "启动实时同步监听：$Pnpm content:watch（新窗口）"
	Start-Process -FilePath $Pnpm -ArgumentList "content:watch" -WorkingDirectory $RepoRoot | Out-Null
}

# ── 3) 启动开发服务器（前台阻塞直到 Ctrl+C）──────────────────────────────
Write-Step "启动开发服务器：$Pnpm dev --port $Port"
Write-Info "预览地址：$PreviewUrl"
Write-Info "按 Ctrl+C 停止。"
Write-Host ""

& $Pnpm dev --port $Port
exit $LASTEXITCODE
