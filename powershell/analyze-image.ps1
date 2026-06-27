param(
    [string]$ImagePath,
    [switch]$Clipboard,
    [string]$OCRLanguage = "tha+eng",
    [int]$MinConfidence = 70,
    [int]$SampleCount = 2000,
    [int]$QuantizeTolerance = 15,
    [switch]$Full,
    [switch]$Json
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$tempDir = "$env:TEMP\image-to-code"

if (-not $ImagePath -and -not $Clipboard) {
    Write-Error "Provide -ImagePath <file> or -Clipboard (to read from clipboard)"
    exit 1
}

if ($Clipboard) {
    Add-Type -AssemblyName System.Windows.Forms
    $clipImg = [System.Windows.Forms.Clipboard]::GetImage()
    if (-not $clipImg) {
        Write-Error "No image found in clipboard"
        exit 1
    }
    if (-not (Test-Path $tempDir)) { $null = New-Item -ItemType Directory -Path $tempDir -Force }
    $savePath = Join-Path $tempDir "clipboard_$(Get-Date -Format 'yyyyMMdd_HHmmss').png"
    $clipImg.Save($savePath, [System.Drawing.Imaging.ImageFormat]::Png)
    $clipImg.Dispose()
    Write-Output ""
    Write-Output "[Clipboard image saved to: $savePath]"
    $resolvedPath = $savePath
} else {
    $resolvedPath = Resolve-Path -LiteralPath $ImagePath -ErrorAction Stop
    $resolvedPath = $resolvedPath.Path
}

Write-Progress -Activity "Analyzing Image" -Status "Extracting colors..." -PercentComplete 10
$colorsRaw = & "$scriptDir\extract-colors.ps1" -ImagePath $resolvedPath -SampleCount $SampleCount -QuantizeTolerance $QuantizeTolerance -Json 2>$null
try { $colors = $colorsRaw | ConvertFrom-Json } catch { $colors = $null }

$isPhoto = if ($colors) { $colors.isPhoto } else { $false }

Write-Progress -Activity "Analyzing Image" -Status "Detecting layout..." -PercentComplete 35
$layoutRaw = & "$scriptDir\detect-layout.ps1" -ImagePath $resolvedPath -Json 2>$null
try { $layout = $layoutRaw | ConvertFrom-Json } catch { $layout = $null }

Write-Progress -Activity "Analyzing Image" -Status "Running OCR..." -PercentComplete 60
$ocrRaw = & "$scriptDir\ocr.ps1" -ImagePath $resolvedPath -Language $OCRLanguage -MinConfidence $MinConfidence -Json 2>$null
$ocrBoxes = @()
$ocrRawText = ""
$ocrByZone = $null
if ($ocrRaw -and $ocrRaw.Trim() -ne "" -and $ocrRaw.Trim() -ne "[]") {
    try { $parsed = $ocrRaw | ConvertFrom-Json } catch { $parsed = $null }
    if (-not $parsed) { $parsed = @() }
    if ($parsed.PSObject.Properties.Name -contains "boxes") {
        # New format: { words, boxes, rawText, byZone }
        $ocrBoxes = if ($parsed.boxes) { $parsed.boxes } else { @() }
        $ocrRawText = if ($parsed.rawText) { $parsed.rawText } else { "" }
        $ocrByZone = $parsed.byZone
    } else {
        # Old format: array []
        $ocrBoxes = $parsed
    }
} else {
    $ocrBoxes = @()
}

Write-Progress -Activity "Analyzing Image" -Status "Generating report..." -PercentComplete 90

$w = if ($colors) { $colors.imageWidth } else { 0 }
$h = if ($colors) { $colors.imageHeight } else { 0 }
$layoutType = if ($layout) { $layout.layoutType } else { "unknown" }
$radiusVal = if ($layoutType -match "mobile") { "8px" } else { "6px" }
$vpVal = if ($w -le 430) { "width=device-width, initial-scale=1.0" } else { "" }
$mqVal = if ($w -le 430) { "mobile" } elseif ($w -le 768) { "tablet" } else { "desktop" }

# Organize OCR by zone
$textByZone = if ($ocrByZone) {
    $ocrByZone
} else {
    [PSCustomObject]@{
        top    = ($ocrBoxes | Where-Object { $_.zone -eq "top" }).text -join ' '
        middle = ($ocrBoxes | Where-Object { $_.zone -eq "middle" }).text -join ' '
        bottom = ($ocrBoxes | Where-Object { $_.zone -eq "bottom" }).text -join ' '
    }
}

# Button detection: large bounding boxes (w>30, h>20) in lower area = UI buttons
$buttons = @()
if ($ocrBoxes -is [array]) {
    $searchH = $h * 0.3  # bottom 70% of image
    $searchTop = $h * 0.25  # ignore very top of image
    foreach ($box in $ocrBoxes) {
        if ($box.w -gt 30 -and $box.h -gt 20 -and $box.conf -gt 80 -and $box.y -gt $searchTop) {
            $buttons += [PSCustomObject]@{
                text = $box.text
                x = $box.x; y = $box.y; w = $box.w; h = $box.h
                zone = $box.zone; conf = $box.conf
            }
        }
    }
}

$result = [PSCustomObject]@{
    imageType = if ($isPhoto) { "photo" } else { "ui" }
    image = [PSCustomObject]@{
        path     = $resolvedPath
        width    = $w
        height   = $h
        aspect   = if ($h -gt 0) { [Math]::Round($w / $h, 3) } else { 0 }
    }
    colors = [PSCustomObject]@{
        background = if ($colors) { $colors.background } else { "#FFFFFF" }
        text       = if ($colors) { $colors.text } else { "#1F2937" }
        accent     = if ($colors) { $colors.button } else { "#4F46E5" }
        border     = if ($colors -and $colors.border) { $colors.border } else { "#E5E7EB" }
        palette    = if ($colors -and $colors.palette) { $colors.palette } else { @() }
        surfaces   = if ($colors -and $colors.surfaces) { $colors.surfaces } else { @() }
        button     = if ($colors) { $colors.button } else { $null }
        textSecondary = if ($colors) { $colors.textSecondary } else { $null }
        contrastRatio = if ($colors) { $colors.contrastRatio } else { 0 }
        harmony    = if ($colors) { $colors.harmony } else { "" }
        gradient   = if ($colors -and $colors.gradient) { $colors.gradient } else { $null }
    }
    layout = [PSCustomObject]@{
        type       = $layoutType
        sections   = if ($layout -and $layout.sections) { $layout.sections } else { @() }
        columns    = if ($layout -and $layout.columns) { $layout.columns } else { @() }
        components = if ($layout -and $layout.components) { $layout.components } else { @() }
    }
    text  = [PSCustomObject]@{
        words     = if ($ocrBoxes -is [array]) { $ocrBoxes.Count } else { 0 }
        boxes     = if ($ocrBoxes -is [array]) { $ocrBoxes } else { @() }
        buttons   = $buttons
        fullText  = if ($ocrRawText) { $ocrRawText } elseif ($ocrBoxes -is [array]) { ($ocrBoxes.text -join ' ') } else { "" }
        byZone    = $textByZone
    }
    css = [PSCustomObject]@{
        customProperties = [PSCustomObject]@{
            "--bg"         = if ($colors) { $colors.background } else { "#FFFFFF" }
            "--surface"    = if ($colors -and $colors.surfaces -and $colors.surfaces.Count -gt 0) { $colors.surfaces[0] } else { if ($colors) { $colors.background } else { "#FFFFFF" } }
            "--text"       = if ($colors) { $colors.text } else { "#1F2937" }
            "--primary"    = if ($colors) { $colors.button } else { "#4F46E5" }
            "--border"     = if ($colors -and $colors.border) { $colors.border } else { "#E5E7EB" }
            "--radius"     = $radiusVal
        }
        surfaces        = if ($colors) { $colors.surfaces } else { @() }
        harmony         = if ($colors) { $colors.harmony } else { "" }
        contrastRatio   = if ($colors) { $colors.contrastRatio } else { 0 }
        gradient        = if ($colors) { $colors.gradient } else { $null }
        viewport        = $vpVal
        mediaQuery      = $mqVal
    }
}

$resultJson = $result | ConvertTo-Json -Depth 10

if ($Json -or $Full) {
    Write-Output $resultJson
}

if (-not $Json) {
    Write-Output ""
    Write-Output "========================================================================"
    Write-Output "  IMAGE ANALYSIS REPORT"
    Write-Output "========================================================================"
    Write-Output ""
    Write-Output "Image: ${w}x${h} ($layoutType, $(if($isPhoto){'photo'}else{'UI'}))"
    Write-Output ""
    Write-Output "--- Colors ---"
    Write-Output "  Background: $($result.colors.background)"
    Write-Output "  Surfaces:   $($result.colors.surfaces -join ', ')"
    Write-Output "  Text:       $($result.colors.text)  (contrast: $($result.colors.contrastRatio):1)"
    if ($result.colors.textSecondary) { Write-Output "  Text(2nd):  $($result.colors.textSecondary)" }
    Write-Output "  Button:     $($result.colors.button)"
    Write-Output "  Border:     $($result.colors.border)"
    Write-Output "  Harmony:    $($result.colors.harmony)"
    Write-Output "  Palette:    $($result.colors.palette.Count) unique colors"
    Write-Output ""
    Write-Output "--- Layout Components ---"
    foreach ($c in $result.layout.components) {
        Write-Output ("  {0,-16} y={1,2}% h={2,2}%  color={3}" -f $c.type, $c.y_pct, $c.h_pct, $c.color)
    }
    Write-Output ""
    Write-Output "--- OCR Text ($($result.text.words) words ≥${MinConfidence}%) ---"
    if ($result.text.fullText) {
        Write-Output $result.text.fullText
    } else {
        Write-Output "  [top]    $($textByZone.top)"
        Write-Output "  [middle] $($textByZone.middle)"
        Write-Output "  [bottom] $($textByZone.bottom)"
    }
    if ($buttons.Count -gt 0) {
        Write-Output "--- UI Buttons ($($buttons.Count)) ---"
        foreach ($b in $buttons) {
            Write-Output ("  [button] {0}  (z={1}, y={2}, c={3}%)" -f $b.text, $b.zone, $b.y, $b.conf)
        }
        Write-Output ""
    }
    Write-Output "--- CSS Recommendations ---"
    $result.css.customProperties.PSObject.Properties | ForEach-Object {
        Write-Output ("  {0}: {1}" -f $_.Name, $_.Value)
    }
    if ($result.colors.gradient) {
        $g = $result.colors.gradient
        Write-Output ("  gradient: $($g.type) $($g.colors -join ' -> ')")
    }
    Write-Output ""
    Write-Output "========================================================================"
}

if ($Full) {
    Write-Output ""
    Write-Output "=== Full JSON Output ==="
    Write-Output $resultJson
}

# Clipboard temp file cleanup
if ($Clipboard -and $savePath -and (Test-Path $savePath)) {
    Remove-Item $savePath -Force -ErrorAction SilentlyContinue
}
