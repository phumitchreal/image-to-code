param(
    [Parameter(Mandatory = $true)]
    [string]$ImagePath,
    [switch]$Json
)

Add-Type -AssemblyName System.Drawing

$resolved = Resolve-Path -LiteralPath $ImagePath -ErrorAction Stop
$bmp = [System.Drawing.Bitmap]::FromFile($resolved.Path)
$w = $bmp.Width; $h = $bmp.Height

# Classify: photo vs UI
$coarseColors = @{}
$lumVals = @()
for ($y = 0; $y -lt $h; $y += [Math]::Max(1, [Math]::Floor($h / 30))) {
    for ($x = 0; $x -lt $w; $x += [Math]::Max(1, [Math]::Floor($w / 30))) {
        $px = $bmp.GetPixel($x, $y)
        $hex = "#{0:X2}{1:X2}{2:X2}" -f ($px.R -band 0xF0), ($px.G -band 0xF0), ($px.B -band 0xF0)
        $coarseColors[$hex] = 1
        $lumVals += [int](0.299*$px.R + 0.587*$px.G + 0.114*$px.B)
    }
}
# Photo heuristic: many distinct colors (>50) OR low luminance variance (smooth photo gradients)
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
$isPhoto = ($coarseColors.Count -gt 50) -or ($coarseColors.Count -ge 15 -and $iqr -lt 80) -or ($lumRange -gt 150 -and $edgeRatio -lt 0.3)

function Get-DominantColor($bitmap, $x1, $y1, $x2, $y2, $step) {
    $counts = @{}
    for ($y = $y1; $y -lt $y2; $y += $step) {
        for ($x = $x1; $x -lt $x2; $x += $step) {
            $px = $bitmap.GetPixel($x, $y)
            $rq = [Math]::Round($px.R / 20) * 20
            $gq = [Math]::Round($px.G / 20) * 20
            $bq = [Math]::Round($px.B / 20) * 20
            $rq = [Math]::Min(255, [Math]::Max(0, $rq))
            $gq = [Math]::Min(255, [Math]::Max(0, $gq))
            $bq = [Math]::Min(255, [Math]::Max(0, $bq))
            $hex = "#{0:X2}{1:X2}{2:X2}" -f $rq, $gq, $bq
            $counts[$hex] += 1
        }
    }
    $sorted = $counts.GetEnumerator() | Sort-Object Value -Descending
    return $sorted[0].Key
}

# For photos: detect horizontal bands at coarser resolution
$scanResolution = if ($isPhoto) { [Math]::Max(8, [Math]::Floor($h / 60)) } else { 4 }

# Horizontal sections
$sections = @()
$prevColor = ""
$sectionStart = 0

for ($y = 0; $y -lt $h; $y += $scanResolution) {
    $endY = [Math]::Min($h, $y + $scanResolution)
    $rowColor = Get-DominantColor $bmp 0 $y $w $endY 8
    if ($rowColor -ne $prevColor -and $prevColor -ne "") {
        $sections += [PSCustomObject]@{
            y     = $sectionStart
            h     = $y - $sectionStart
            color = $prevColor
        }
        $sectionStart = $y
    }
    $prevColor = $rowColor
}
if ($h - $sectionStart -gt 2) {
    $sections += [PSCustomObject]@{
        y     = $sectionStart
        h     = $h - $sectionStart
        color = $prevColor
    }
}

# Vertical columns (only for UI, photos are always single-column)
$columns = @()
if (-not $isPhoto) {
    $minColWidthPx = [Math]::Floor($w * 0.08)
    $xStep = [Math]::Max(1, [Math]::Floor($w / 80))
    $prevColColor = ""
    $colStart = 0
    for ($x = 0; $x -lt $w; $x += $xStep) {
        $endX = [Math]::Min($w, $x + $xStep)
        $colColor = Get-DominantColor $bmp $x 0 $endX $h 10
        if ($colColor -ne $prevColColor -and $prevColColor -ne "") {
            $colWidth = $x - $colStart
            if ($colWidth -ge $minColWidthPx) {
                $columns += [PSCustomObject]@{
                    x     = $colStart
                    w     = $colWidth
                    color = $prevColColor
                }
            }
            $colStart = $x
        }
        $prevColColor = $colColor
    }
    if ($w - $colStart -gt $minColWidthPx) {
        $columns += [PSCustomObject]@{
            x     = $colStart
            w     = $w - $colStart
            color = $prevColColor
        }
    }
}

# Merge small sections
$mergedSections = @()
$minHeight = if ($isPhoto) { [Math]::Max(20, [Math]::Floor($h * 0.03)) } else { [Math]::Max(8, [Math]::Floor($h * 0.02)) }
$buffer = $null
foreach ($s in $sections) {
    if ($s.h -lt $minHeight) {
        if ($buffer -ne $null) { $buffer.h += $s.h }
        else { $buffer = $s }
    } else {
        if ($buffer -ne $null) {
            $s.y = $buffer.y; $s.h += $buffer.h; $buffer = $null
        }
        $mergedSections += $s
    }
}
if ($buffer -ne $null) { $mergedSections += $buffer }

# Component identification — neutral labels, no UI-specific guessing
$components = @()
foreach ($s in $mergedSections) {
    $relY = [Math]::Round($s.y / $h * 100)
    $relH = [Math]::Round($s.h / $h * 100)

    if ($relY -lt 3) { $label = if ($relH -gt 30) { "hero-padding" } else { "top-segment" } }
    elseif ($relY + $relH -gt 97) { $label = "bottom-segment" }
    elseif ($relH -gt 50) { $label = "large-segment" }
    elseif ($relH -lt 5) { $label = "thin-band" }
    else { $label = "mid-segment" }

    $components += [PSCustomObject]@{
        type  = $label
        y_pct = $relY
        h_pct = $relH
        y_px  = $s.y
        h_px  = $s.h
        color = $s.color
    }
}

$bmp.Dispose()

$result = [PSCustomObject]@{
    imageWidth  = $w
    imageHeight = $h
    isPhoto     = $isPhoto
    layoutType  = if ($w -le 430) { "mobile" } elseif ($w -gt $h) { "landscape/desktop" } else { "tablet/mobile" }
    sections    = $mergedSections
    columns     = $columns
    components  = $components
}

if ($Json) {
    Write-Output ($result | ConvertTo-Json -Depth 5)
} else {
    Write-Output ""
    Write-Output "=== Layout Analysis ==="
    Write-Output "Image: ${w}x${h} ($($result.layoutType), $(if($isPhoto){'photo'}else{'UI'}))"
    Write-Output ""
    Write-Output "Sections ($($mergedSections.Count)):"
    foreach ($s in $mergedSections) {
        Write-Output ("  y={0,4} h={1,4} {2}" -f $s.y, $s.h, $s.color)
    }
    Write-Output ""
    Write-Output "Components:"
    foreach ($c in $components) {
        Write-Output ("  {0,-16} y={1,2}% h={2,2}%" -f $c.type, $c.y_pct, $c.h_pct)
    }
}
