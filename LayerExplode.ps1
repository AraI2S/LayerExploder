# LayerExplode v1.0.2
# Runs on Windows PowerShell 5.1 / Windows 10-11; no external dependencies.
param(
    [string]$InputDir
)

$ErrorActionPreference = 'Stop'
$script:Version = 'v1.0.2'
$script:OutputName = 'Exploded_Layers.png'
$script:ManifestName = 'Layers.txt'
$script:CanvasWidth = 3840
$script:CanvasHeight = 3840

function Get-InputFolder {
    param([string]$Requested)
    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        $Requested = $Requested.Trim().Trim('"')
        if (-not (Test-Path -LiteralPath $Requested -PathType Container)) {
            throw "找不到素材文件夹：$Requested"
        }
        return (Get-Item -LiteralPath $Requested).FullName
    }

    Add-Type -AssemblyName System.Windows.Forms
    $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
    try {
        $dialog.Description = '选择包含图片和 Layers.txt 的素材文件夹'
        $dialog.ShowNewFolderButton = $false
        $result = $dialog.ShowDialog()
        if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
        return $dialog.SelectedPath
    }
    finally {
        $dialog.Dispose()
    }
}

function Ensure-Manifest {
    param([string]$Folder)
    $manifest = Join-Path $Folder $script:ManifestName
    if (Test-Path -LiteralPath $manifest -PathType Leaf) { return $true }

    $files = @(Get-ChildItem -LiteralPath $Folder -File |
        Where-Object {
            ($_.Extension -match '^\.(png|jpg|jpeg)$') -and
            ($_.Name -ine $script:OutputName) -and
            ($_.Name -ine 'Exploded_Layers.__writing__.png')
        } | Sort-Object Name)
    if ($files.Count -eq 0) {
        throw '文件夹内没有 PNG/JPG 图片。请先放入素材。'
    }

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('# 从上到下排列 = 从最上面的工艺层到最下面的卡面。')
    $lines.Add('# 最后一行默认带 > 主图层标记。可直接剪切 / 粘贴这个字符，改选正面主图层。')
    $lines.Add('# 格式：> 图片文件名 | 左侧标签    或    图片文件名 | 左侧标签')
    for ($n = 0; $n -lt $files.Count; $n++) {
        $file = $files[$n]
        $label = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        $prefix = if ($n -eq ($files.Count - 1)) { '> ' } else { '' }
        $lines.Add(('{0}{1} | {2}' -f $prefix, $file.Name, $label))
    }
    $utf8bom = [System.Text.UTF8Encoding]::new($true)
    [System.IO.File]::WriteAllLines($manifest, [string[]]$lines.ToArray(), $utf8bom)
    Write-Host ''
    Write-Host '首次运行：已创建 Layers.txt，并将在记事本中打开。' -ForegroundColor Cyan
    Write-Host '最下面一行已预先带上 > 标记。请调整顺序，并按需把 > 移到正面主图层。'
    Write-Host '例如：把 > 移到倒数第二行，最后一行便作为完整背面展示。'
    Write-Host "配置文件：$manifest"
    try {
        Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $manifest) | Out-Null
    }
    catch {
        Write-Host '自动打开记事本失败，请手动打开 Layers.txt。' -ForegroundColor Yellow
    }
    return $false
}

function Read-Layers {
    param([string]$Folder)
    $manifest = Join-Path $Folder $script:ManifestName
    $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
    try {
        $lines = [System.IO.File]::ReadAllLines($manifest, $strictUtf8)
    }
    catch {
        throw '读取 Layers.txt 失败。请将 TXT 保存为 UTF-8 编码。'
    }

    $layers = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}
    $lineNumber = 0
    $mainCount = 0
    $mainIndex = -1

    foreach ($raw in $lines) {
        $lineNumber++
        $line = $raw.Trim()
        if ($line.Length -eq 0 -or $line.StartsWith('#')) { continue }

        $isMain = $false
        if ($line.StartsWith('>')) {
            $isMain = $true
            $line = $line.Substring(1).Trim()
        }
        elseif ($line.StartsWith('->')) {
            # Compatibility with existing Layers.txt files from earlier versions.
            $isMain = $true
            $line = $line.Substring(2).Trim()
        }
        elseif ($line.StartsWith('=>')) {
            $isMain = $true
            $line = $line.Substring(2).Trim()
        }
        elseif ($line.StartsWith('→')) {
            $isMain = $true
            $line = $line.Substring(1).Trim()
        }

        $separatorIndex = $line.IndexOf('|')
        if ($separatorIndex -ge 0) {
            $fileName = $line.Substring(0, $separatorIndex).Trim()
            $label = $line.Substring($separatorIndex + 1).Trim()
        }
        else {
            $fileName = $line
            $label = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
        }

        if ([string]::IsNullOrWhiteSpace($fileName)) {
            throw "Layers.txt 第 $lineNumber 行缺少图片文件名。"
        }
        if ([System.IO.Path]::GetFileName($fileName) -cne $fileName) {
            throw "Layers.txt 第 $lineNumber 行请只填写文件名，不要填写子目录或完整路径。"
        }
        if ($fileName -ieq $script:OutputName -or $fileName -ieq 'Exploded_Layers.__writing__.png') {
            throw 'Layers.txt 不能把生成结果当作输入图片。'
        }
        if ([System.IO.Path]::GetExtension($fileName) -notmatch '^\.(png|jpg|jpeg)$') {
            throw "不支持的图片格式：$fileName（只支持 PNG、JPG、JPEG）。"
        }
        if ($seen.ContainsKey($fileName)) {
            throw "Layers.txt 中重复列出了：$fileName"
        }
        $seen[$fileName] = $true
        $fullPath = Join-Path $Folder $fileName
        if (-not [System.IO.File]::Exists($fullPath)) {
            throw "找不到图片：$fileName（Layers.txt 第 $lineNumber 行）。"
        }

        $layers.Add([pscustomobject]@{
            FileName = $fileName
            FilePath = $fullPath
            Label = $label
            Width = 0
            Height = 0
            IsMain = $isMain
        })

        if ($isMain) {
            $mainCount++
            $mainIndex = $layers.Count - 1
        }
    }

    if ($layers.Count -eq 0) { throw 'Layers.txt 没有有效的图层记录。' }
    if ($mainCount -gt 1) { throw 'Layers.txt 只能有一个主图层（行首 > 标记）。' }
    if ($mainIndex -lt 0) {
        $mainIndex = $layers.Count - 1
        $layers[$mainIndex].IsMain = $true
    }

    return [pscustomobject]@{
        Layers = $layers.ToArray()
        MainIndex = $mainIndex
    }
}

function Inspect-Layers {
    param([object[]]$Layers, [int]$MainIndex)
    Add-Type -AssemblyName System.Drawing

    foreach ($layer in $Layers) {
        $image = $null
        try {
            $image = [System.Drawing.Image]::FromFile($layer.FilePath)
            $layer.Width = $image.Width
            $layer.Height = $image.Height
            if ($layer.Width -le 0 -or $layer.Height -le 0) {
                throw "图片尺寸异常：$($layer.FileName)"
            }
        }
        finally {
            if ($null -ne $image) { $image.Dispose() }
        }
    }

    $base = $Layers[$MainIndex]
    $aspect = [double]$base.Width / [double]$base.Height
    if ($aspect -le 0.0) {
        throw "主图层比例异常：$($base.FileName)"
    }

    return [pscustomobject]@{
        BaseFileName = $base.FileName
        BaseWidth = $base.Width
        BaseHeight = $base.Height
        BaseAspect = $aspect
    }
}

function Get-CoverSourceRect {
    param(
        [int]$ImageWidth,
        [int]$ImageHeight,
        [double]$TargetAspect
    )

    $imageAspect = [double]$ImageWidth / [double]$ImageHeight
    if ([Math]::Abs($imageAspect - $TargetAspect) -lt 0.000001) {
        return [System.Drawing.RectangleF]::new(0.0, 0.0, [single]$ImageWidth, [single]$ImageHeight)
    }

    if ($imageAspect -gt $TargetAspect) {
        $cropWidth = [double]$ImageHeight * $TargetAspect
        $cropX = ([double]$ImageWidth - $cropWidth) / 2.0
        return [System.Drawing.RectangleF]::new([single]$cropX, 0.0, [single]$cropWidth, [single]$ImageHeight)
    }
    else {
        $cropHeight = [double]$ImageWidth / $TargetAspect
        $cropY = ([double]$ImageHeight - $cropHeight) / 2.0
        return [System.Drawing.RectangleF]::new(0.0, [single]$cropY, [single]$ImageWidth, [single]$cropHeight)
    }
}

function Render-Composition {
    param(
        [object[]]$Layers,
        [int]$MainIndex,
        [double]$AspectRatio,
        [string]$Folder
    )
    $W = [int]$script:CanvasWidth
    $H = [int]$script:CanvasHeight
    $count = [int]$Layers.Count

    $maxProjectedWidth = [double]$W * 0.455
    $maxProjectedHeight = [double]$H * 0.235
    $availableHeight = [double]$H * 0.86
    $relativeAspect = $AspectRatio / (2.0 / 3.0)

    $rawUX = 900.0 * $relativeAspect
    $rawUY = 295.0 * $relativeAspect
    $rawVX = -1020.0
    $rawVY = 655.0
    $fit = [Math]::Min($maxProjectedWidth / ($rawUX - $rawVX), $maxProjectedHeight / ($rawUY + $rawVY))
    $ux = [double]$rawUX * $fit
    $uy = [double]$rawUY * $fit
    $vx = [double]$rawVX * $fit
    $vy = [double]$rawVY * $fit
    $sheetHeight = $uy + $vy

    $lowerGapUnits = if ($MainIndex -lt $count - 1) { 0.18 } else { 0.0 }
    $gapUnits = [Math]::Max(0, $count - 1) + $lowerGapUnits
    if ($gapUnits -gt 0) {
        $step = [Math]::Min($H * 0.155, ($availableHeight - $sheetHeight) / $gapUnits)
    }
    else {
        $step = 0.0
    }
    if ($step -lt ($H * 0.075) -and $count -gt 1) {
        Write-Host "提示：$count 层较多，图层和标签可能比较密集。" -ForegroundColor Yellow
    }

    $positions = New-Object 'System.Collections.Generic.List[double]'
    $positions.Add(0.0)
    $currentY = 0.0
    for ($i = 1; $i -lt $count; $i++) {
        $gap = $step
        if (($i - 1) -eq $MainIndex) {
            $gap = $step * 1.18
        }
        $currentY += $gap
        $positions.Add($currentY)
    }
    $totalHeight = $sheetHeight + $currentY
    $startY = ($H - $totalHeight) / 2.0

    $centerX = $W * 0.695
    $upperLeftX = $centerX - ($ux + $vx) / 2.0
    $stackLeft = [double]$upperLeftX + $vx
    $labelRight = [single]($stackLeft - $W * 0.038)
    $labelLeftLimit = [single]($W * 0.07)
    $labelMaxWidth = [single]($W * 0.26)

    $bitmap = $null
    $graphics = $null
    $brush = $null
    $sheetBrush = $null
    $edgePen = $null
    $topEdgePen = $null
    $format = $null
    $tempPath = Join-Path $Folder 'Exploded_Layers.__writing__.png'
    $finalPath = Join-Path $Folder $script:OutputName

    try {
        $bitmap = [System.Drawing.Bitmap]::new($W, $H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceOver
        $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        # A neutral sheet acts as a directional filter: an upper sheet dims lower ones.
        # DrawImage is SourceOver, painted bottom-to-top. Ink and sheet should NOT be
        # separately flattened onto an opaque temporary background.
        $sheetBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(66, 205, 212, 227))
        # Fine perimeter edges make the front/back order readable at intersections.
        $edgePen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(100, 48, 56, 74), [single]2.4)
        $topEdgePen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(100, 244, 247, 251), [single]1.8)

        for ($i = $count - 1; $i -ge 0; $i--) {
            $layer = $Layers[$i]
            $y = $startY + $positions[$i]
            $points = [System.Drawing.PointF[]]@(
                [System.Drawing.PointF]::new([single]$upperLeftX, [single]$y),
                [System.Drawing.PointF]::new([single]($upperLeftX + $ux), [single]($y + $uy)),
                [System.Drawing.PointF]::new([single]($upperLeftX + $vx), [single]($y + $vy))
            )

            if ($i -lt $MainIndex) {
                $fourth = [System.Drawing.PointF]::new([single]($upperLeftX + $ux + $vx), [single]($y + $uy + $vy))
                $outline = [System.Drawing.PointF[]]@($points[0], $points[1], $fourth, $points[2])
                $graphics.FillPolygon($sheetBrush, $outline)
            }

            $img = $null
            $attributes = $null
            try {
                $img = [System.Drawing.Image]::FromFile($layer.FilePath)
                $opacity = if ($i -lt $MainIndex) { 0.68 } else { 1.0 }
                $matrix = [System.Drawing.Imaging.ColorMatrix]::new()
                $matrix.Matrix33 = [single]$opacity
                $attributes = [System.Drawing.Imaging.ImageAttributes]::new()
                $attributes.SetColorMatrix($matrix)
                $source = Get-CoverSourceRect -ImageWidth $img.Width -ImageHeight $img.Height -TargetAspect $AspectRatio
                $graphics.DrawImage($img, $points, $source, [System.Drawing.GraphicsUnit]::Pixel, $attributes)
            }
            finally {
                if ($null -ne $attributes) { $attributes.Dispose() }
                if ($null -ne $img) { $img.Dispose() }
            }
            if ($i -lt $MainIndex) {
                # Occlusion cues must be painted AFTER this layer's image, so that
                # the next (higher) layer naturally covers the previous outline.
                $graphics.DrawPolygon($edgePen, $outline)
                $graphics.DrawLine($topEdgePen, $points[0], $points[1])
            }
            $completed = $count - $i
            $percent = [int][Math]::Round(($completed * 100.0) / $count)
            Write-Host -NoNewline ("`r绘制图层：{0}/{1} ({2}%)  " -f $completed, $count, $percent)
        }
        Write-Host ''

        $brush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 245, 247, 250))
        $format = [System.Drawing.StringFormat]::new()
        $format.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
        if ($count -gt 1) {
            $baseFontSize = [Math]::Min($H * 0.022, [Math]::Max(34.0, $step * 0.22))
        } else {
            $baseFontSize = $H * 0.022
        }

        for ($i = 0; $i -lt $count; $i++) {
            $label = [string]$Layers[$i].Label
            if ([string]::IsNullOrEmpty($label)) { continue }
            $font = $null
            try {
                $size = [double]$baseFontSize
                $measured = $null
                while ($true) {
                    if ($null -ne $font) { $font.Dispose() }
                    $font = [System.Drawing.Font]::new('Microsoft YaHei', [single]$size, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
                    $measured = $graphics.MeasureString($label, $font)
                    if ($measured.Width -le $labelMaxWidth -or $size -le 26.0) { break }
                    $size -= 2.0
                }
                if ($measured.Width -gt $labelMaxWidth) {
                    Write-Host "提示：标签过长，可能比较拥挤：$label" -ForegroundColor Yellow
                }
                $centerY = $startY + $positions[$i] + $sheetHeight * 0.52
                $textY = [single]($centerY - $measured.Height / 2.0)
                $textX = [single]($labelRight - $measured.Width)
                if ($textX -lt $labelLeftLimit) { $textX = $labelLeftLimit }
                $graphics.DrawString($label, $font, $brush, $textX, $textY, $format)
            }
            finally {
                if ($null -ne $font) { $font.Dispose() }
            }
        }

        if ([System.IO.File]::Exists($tempPath)) {
            [System.IO.File]::Delete($tempPath)
        }
        $bitmap.Save($tempPath, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        if ($null -ne $format) { $format.Dispose() }
        if ($null -ne $brush) { $brush.Dispose() }
        if ($null -ne $sheetBrush) { $sheetBrush.Dispose() }
        if ($null -ne $edgePen) { $edgePen.Dispose() }
        if ($null -ne $topEdgePen) { $topEdgePen.Dispose() }
        if ($null -ne $graphics) { $graphics.Dispose() }
        if ($null -ne $bitmap) { $bitmap.Dispose() }
    }

    Move-Item -LiteralPath $tempPath -Destination $finalPath -Force
    Write-Host "生成完成：$finalPath" -ForegroundColor Green
    Write-Host ("画布：{0}×{1} / 透明 PNG / 图层数：{2} / 主图层：{3}" -f $W, $H, $count, $Layers[$MainIndex].FileName)
}

try {
    Write-Host "LayerExplode $script:Version"
    $folder = Get-InputFolder -Requested $InputDir
    if ([string]::IsNullOrEmpty($folder)) {
        Write-Host '已取消。'
        exit 0
    }
    Write-Host "素材目录：$folder"
    if (-not (Ensure-Manifest -Folder $folder)) { exit 0 }

    $parsed = Read-Layers -Folder $folder
    $layers = @($parsed.Layers)
    $mainIndex = [int]$parsed.MainIndex
    $baseInfo = Inspect-Layers -Layers $layers -MainIndex $mainIndex
    Write-Host ("读取完成：{0} 行；主图层：{1}（{2}×{3}，作为基准比例）" -f $layers.Count, $baseInfo.BaseFileName, $baseInfo.BaseWidth, $baseInfo.BaseHeight)
    Render-Composition -Layers $layers -MainIndex $mainIndex -AspectRatio $baseInfo.BaseAspect -Folder $folder
    exit 0
}
catch {
    Write-Host ''
    Write-Host ('错误：' + $_.Exception.Message) -ForegroundColor Red
    if ($_.Exception.InnerException) {
        Write-Host ('内部原因：' + $_.Exception.InnerException.Message) -ForegroundColor DarkYellow
    }
    exit 1
}
