#Requires -Version 5.1
<#
.SYNOPSIS
    把 Windows 用户文件夹迁到其他磁盘，原路径保留目录联接。

.DESCRIPTION
    重装系统后的标准动作：C 盘只留系统，Desktop / Documents / Downloads 这些
    天天长大的目录搬到大盘。搬完原路径变成 junction，硬编码 %USERPROFILE%
    的软件照常读写，不用逐个改配置。不需要管理员权限。

    默认只演练，确认无误再加 -Apply。

.PARAMETER ProfileRoot
    要处理的用户目录，默认当前用户。指定其他路径可迁移别的账户或做沙箱测试。

.PARAMETER TargetRoot
    必填。目标根目录，每个文件夹落到 <TargetRoot>\<名称>。

.PARAMETER Folders
    要迁移的文件夹名，默认六个标准用户目录。

.PARAMETER Apply
    真正执行。不加则只打印将要做什么。

.PARAMETER Undo
    回滚：删除联接并把内容搬回用户目录。

.PARAMETER AdoptExisting
    目标位置已有同名目录时默认中止。脚本能认出自己上次迁过哪些目录（靠目标根下的
    标记文件），但认不出来的是你自己建的还是别处拷来的，只能由你确认。
    加这个开关表示"这些目录我知道，合并进去"。

.PARAMETER SyncShellFolders
    顺带改写注册表 Shell Folders，让资源管理器属性页显示真实位置。
    联接本身已覆盖所有路径解析，此开关纯粹为了界面一致，需重新登录生效。

.EXAMPLE
    .\Relocate-UserFolders.ps1 -TargetRoot 'D:\'
    演练，显示计划。

.EXAMPLE
    .\Relocate-UserFolders.ps1 -TargetRoot 'D:\' -Apply
    迁移到 D 盘。

.EXAMPLE
    .\Relocate-UserFolders.ps1 -TargetRoot 'D:\' -Folders Downloads,Pictures -Apply
    只迁下载和图片。

.EXAMPLE
    .\Relocate-UserFolders.ps1 -TargetRoot 'D:\' -Undo -Apply
    回滚。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$TargetRoot,

    [string]$ProfileRoot = [Environment]::GetFolderPath('UserProfile'),
    [string[]]$Folders = @('Desktop', 'Documents', 'Downloads', 'Music', 'Pictures', 'Videos'),
    [switch]$Apply,
    [switch]$Undo,
    [switch]$AdoptExisting,
    [switch]$SyncShellFolders
)

$ErrorActionPreference = 'Stop'
$Results = [System.Collections.Generic.List[object]]::new()

$MarkerPath = Join-Path $TargetRoot '.relocate-userfolders.json'
$driveRoot = [System.IO.Path]::GetPathRoot($TargetRoot)
if (-not (Test-Path -LiteralPath $driveRoot)) {
    throw "目标磁盘不存在：$driveRoot"
}
if ($Apply -and -not (Test-Path -LiteralPath $TargetRoot)) {
    $null = New-Item -ItemType Directory -Path $TargetRoot -Force
}

# robocopy 用退出码 1 表示"成功复制了文件"，别让它被当成错误
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

# 注册表值名，仅 -SyncShellFolders 使用
$ShellFolderValue = @{
    Desktop   = 'Desktop'
    Documents = 'Personal'
    Downloads = '{374DE290-123F-4565-9164-39C4925E467B}'
    Music     = 'My Music'
    Pictures  = 'My Pictures'
    Videos    = 'My Video'
}

function Say {
    param([string]$Text, [string]$Color = 'Gray')
    Write-Host "  $Text" -ForegroundColor $Color
}

function New-Junction {
    param([string]$Path, [string]$Target)
    $out = cmd /c "mklink /J `"$Path`" `"$Target`"" 2>&1
    if ((Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue).LinkType -ne 'Junction') {
        throw "建立联接失败：$Path`n$out"
    }
}

function Remove-Junction {
    param([string]$Path)
    # 必须走 Directory::Delete：PS 5.1 的 Remove-Item -Recurse 会连联接目标里的内容一起删
    [System.IO.Directory]::Delete($Path, $false)
}

function Move-Tree {
    param([string]$Source, [string]$Target)
    if (-not (Test-Path -LiteralPath $Target)) {
        $null = New-Item -ItemType Directory -Path $Target -Force
    }
    # /XJ 跳过源目录内部的联接，否则会顺着它把整个目标盘复制一遍
    robocopy $Source $Target /MOVE /E /XJ /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy 失败（退出码 $LASTEXITCODE）：$Source -> $Target"
    }
    # 必须写 $global:：函数内直接赋值只会改局部变量，退出码照样污染到脚本末尾
    $global:LASTEXITCODE = 0
}

function Set-ShellFolder {
    param([string]$Name, [string]$Path)
    $value = $ShellFolderValue[$Name]
    if (-not $value) { return }
    $base = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'
    New-ItemProperty -Path "$base\User Shell Folders" -Name $value -Value $Path -PropertyType ExpandString -Force | Out-Null
    New-ItemProperty -Path "$base\Shell Folders" -Name $value -Value $Path -PropertyType String -Force | Out-Null
}

# 目标根下的标记文件，记下哪些目录是本工具迁的。目标位置已存在同名目录时，
# 只有靠它才能分辨"上次迁移的残留"和"用户自己建的"，否则只能中止等人工确认。
function Read-Marker {
    if (-not (Test-Path -LiteralPath $MarkerPath)) { return @{} }
    $json = Get-Content -LiteralPath $MarkerPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $table = @{}
    if ($json.migrated) {
        foreach ($p in $json.migrated.PSObject.Properties) { $table[$p.Name] = $p.Value }
    }
    $table
}

function Write-Marker {
    param([hashtable]$Migrated)
    [ordered]@{
        version     = 1
        profileRoot = $ProfileRoot
        migrated    = $Migrated
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $MarkerPath -Encoding UTF8
}

$Migrated = Read-Marker

$mode = if ($Undo) { '回滚' } elseif ($Apply) { '执行' } else { '演练' }
Write-Host "用户目录  $ProfileRoot"
Write-Host "目标根    $TargetRoot"
Write-Host "模式      $mode" -ForegroundColor $(if ($Apply) { 'Yellow' } else { 'DarkGray' })

foreach ($name in $Folders) {
    $old = Join-Path $ProfileRoot $name
    $new = Join-Path $TargetRoot $name

    Write-Host "`n$name" -ForegroundColor Cyan
    Write-Host "  $old  ->  $new"

    $item = Get-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
    $isLink = $item -and $item.LinkType
    $targets = if ($isLink) { @($item.Target) } else { @() }

    if ($Undo) {
        if (-not $isLink) {
            Say '不是联接，跳过' DarkGray
            $Results.Add([pscustomobject]@{ 文件夹 = $name; 结果 = '跳过（非联接）' })
            continue
        }
        if (-not (Test-Path -LiteralPath $new)) {
            Say "联接目标不存在：$new，跳过" Yellow
            $Results.Add([pscustomobject]@{ 文件夹 = $name; 结果 = '跳过（目标缺失）' })
            continue
        }

        $size = (Get-ChildItem -LiteralPath $new -Recurse -Force -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
        $free = (New-Object System.IO.DriveInfo ([System.IO.Path]::GetPathRoot($ProfileRoot))).AvailableFreeSpace
        if ($size -gt $free) {
            Say "系统盘空间不足（需 $([math]::Round($size / 1GB, 1)) GB），跳过" Yellow
            $Results.Add([pscustomobject]@{ 文件夹 = $name; 结果 = '跳过（空间不足）' })
            continue
        }

        if (-not $Apply) {
            Say "[演练] 搬回 $new -> $old 并删除联接" DarkGray
            $Results.Add([pscustomobject]@{ 文件夹 = $name; 结果 = '待回滚' })
            continue
        }

        Remove-Junction -Path $old
        Move-Tree -Source $new -Target $old
        $Migrated.Remove($name)
        Write-Marker -Migrated $Migrated
        Say '已回滚' Green
        $Results.Add([pscustomobject]@{ 文件夹 = $name; 结果 = '已回滚' })
        continue
    }

    if ($isLink) {
        if ($targets -contains $new) {
            Say '已是联接，无需处理' Green
            $Results.Add([pscustomobject]@{ 文件夹 = $name; 结果 = '已就绪' })
        }
        else {
            Say "已有联接但指向 $($targets -join ', ')，需人工确认" Yellow
            $Results.Add([pscustomobject]@{ 文件夹 = $name; 结果 = "指向异常：$($targets -join ', ')" })
        }
        continue
    }

    # OneDrive 备份中的目录做联接会跟云端同步打架
    if ($env:OneDrive -and (Test-Path -LiteralPath (Join-Path $env:OneDrive $name))) {
        Say 'OneDrive 正在备份此目录，请先在 OneDrive 设置里关闭再重跑' Yellow
        $Results.Add([pscustomobject]@{ 文件夹 = $name; 结果 = '跳过（OneDrive 占用）' })
        continue
    }

    $targetExists = Test-Path -LiteralPath $new

    if (-not $item -and -not $targetExists) {
        Say '新旧位置都不存在，跳过' DarkGray
        $Results.Add([pscustomobject]@{ 文件夹 = $name; 结果 = '跳过（未使用）' })
        continue
    }

    # 目标已存在时先分辨来路，认不出来就不往里灌数据
    $ours = $Migrated.ContainsKey($name)
    if ($targetExists -and -not $ours -and -not $AdoptExisting) {
        $n = @(Get-ChildItem -LiteralPath $new -Force).Count
        Say "$new 已存在（$n 项），不是本工具迁移的。确认要合并进去请加 -AdoptExisting" Yellow
        $Results.Add([pscustomobject]@{ 文件夹 = $name; 结果 = '中止（目标已存在，来路不明）' })
        continue
    }
    if ($targetExists -and $ours) {
        Say "$new 是上次迁移留下的，按合并处理" DarkGray
    }

    $count = if ($item) { @(Get-ChildItem -LiteralPath $old -Force).Count } else { 0 }

    if (-not $Apply) {
        if ($count) { Say "[演练] 迁移 $count 项到 $new" DarkGray }
        Say "[演练] 删除 $old 并建立联接" DarkGray
        $Results.Add([pscustomobject]@{ 文件夹 = $name; 结果 = "待迁移（$count 项）" })
        continue
    }

    if ($count) {
        Move-Tree -Source $old -Target $new
        # robocopy /MOVE 通常连源目录一起删；若留下空壳，确认真的空了再删
        if (Test-Path -LiteralPath $old) {
            if (Get-ChildItem -LiteralPath $old -Force) {
                throw "$old 仍有内容未搬走，已中止以免误删"
            }
            Remove-Item -LiteralPath $old -Force
        }
    }
    elseif (-not $targetExists) {
        $null = New-Item -ItemType Directory -Path $new -Force
    }

    if ($item -and (Test-Path -LiteralPath $old)) { Remove-Item -LiteralPath $old -Force }
    New-Junction -Path $old -Target $new
    if ($SyncShellFolders) { Set-ShellFolder -Name $name -Path $new }

    # 每个目录迁完就落盘，中途出错也不至于让已迁的目录失去标记
    $Migrated[$name] = (Get-Date).ToString('o')
    Write-Marker -Migrated $Migrated

    Say "完成，$count 项已迁入" Green
    $Results.Add([pscustomobject]@{ 文件夹 = $name; 结果 = "已迁移（$count 项）" })
}

Write-Host "`n=== 汇总 ===" -ForegroundColor Cyan
$Results | Format-Table -AutoSize
if (-not $Apply) {
    Write-Host '演练结束，确认无误后加 -Apply 执行。' -ForegroundColor Yellow
}
