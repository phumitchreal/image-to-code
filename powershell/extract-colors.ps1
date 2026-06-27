param(
    [Parameter(Mandatory = $true)]
    [string]$ImagePath,
    [int]$SampleCount = 2000,
    [int]$QuantizeTolerance = 15,
    [switch]$Json
)

Add-Type -AssemblyName System.Drawing

$resolved = Resolve-Path -LiteralPath $ImagePath -ErrorAction Stop
$bmp = [System.Drawing.Bitmap]::FromFile($resolved.Path)
$w = $bmp.Width; $h = $bmp.Height

# Phase 1: Coarse sampling to classify image type
$coarseColors = @{}
$cStepX = [Math]::Max(1, [Math]::Floor($w / 40))
$cStepY = [Math]::Max(1, [Math]::Floor($h / 40))
$lumVals = @()
for ($y = 0; $y -lt $h; $y += $cStepY) {
    for ($x = 0; $x -lt $w; $x += $cStepX) {
        $px = $bmp.GetPixel($x, $y)
        $hex = "#{0:X2}{1:X2}{2:X2}" -f ($px.R -band 0xF0), ($px.G -band 0xF0), ($px.B -band 0xF0)
        $coarseColors[$hex] = 1
        $lumVals += [int](0.299*$px.R + 0.587*$px.G + 0.114*$px.B)
    }
}
$distinctColorCount = $coarseColors.Count
# Compute edge ratio BEFORE sorting (needs spatial adjacency)
$edgeCount = 0; $totalPairs = 0
for ($i = 0; $i -lt $lumVals.Count - 1; $i += 2) {
    if ([Math]::Abs($lumVals[$i] - $lumVals[$i+1]) -gt 40) { $edgeCount++ }
    $totalPairs++
}
$edgeRatio = if ($totalPairs -gt 0) { $edgeCount / $totalPairs } else { 0 }

$lumVals = $lumVals | Sort-Object
$iqr = 0
if ($lumVals.Count -ge 4) {
    $q1 = $lumVals[[Math]::Floor($lumVals.Count / 4)]
    $q3 = $lumVals[[Math]::Floor($lumVals.Count * 3 / 4)]
    $iqr = $q3 - $q1
}
$lumRange = if ($lumVals.Count -ge 2) { $lumVals[-1] - $lumVals[0] } else { 0 }
# Photo: high distinct colors OR controlled variance (gradients) OR wide dynamic range with low edges
$isPhoto = ($distinctColorCount -gt 50) -or ($distinctColorCount -ge 15 -and $iqr -lt 80) -or ($lumRange -gt 150 -and $edgeRatio -lt 0.3)

# Phase 2: Fine pixel sampling
$colorCounts = @{}
$stepX = [Math]::Max(1, [Math]::Floor($w / [Math]::Sqrt($SampleCount * $w / $h)))
$stepY = [Math]::Max(1, [Math]::Floor($h / [Math]::Sqrt($SampleCount * $h / $w)))
$totalSamples = 0

for ($y = 0; $y -lt $h; $y += $stepY) {
    for ($x = 0; $x -lt $w; $x += $stepX) {
        $px = $bmp.GetPixel($x, $y)
        $rq = [Math]::Round($px.R / $QuantizeTolerance) * $QuantizeTolerance
        $gq = [Math]::Round($px.G / $QuantizeTolerance) * $QuantizeTolerance
        $bq = [Math]::Round($px.B / $QuantizeTolerance) * $QuantizeTolerance
        $rq = [Math]::Min(255, [Math]::Max(0, $rq))
        $gq = [Math]::Min(255, [Math]::Max(0, $gq))
        $bq = [Math]::Min(255, [Math]::Max(0, $bq))
        $hex = "#{0:X2}{1:X2}{2:X2}" -f $rq, $gq, $bq
        $colorCounts[$hex] += 1
        $totalSamples++
    }
}

$sorted = $colorCounts.GetEnumerator() | Sort-Object Value -Descending
$total = [Math]::Max(1, $totalSamples)
$palette = @()
foreach ($entry in $sorted) {
    $palette += [PSCustomObject]@{
        hex       = $entry.Key
        pct       = [Math]::Round($entry.Value / $total * 100, 1)
        count     = $entry.Value
    }
}

# Helper: parse hex to RGB
function HexToRGB($hex) {
    $r = [Convert]::ToByte($hex.Substring(1,2), 16)
    $g = [Convert]::ToByte($hex.Substring(3,2), 16)
    $b = [Convert]::ToByte($hex.Substring(5,2), 16)
    return @($r, $g, $b)
}

# Helper: luminance
function Luminance($rgb) {
    return 0.299*$rgb[0] + 0.587*$rgb[1] + 0.114*$rgb[2]
}

# Helper: contrast ratio
function ContrastRatio($lum1, $lum2) {
    $l1 = [Math]::Max($lum1, $lum2) + 0.05
    $l2 = [Math]::Min($lum1, $lum2) + 0.05
    return $l1 / $l2
}

# Helper: saturation (0-100)
function Saturation($rgb) {
    $maxC = [Math]::Max($rgb[0], [Math]::Max($rgb[1], $rgb[2]))
    $minC = [Math]::Min($rgb[0], [Math]::Min($rgb[1], $rgb[2]))
    if ($maxC -eq 0) { return 0 }
    return ($maxC - $minC) / $maxC * 100
}

# Compute per-color metadata
$colorMeta = @()
foreach ($c in $palette) {
    $rgb = HexToRGB $c.hex
    $lum = Luminance $rgb
    $sat = Saturation $rgb
    $colorMeta += [PSCustomObject]@{
        hex    = $c.hex
        pct    = $c.pct
        r      = $rgb[0]
        g      = $rgb[1]
        b      = $rgb[2]
        lum    = $lum
        sat    = [Math]::Round($sat, 1)
    }
}

# Semantic role detection
$bgColor = if ($palette.Count -gt 0) { $palette[0].hex } else { "#FFFFFF" }
$bgMeta = if ($colorMeta.Count -gt 0) { $colorMeta[0] } else { $null }
$bgLum = if ($bgMeta) { $bgMeta.lum } else { 255 }

# For UI: surfaces are colors with >2% frequency that cluster near bg
$surfaces = @()
$textPrimary = $null
$textSecondary = $null
$buttonColor = $null
$borderColor = $null
$borderCandidates = @()

if (-not $isPhoto) {
    $textCandidates = @()
    $buttonCandidates = @()

    foreach ($cm in $colorMeta) {
        $isBg = $cm.hex -eq $bgColor
        $contrast = ContrastRatio $bgLum $cm.lum
        $lumDiff = [Math]::Abs($cm.lum - $bgLum)

        # Surface: near-bg luminance, significant frequency
        if ((-not $isBg) -and $cm.pct -gt 1 -and $lumDiff -lt 40) {
            $surfaces += $cm
        }

        # Border: low frequency, subtle contrast
        if ((-not $isBg) -and $contrast -gt 1.3 -and $cm.pct -lt 2 -and $cm.pct -gt 0.05 -and $lumDiff -gt 2) {
            $borderCandidates += @{hex=$cm.hex; contrast=$contrast; lumDiff=$lumDiff}
        }

        # Button/CTA: high saturation, moderate-low frequency, not too dark
        if ((-not $isBg) -and $cm.sat -gt 20 -and $cm.lum -gt 30 -and $cm.pct -lt 5 -and $cm.pct -gt 0.1) {
            $buttonCandidates += @{hex=$cm.hex; sat=$cm.sat; contrast=$contrast}
        }

        # Text: high contrast, very low frequency
        if ((-not $isBg) -and $contrast -gt 3 -and $cm.pct -lt 3) {
            $textCandidates += @{hex=$cm.hex; contrast=$contrast; lum=$cm.lum}
        }
    }

    # Sort surfaces by frequency (desc)
    $surfaces = $surfaces | Sort-Object pct -Descending

    # Primary text = highest contrast
    if ($textCandidates.Count -gt 0) {
        $bestText = $textCandidates | Sort-Object contrast -Descending | Select-Object -First 1
        $textPrimary = $bestText.hex
        # Secondary = next highest contrast
        $rest = $textCandidates | Where-Object { $_.hex -ne $textPrimary } | Sort-Object contrast -Descending
        if ($rest.Count -gt 0) { $textSecondary = $rest[0].hex }
    } else {
        $textPrimary = if ($bgLum -gt 128) { "#1F2937" } else { "#FFFFFF" }
    }

    if ($buttonCandidates.Count -gt 0) {
        $buttonColor = ($buttonCandidates | Sort-Object sat -Descending | Select-Object -First 1).hex
    }
    if ($borderCandidates.Count -gt 0) {
        $borderColor = ($borderCandidates | Sort-Object lumDiff -Descending | Select-Object -First 1).hex
    }
} else {
    # Photo: surfaces are muted mid-tones near bg luminance
    foreach ($cm in $colorMeta) {
        $isBg = $cm.hex -eq $bgColor
        $lumDiff = [Math]::Abs($cm.lum - $bgLum)
        if ((-not $isBg) -and $cm.pct -gt 0.5 -and $lumDiff -lt 50) {
            $surfaces += $cm
        }
    }
    $surfaces = $surfaces | Sort-Object pct -Descending
    $textPrimary = if ($bgLum -gt 128) { "#1F2937" } else { "#FFFFFF" }
    # Button: highest saturation with moderate frequency
    $buttonCandidates = $colorMeta | Where-Object { $_.sat -gt 20 -and $_.lum -gt 30 -and $_.pct -gt 0.1 -and $_.pct -lt 5 -and $_.hex -ne $bgColor }
    if ($buttonCandidates.Count -gt 0) {
        $buttonColor = ($buttonCandidates | Sort-Object sat -Descending | Select-Object -First 1).hex
    }
    # Also try border detection in photo mode
    foreach ($cm in $colorMeta) {
        $isBg = $cm.hex -eq $bgColor
        $contrast = ContrastRatio $bgLum $cm.lum
        $lumDiff = [Math]::Abs($cm.lum - $bgLum)
        if ((-not $isBg) -and $contrast -gt 1.3 -and $cm.pct -lt 2 -and $cm.pct -gt 0.05 -and $lumDiff -gt 2) {
            $borderCandidates += @{hex=$cm.hex; contrast=$contrast; lumDiff=$lumDiff}
        }
    }
    if ($borderCandidates.Count -gt 0) {
        $borderColor = ($borderCandidates | Sort-Object lumDiff -Descending | Select-Object -First 1).hex
    }
}
# No default fallback — let caller decide

# Gradient detection (works for all images, threshold higher for UI to avoid false positives from section transitions)
$hasGradient = $false
$gradientType = "none"
$gradientColors = @($bgColor)
$gradThreshold = if ($isPhoto) { 30 } else { 50 }
$topLum = 0; $midLum = 0; $botLum = 0; $cnt = 0
for ($y = 0; $y -lt [Math]::Min(50, $h); $y += 2) {
    for ($x = 0; $x -lt $w; $x += 20) {
        $px = $bmp.GetPixel($x, $y)
        $topLum += Luminance @($px.R, $px.G, $px.B); $cnt++
    }
}
$cntM = 0
$midY = [Math]::Floor($h/2) - 25
for ($y = [Math]::Max(0,$midY); $y -lt [Math]::Min($h, $midY+50); $y += 2) {
    for ($x = 0; $x -lt $w; $x += 20) {
        $px = $bmp.GetPixel($x, $y)
        $midLum += Luminance @($px.R, $px.G, $px.B); $cntM++
    }
}
$cntB = 0
$botY = [Math]::Max(0, $h - 50)
for ($y = $botY; $y -lt $h; $y += 2) {
    for ($x = 0; $x -lt $w; $x += 20) {
        $px = $bmp.GetPixel($x, $y)
        $botLum += Luminance @($px.R, $px.G, $px.B); $cntB++
    }
}
if ($cnt -gt 0) { $topLum /= $cnt }
if ($cntM -gt 0) { $midLum /= $cntM }
if ($cntB -gt 0) { $botLum /= $cntB }
$gradRange = [Math]::Max([Math]::Abs($topLum-$botLum), [Math]::Abs($topLum-$midLum))
if ($gradRange -gt $gradThreshold) {
    $hasGradient = $true
    $gradientType = if ([Math]::Abs($topLum - $midLum) -gt 15 -and [Math]::Abs($midLum - $botLum) -gt 15) { "vertical-3tone" } else { "vertical" }
    # Sample 3 colors along vertical axis
    $gradR = 0; $gradG = 0; $gradB = 0; $cnt = 0
    for ($x = [Math]::Floor($w/3); $x -lt [Math]::Floor($w*2/3); $x += 10) {
        $px = $bmp.GetPixel($x, 5)
        $gradR += $px.R; $gradG += $px.G; $gradB += $px.B; $cnt++
    }
    if ($cnt -gt 0) { $gradientColors[0] = "#{0:X2}{1:X2}{2:X2}" -f [int]($gradR/$cnt), [int]($gradG/$cnt), [int]($gradB/$cnt) }
    $cnt=0; $gradR=0; $gradG=0; $gradB=0
    for ($x = [Math]::Floor($w/3); $x -lt [Math]::Floor($w*2/3); $x += 10) {
        $px = $bmp.GetPixel($x, [Math]::Floor($h/2))
        $gradR += $px.R; $gradG += $px.G; $gradB += $px.B; $cnt++
    }
    if ($cnt -gt 0) { $gradientColors += "#{0:X2}{1:X2}{2:X2}" -f [int]($gradR/$cnt), [int]($gradG/$cnt), [int]($gradB/$cnt) }
    $cnt=0; $gradR=0; $gradG=0; $gradB=0
    for ($x = [Math]::Floor($w/3); $x -lt [Math]::Floor($w*2/3); $x += 10) {
        $px = $bmp.GetPixel($x, $h-5)
        $gradR += $px.R; $gradG += $px.G; $gradB += $px.B; $cnt++
    }
    if ($cnt -gt 0) { $gradientColors += "#{0:X2}{1:X2}{2:X2}" -f [int]($gradR/$cnt), [int]($gradG/$cnt), [int]($gradB/$cnt) }
}

$bmp.Dispose()

# Text-bg contrast ratio
$textRgb = HexToRGB $textPrimary
$textLum = Luminance $textRgb
$bgRgb = HexToRGB $bgColor
$bgLum = Luminance $bgRgb
$contrastRatio = [Math]::Round((ContrastRatio $textLum $bgLum), 1)

# Color harmony classification
$hues = @()
foreach ($cm in $colorMeta | Where-Object { $_.pct -gt 0.5 }) {
    $r = $cm.r; $g = $cm.g; $b = $cm.b
    $maxC = [Math]::Max($r, [Math]::Max($g, $b))
    $minC = [Math]::Min($r, [Math]::Min($g, $b))
    if ($maxC -eq $minC) { continue }
    $delta = $maxC - $minC
    if ($maxC -eq $r) { $hueVal = (($g-$b)/$delta) % 6 }
    elseif ($maxC -eq $g) { $hueVal = ($b-$r)/$delta + 2 }
    else { $hueVal = ($r-$g)/$delta + 4 }
    $hueDeg = [Math]::Round($hueVal * 60)
    if ($hueDeg -lt 0) { $hueDeg += 360 }
    $hues += $hueDeg
}
$hueRange = 0
if ($hues.Count -gt 1) {
    $sortedHues = $hues | Sort-Object
    $maxGap = 0
    for ($i = 0; $i -lt $sortedHues.Count - 1; $i++) {
        $gap = $sortedHues[$i+1] - $sortedHues[$i]
        if ($gap -gt $maxGap) { $maxGap = $gap }
    }
    $wrapGap = 360 - $sortedHues[-1] + $sortedHues[0]
    if ($wrapGap -gt $maxGap) { $maxGap = $wrapGap }
    $hueRange = 360 - $maxGap
}
$harmony = if ($hueRange -le 30) { "monochromatic" } elseif ($hueRange -le 60) { "analogous" } elseif ($hueRange -ge 150 -and $hueRange -le 210) { "complementary" } else { "neutral" }

# Format gradient info
$gradientInfo = if ($hasGradient) {
    [PSCustomObject]@{ type = $gradientType; colors = $gradientColors }
} else {
    $null
}

$surfaceColors = @()
foreach ($s in $surfaces | Select-Object -First 3) {
    $surfaceColors += $s.hex
}
if ($surfaceColors.Count -eq 0) { $surfaceColors += $bgColor }

$result = [PSCustomObject]@{
    imageWidth      = $w
    imageHeight     = $h
    isPhoto         = $isPhoto
    distinctColors  = $distinctColorCount
    totalColors     = $palette.Count
    samples         = $totalSamples
    background      = $bgColor
    surfaces        = $surfaceColors
    text            = $textPrimary
    textSecondary   = $textSecondary
    button          = $buttonColor
    border          = $borderColor
    contrastRatio   = $contrastRatio
    harmony         = $harmony
    gradient        = $gradientInfo
    palette         = $palette | Select-Object -First 20
}

if ($Json) {
    Write-Output ($result | ConvertTo-Json -Depth 5)
} else {
    Write-Output ""
    Write-Output "=== Color Analysis ==="
    Write-Output "Image: ${w}x${h}"
    Write-Output "Type:  $(if($isPhoto){'Photo'}else{'UI'}) ($distinctColorCount distinct colors)"
    Write-Output "Harmony: $harmony"
    Write-Output ""
    Write-Output "Background: $bgColor"
    Write-Output "Surface(s): $($surfaceColors -join ', ')"
    Write-Output "Text (primary):  $textPrimary  (contrast: ${contrastRatio}:1)"
    if ($textSecondary) { Write-Output "Text (secondary): $textSecondary" }
    if ($buttonColor) { Write-Output "Button/CTA: $buttonColor" }
    if ($borderColor) { Write-Output "Border: $borderColor" }
    if ($hasGradient) { Write-Output "Gradient: ${gradientType} ${gradientColors[0]} → ${gradientColors[-1]}" }
    Write-Output ""
    Write-Output "Palette (top $([Math]::Min(12, $palette.Count))):"
    foreach ($c in $palette | Select-Object -First 12) {
        Write-Output ("  {0,-8} {1,5}%" -f $c.hex, $c.pct)
    }
}
