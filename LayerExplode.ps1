# LayerExplode v0.0.2
# Runs on Windows PowerShell 5.1 / Windows 10-11; no external dependencies.
param(
    [string]$InputDir
)

$ErrorActionPreference = 'Stop'
$script:Version = 'v0.0.2'
$script:OutputName = 'Exploded_Layers.png'
$script:ManifestName = 'Layers.txt'
$script:CanvasWidth = 3840
$script:CanvasHeight = 2160

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
    $lines.Add('# 从上到下排列 = 图层从上到下；最后一行 = 作为基准比例与底图的正面海报')
    $lines.Add('# 格式：图片文件名 | 左侧标签。可只写文件名（自动取文件名作为标签）。')
    foreach ($file in $files) {
        $label = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        $lines.Add(('{0} | {1}' -f $file.Name, $label))
    }
    $utf8bom = [System.Text.UTF8Encoding]::new($true)
    [System.IO.File]::WriteAllLines($manifest, [string[]]$lines.ToArray(), $utf8bom)
    Write-Host ''
    Write-Host '首次运行：已创建 Layers.txt，并将在记事本中打开。' -ForegroundColor Cyan
    Write-Host '请把最后一行调整为正面海报（底图）；上层截图尺寸不必一致，程序会按底图比例居中裁切。'
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
    foreach ($raw in $lines) {
        $lineNumber++
        $line = $raw.Trim()
        if ($line.Length -eq 0 -or $line.StartsWith('#')) { continue }

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
        })
    }
    if ($layers.Count -eq 0) { throw 'Layers.txt 没有有效的图层记录。' }
    return $layers.ToArray()
}

function Inspect-Layers {
    param([object[]]$Layers)
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

    $base = $Layers[-1]
    $aspect = [double]$base.Width / [double]$base.Height
    if ($aspect -le 0.0) {
        throw "底图比例异常：$($base.FileName)"
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
        # Too wide: crop left and right.
        $cropWidth = [double]$ImageHeight * $TargetAspect
        $cropX = ([double]$ImageWidth - $cropWidth) / 2.0
        return [System.Drawing.RectangleF]::new([single]$cropX, 0.0, [single]$cropWidth, [single]$ImageHeight)
    }
    else {
        # Too tall: crop top and bottom.
        $cropHeight = [double]$ImageWidth / $TargetAspect
        $cropY = ([double]$ImageHeight - $cropHeight) / 2.0
        return [System.Drawing.RectangleF]::new(0.0, [single]$cropY, [single]$ImageWidth, [single]$cropHeight)
    }
}

function Render-Composition {
    param(
        [object[]]$Layers,
        [double]$AspectRatio,
        [string]$Folder
    )
    $W = [int]$script:CanvasWidth
    $H = [int]$script:CanvasHeight
    $count = [int]$Layers.Count

    # Canvas zones: left for labels, right for the tilted layer stack.
    $maxProjectedWidth = [double]$W * 0.456
    $maxProjectedHeight = [double]$H * 0.426
    $availableHeight = [double]$H * 0.875
    $minimumStep = [double]$H * 0.055
    if ($count -gt 9) {
        $maxProjectedHeight = [Math]::Max($H * 0.285, [Math]::Min($maxProjectedHeight, $availableHeight - ($count - 1) * $minimumStep))
    }

    # The two basis vectors define one affine parallelogram shared by every layer.
    $relativeAspect = $AspectRatio / (2.0 / 3.0)
    $rawUX = 820.0 * $relativeAspect
    $rawUY = 310.0 * $relativeAspect
    $rawVX = -940.0
    $rawVY = 610.0
    $fit = [Math]::Min($maxProjectedWidth / ($rawUX - $rawVX), $maxProjectedHeight / ($rawUY + $rawVY))
    $ux = [double]$rawUX * $fit
    $uy = [double]$rawUY * $fit
    $vx = [double]$rawVX * $fit
    $vy = [double]$rawVY * $fit
    $sheetHeight = $uy + $vy
    $sheetWidth = $ux - $vx

    if ($count -gt 1) {
        $step = [Math]::Min($H * 0.18, ($availableHeight - $sheetHeight) / ($count - 1))
    }
    else {
        $step = 0.0
    }
    if ($step -lt ($H * 0.043) -and $count -gt 1) {
        Write-Host "提示：$count 层较多，图层和标签可能比较密集。" -ForegroundColor Yellow
    }
    $totalHeight = $sheetHeight + ($count - 1) * $step
    $startY = ($H - $totalHeight) / 2.0
    $centerX = $W * 0.695
    $upperLeftX = $centerX - ($ux + $vx) / 2.0

    $bitmap = $null
    $graphics = $null
    $brush = $null
    $sheetBrush = $null
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
        $sheetBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(40, 205, 212, 227))

        # Paint from the opaque front poster (last TXT line) upward to the first line.
        for ($i = $count - 1; $i -ge 0; $i--) {
            $layer = $Layers[$i]
            $y = $startY + $step * $i
            $points = [System.Drawing.PointF[]]@(
                [System.Drawing.PointF]::new([single]$upperLeftX, [single]$y),
                [System.Drawing.PointF]::new([single]($upperLeftX + $ux), [single]($y + $uy)),
                [System.Drawing.PointF]::new([single]($upperLeftX + $vx), [single]($y + $vy))
            )
            if ($i -lt $count - 1) {
                $fourth = [System.Drawing.PointF]::new([single]($upperLeftX + $ux + $vx), [single]($y + $uy + $vy))
                $outline = [System.Drawing.PointF[]]@($points[0], $points[1], $fourth, $points[2])
                $graphics.FillPolygon($sheetBrush, $outline)
            }

            $img = $null
            $attributes = $null
            try {
                $img = [System.Drawing.Image]::FromFile($layer.FilePath)
                if ($i -eq $count - 1) { $opacity = 1.0 } else { $opacity = 0.46 }
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
            $completed = $count - $i
            $percent = [int][Math]::Round(($completed * 100.0) / $count)
            Write-Host -NoNewline ("`r绘制图层：{0}/{1} ({2}%)  " -f $completed, $count, $percent)
        }
        Write-Host ''

        # Labels: same order and vertical anchors as the corresponding images.
        $brush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 245, 247, 250))
        $format = [System.Drawing.StringFormat]::new()
        $format.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
        $labelLeft = [single]($W * 0.044)
        $labelMaxWidth = [single]($W * 0.355)
        if ($count -gt 1) {
            $baseFontSize = [Math]::Min($H * 0.035, [Math]::Max(28.0, $step * 0.57))
        } else {
            $baseFontSize = $H * 0.035
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
                    if ($measured.Width -le $labelMaxWidth -or $size -le 25.0) { break }
                    $size -= 2.0
                }
                if ($measured.Width -gt $labelMaxWidth) {
                    Write-Host "提示：标签过长，可能进入图层区域：$label" -ForegroundColor Yellow
                }
                $centerY = $startY + $step * $i + $sheetHeight * 0.52
                $textY = [single]($centerY - $measured.Height / 2.0)
                $graphics.DrawString($label, $font, $brush, $labelLeft, $textY, $format)
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
        if ($null -ne $graphics) { $graphics.Dispose() }
        if ($null -ne $bitmap) { $bitmap.Dispose() }
    }

    Move-Item -LiteralPath $tempPath -Destination $finalPath -Force
    Write-Host "生成完成：$finalPath" -ForegroundColor Green
    Write-Host ("画布：{0}×{1} / 透明 PNG / 图层数：{2}" -f $W, $H, $count)
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

    $layers = @(Read-Layers -Folder $folder)
    $baseInfo = Inspect-Layers -Layers $layers
    Write-Host ("读取完成：{0} 层；底图：{1}（{2}×{3}，作为基准比例）" -f $layers.Count, $baseInfo.BaseFileName, $baseInfo.BaseWidth, $baseInfo.BaseHeight)
    Render-Composition -Layers $layers -AspectRatio $baseInfo.BaseAspect -Folder $folder
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
