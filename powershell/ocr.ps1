param(
    [Parameter(Mandatory = $true)]
    [string]$ImagePath,
    [string]$Language = "tha+eng",
    [int]$MinConfidence = 70,
    [switch]$BoundingBoxes,
    [switch]$Json
)

$tesseract = "C:\Program Files\Tesseract-OCR\tesseract.exe"
if (-not (Test-Path $tesseract)) {
    Write-Error "Tesseract not found. Install: winget install -e --id UB-Mannheim.TesseractOCR"
    exit 1
}

$resolved = Resolve-Path -LiteralPath $ImagePath -ErrorAction Stop
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$userTessdata = Join-Path $scriptDir "tessdata"

$env:TESSDATA_PREFIX = $userTessdata

# Auto-download missing language data
foreach ($lang in $Language -split '\+') {
    $langFile = Join-Path $userTessdata "$lang.traineddata"
    if (-not (Test-Path $langFile)) {
        Write-Progress -Activity "Downloading language data..." -Status $lang
        $url = "https://github.com/tesseract-ocr/tessdata/raw/main/$lang.traineddata"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $langFile -UseBasicParsing
    }
}

# Preprocess image for better OCR on complex backgrounds
Add-Type -AssemblyName System.Drawing
$origImg = [System.Drawing.Image]::FromFile($resolved.Path)
$w = $origImg.Width; $h = $origImg.Height
$bmp = New-Object System.Drawing.Bitmap($origImg)
$origImg.Dispose()

# Auto-detect if image is photograph (many colors + low variance) vs UI (few colors)
$colorSample = @{}
$lumVals = @()
for ($y = 0; $y -lt $h; $y += [Math]::Max(1, [Math]::Floor($h / 50))) {
    for ($x = 0; $x -lt $w; $x += [Math]::Max(1, [Math]::Floor($w / 50))) {
        $px = $bmp.GetPixel($x, $y)
        $hex = "#{0:X2}{1:X2}{2:X2}" -f ($px.R -band 0xF0), ($px.G -band 0xF0), ($px.B -band 0xF0)
        $colorSample[$hex] = 1
        $lumVals += [int](0.299*$px.R + 0.587*$px.G + 0.114*$px.B)
    }
}
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
$isPhoto = ($colorSample.Count -gt 50) -or ($colorSample.Count -ge 15 -and $iqr -lt 80) -or ($lumRange -gt 150 -and $edgeRatio -lt 0.3)

# For photos: create high-contrast BW version for OCR
$preprocessedPaths = @($resolved.Path)
if ($isPhoto) {
    # Version 1: high contrast (equalize histogram stretch)
    $procBmp1 = New-Object System.Drawing.Bitmap($w, $h)
    # Find min/max luminance first
    $minL = 255; $maxL = 0
    for ($y = 0; $y -lt $h; $y++) {
        for ($x = 0; $x -lt $w; $x++) {
            $px = $bmp.GetPixel($x, $y)
            $lum = [int](0.299*$px.R + 0.587*$px.G + 0.114*$px.B)
            if ($lum -lt $minL) { $minL = $lum }
            if ($lum -gt $maxL) { $maxL = $lum }
        }
    }
    $range = [Math]::Max(1, $maxL - $minL)
    for ($y = 0; $y -lt $h; $y++) {
        for ($x = 0; $x -lt $w; $x++) {
            $px = $bmp.GetPixel($x, $y)
            $lum = [int](0.299*$px.R + 0.587*$px.G + 0.114*$px.B)
            $newLum = [Math]::Min(255, [Math]::Max(0, [int](($lum - $minL) / $range * 255)))
            $c = $newLum
            $procBmp1.SetPixel($x, $y, [System.Drawing.Color]::FromArgb(255, $c, $c, $c))
        }
    }
    $pp1 = Join-Path ([System.IO.Path]::GetTempPath()) "img2code_$( [System.Guid]::NewGuid() )_pp1.png"
    $procBmp1.Save($pp1, [System.Drawing.Imaging.ImageFormat]::Png)
    $procBmp1.Dispose()
    $preprocessedPaths += $pp1

    # Version 2: adaptive threshold (text becomes black, bg becomes white)
    $procBmp2 = New-Object System.Drawing.Bitmap($w, $h)
    for ($y = 0; $y -lt $h; $y++) {
        for ($x = 0; $x -lt $w; $x++) {
            $px = $bmp.GetPixel($x, $y)
            $lum = [int](0.299*$px.R + 0.587*$px.G + 0.114*$px.B)
            $newLum = if ($lum -lt 100) { 0 } elseif ($lum -gt 160) { 255 } else { [Math]::Min(255, [Math]::Max(0, ($lum - 80) * 3)) }
            $c = [Math]::Min(255, [Math]::Max(0, $newLum))
            $procBmp2.SetPixel($x, $y, [System.Drawing.Color]::FromArgb(255, $c, $c, $c))
        }
    }
    $pp2 = Join-Path ([System.IO.Path]::GetTempPath()) "img2code_$( [System.Guid]::NewGuid() )_pp2.png"
    $procBmp2.Save($pp2, [System.Drawing.Imaging.ImageFormat]::Png)
    $procBmp2.Dispose()
    $preprocessedPaths += $pp2
}
$bmp.Dispose()

$allResults = @()
$allText = ""

# Try multiple PSM modes on all preprocessed versions
$psmModes = if ($isPhoto) { @(3, 6, 4, 11) } else { @(3, 11, 6, 4) }

foreach ($ppPath in $preprocessedPaths) {
    foreach ($psm in $psmModes) {
        if ($BoundingBoxes -or $Json) {
            $tmpOut = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            & $tesseract $ppPath $tmpOut -l $Language --psm $psm tsv 2>&1 | Out-Null
            $tsv = Get-Content "${tmpOut}.tsv" -Raw -ErrorAction SilentlyContinue
            Remove-Item "${tmpOut}.tsv" -Force -ErrorAction SilentlyContinue

            if ($tsv) {
                $lines = $tsv -split "`n" | Where-Object { $_.Trim() -ne "" }
                if ($lines.Count -gt 1) {
                    $header = $lines[0] -split "`t"
                    for ($i = 1; $i -lt $lines.Count; $i++) {
                        $cols = $lines[$i] -split "`t"
                        if ($cols.Count -lt 12) { continue }
                        $text = $cols[$header.IndexOf("text")]
                        $conf = 0.0; [double]::TryParse($cols[$header.IndexOf("conf")], [ref]$conf) | Out-Null
                        if ([string]::IsNullOrWhiteSpace($text) -or $conf -lt $MinConfidence) { continue }
                        $ww = 0; [int]::TryParse($cols[$header.IndexOf("width")], [ref]$ww) | Out-Null
                        $wh = 0; [int]::TryParse($cols[$header.IndexOf("height")], [ref]$wh) | Out-Null
                        if ($ww -lt 8 -and $wh -lt 8) { continue }

                        $x = 0; [int]::TryParse($cols[$header.IndexOf("left")], [ref]$x) | Out-Null
                        $y = 0; [int]::TryParse($cols[$header.IndexOf("top")], [ref]$y) | Out-Null
                        $word = $text.Trim()

                        # Deduplicate: same text within 40px zone
                        $dup = $allResults | Where-Object {
                            $_.text -eq $word -and [Math]::Abs($_.x - $x) -lt 40 -and [Math]::Abs($_.y - $y) -lt 40
                        }
                        # Also: skip if existing result already has this word as a substring (min 3 chars to avoid false matches)
                        $subdup = if ($word.Length -ge 3) {
                            $allResults | Where-Object {
                                $_.text.IndexOf($word, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and [Math]::Abs($_.y - $y) -lt 30
                            }
                        } else { $null }
                        # Or if new word is a longer version of an existing word (e.g. "Studio" vs "Studi")
                        $extend = $allResults | Where-Object {
                            $word.IndexOf($_.text, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and [Math]::Abs($_.y - $y) -lt 30 -and $word.Length -gt $_.text.Length
                        }
                        if ($extend) {
                            # Upgrade ALL matching entries to longer/better version
                            foreach ($existing in $extend) { $existing.text = $word }
                        }
                        if (-not $dup -and -not $subdup -and -not $extend) {
                            $allResults += [PSCustomObject]@{
                                text = $word
                                conf = [Math]::Round($conf, 1)
                                x    = $x
                                y    = $y
                                w    = $ww
                                h    = $wh
                                zone = if ($y -lt $h/3) { "top" } elseif ($y -lt $h*2/3) { "middle" } else { "bottom" }
                                src  = if ($ppPath -eq $resolved.Path) { "orig" } else { "pp" }
                                psm  = $psm
                            }
                        }
                    }
                }
            }
        } else {
            $tmpOut = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            & $tesseract $ppPath $tmpOut -l $Language --psm $psm 2>&1 | Out-Null
            $text = Get-Content "${tmpOut}.txt" -Raw -ErrorAction SilentlyContinue
            Remove-Item "${tmpOut}.txt" -Force -ErrorAction SilentlyContinue
            if ($text -and $text.Trim()) {
                $allText += $text.Trim() + "`n"
            }
        }
    }
}

# Footer scan: scan bottom area for tiny footer text and low-contrast branding
$footerBmp = New-Object System.Drawing.Bitmap($resolved.Path)
if ($footerBmp.Height -gt 40) {
    $fh = $footerBmp.Height

    # Pass 1: crop bottom 40px for copyright text, PSM 11 + 6
    $footerCropH = 40
    $footerCrop = $footerBmp.Clone([System.Drawing.Rectangle]::new(0, $fh - $footerCropH, $footerBmp.Width, $footerCropH), [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $footerCropPath = Join-Path ([System.IO.Path]::GetTempPath()) "img2code_$( [System.Guid]::NewGuid() )_copyright.png"
    $footerCrop.Save($footerCropPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $footerCrop.Dispose()

    # Also try histogram-stretched version
    $footerCrop2 = $footerBmp.Clone([System.Drawing.Rectangle]::new(0, $fh - $footerCropH, $footerBmp.Width, $footerCropH), [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $minL = 255; $maxL = 0
    for ($y = 0; $y -lt $footerCrop2.Height; $y++) {
        for ($x = 0; $x -lt $footerCrop2.Width; $x++) {
            $px = $footerCrop2.GetPixel($x, $y)
            $lum = [int](0.299*$px.R + 0.587*$px.G + 0.114*$px.B)
            if ($lum -lt $minL) { $minL = $lum }
            if ($lum -gt $maxL) { $maxL = $lum }
        }
    }
    $range = [Math]::Max(1, $maxL - $minL)
    for ($y = 0; $y -lt $footerCrop2.Height; $y++) {
        for ($x = 0; $x -lt $footerCrop2.Width; $x++) {
            $px = $footerCrop2.GetPixel($x, $y)
            $lum = [int](0.299*$px.R + 0.587*$px.G + 0.114*$px.B)
            $newLum = [Math]::Min(255, [Math]::Max(0, [int](($lum - $minL) / $range * 255)))
            $footerCrop2.SetPixel($x, $y, [System.Drawing.Color]::FromArgb(255, $newLum, $newLum, $newLum))
        }
    }
    $footerStretchPath = Join-Path ([System.IO.Path]::GetTempPath()) "img2code_$( [System.Guid]::NewGuid() )_copyright_s.png"
    $footerCrop2.Save($footerStretchPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $footerCrop2.Dispose()

    foreach ($footerPath in @($footerCropPath, $footerStretchPath)) {
        foreach ($psmFooter in @(11, 6)) {
            $tmpOut = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            & $tesseract $footerPath $tmpOut -l $Language --psm $psmFooter tsv 2>&1 | Out-Null
            $tsv = Get-Content "${tmpOut}.tsv" -Raw -ErrorAction SilentlyContinue
            Remove-Item "${tmpOut}.tsv" -Force -ErrorAction SilentlyContinue
            if ($tsv) {
                $lines = $tsv -split "`n" | Where-Object { $_.Trim() -ne "" }
                if ($lines.Count -gt 1) {
                    $header = $lines[0] -split "`t"
                    for ($i = 1; $i -lt $lines.Count; $i++) {
                        $cols = $lines[$i] -split "`t"
                        if ($cols.Count -lt 12) { continue }
                        $text = $cols[$header.IndexOf("text")]
                        $conf = 0.0; [double]::TryParse($cols[$header.IndexOf("conf")], [ref]$conf) | Out-Null
                        if ([string]::IsNullOrWhiteSpace($text) -or $conf -lt $MinConfidence) { continue }
                        $fw = 0; [int]::TryParse($cols[$header.IndexOf("width")], [ref]$fw) | Out-Null
                        $fh2 = 0; [int]::TryParse($cols[$header.IndexOf("height")], [ref]$fh2) | Out-Null
                        if ($fw -lt 8 -and $fh2 -lt 8) { continue }
                        if ($fh2 -gt 50) { continue }
                        $fx = 0; [int]::TryParse($cols[$header.IndexOf("left")], [ref]$fx) | Out-Null
                        if ($fx -gt $w * 0.92) { continue }
                        $fy = 0; [int]::TryParse($cols[$header.IndexOf("top")], [ref]$fy) | Out-Null; $fy += ($fh - $footerCropH)
                        $fword = $text.Trim()
                        $dup = $allResults | Where-Object {
                            $_.text -eq $fword -and [Math]::Abs($_.x - $fx) -lt 30 -and [Math]::Abs($_.y - $fy) -lt 30
                        }
                        $subdup = if ($fword.Length -ge 3) {
                            $allResults | Where-Object {
                                $_.text.IndexOf($fword, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and [Math]::Abs($_.y - $fy) -lt 30
                            }
                        } else { $null }
                        if (-not $dup -and -not $subdup) {
                            $allResults += [PSCustomObject]@{
                                text = $fword; conf = [Math]::Round($conf, 1); x = $fx; y = $fy
                                w = $fw; h = $fh2; zone = "bottom"; src = "footer"; psm = $psmFooter
                            }
                        }
                    }
                }
            }
        }
    }
    Remove-Item $footerCropPath -Force -ErrorAction SilentlyContinue
    Remove-Item $footerStretchPath -Force -ErrorAction SilentlyContinue

    # Pass 2: crop bottom 70px for low-contrast branding text (e.g. "MADE BY Zexta Studio")
    $mbCropH = 70
    $mbCrop = $footerBmp.Clone([System.Drawing.Rectangle]::new(0, $fh - $mbCropH, $footerBmp.Width, $mbCropH), [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $mbPath = Join-Path ([System.IO.Path]::GetTempPath()) "img2code_$( [System.Guid]::NewGuid() )_mb.png"
    $mbCrop.Save($mbPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $mbCrop.Dispose()
    foreach ($psmMB in @(8, 7, 13)) {
        $tmpOut = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        & $tesseract $mbPath $tmpOut -l $Language --psm $psmMB tsv 2>&1 | Out-Null
        $tsv = Get-Content "${tmpOut}.tsv" -Raw -ErrorAction SilentlyContinue
        Remove-Item "${tmpOut}.tsv" -Force -ErrorAction SilentlyContinue
        if ($tsv) {
            $lines = $tsv -split "`n" | Where-Object { $_.Trim() -ne "" }
            if ($lines.Count -gt 1) {
                $header = $lines[0] -split "`t"
                for ($i = 1; $i -lt $lines.Count; $i++) {
                    $cols = $lines[$i] -split "`t"
                    if ($cols.Count -lt 12) { continue }
                        $text = $cols[$header.IndexOf("text")]
                        $conf = 0.0; [double]::TryParse($cols[$header.IndexOf("conf")], [ref]$conf) | Out-Null
                        if ([string]::IsNullOrWhiteSpace($text) -or $conf -lt $MinConfidence) { continue }
                        $fw = 0; [int]::TryParse($cols[$header.IndexOf("width")], [ref]$fw) | Out-Null
                        $fh2 = 0; [int]::TryParse($cols[$header.IndexOf("height")], [ref]$fh2) | Out-Null
                        if ($fw -lt 8 -and $fh2 -lt 8) { continue }
                        if ($fh2 -gt 50) { continue }
                        $fx = 0; [int]::TryParse($cols[$header.IndexOf("left")], [ref]$fx) | Out-Null
                        if ($fx -gt $w * 0.92) { continue }
                    $fy = 0; [int]::TryParse($cols[$header.IndexOf("top")], [ref]$fy) | Out-Null; $fy += ($fh - $mbCropH)
                    $fword = $text.Trim()
                    $dup = $allResults | Where-Object {
                        $_.text -eq $fword -and [Math]::Abs($_.x - $fx) -lt 30 -and [Math]::Abs($_.y - $fy) -lt 30
                    }
                    $subdup = if ($fword.Length -ge 3) {
                        $allResults | Where-Object {
                            $_.text.IndexOf($fword, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and [Math]::Abs($_.y - $fy) -lt 30
                        }
                    } else { $null }
                    if (-not $dup -and -not $subdup) {
                        $allResults += [PSCustomObject]@{
                            text = $fword; conf = [Math]::Round($conf, 1); x = $fx; y = $fy
                            w = $fw; h = $fh2; zone = "bottom"; src = "footer"; psm = $psmMB
                        }
                    }
                }
            }
        }
    }
    Remove-Item $mbPath -Force -ErrorAction SilentlyContinue
    $footerBmp.Dispose()
} else { $footerBmp.Dispose() }

# If photo-classified OR word count is suspiciously low, retry with preprocessing
if ($allResults.Count -lt 5) {
    # Reload bitmap for retry preprocessing
    $retryBmp = New-Object System.Drawing.Bitmap($resolved.Path)
    $procBmp1 = New-Object System.Drawing.Bitmap($w, $h)
    $minL = 255; $maxL = 0
    for ($y = 0; $y -lt $h; $y++) {
        for ($x = 0; $x -lt $w; $x++) {
            $px = $retryBmp.GetPixel($x, $y)
            $lum = [int](0.299*$px.R + 0.587*$px.G + 0.114*$px.B)
            if ($lum -lt $minL) { $minL = $lum }
            if ($lum -gt $maxL) { $maxL = $lum }
        }
    }
    $range = [Math]::Max(1, $maxL - $minL)
    for ($y = 0; $y -lt $h; $y++) {
        for ($x = 0; $x -lt $w; $x++) {
            $px = $retryBmp.GetPixel($x, $y)
            $lum = [int](0.299*$px.R + 0.587*$px.G + 0.114*$px.B)
            $newLum = [Math]::Min(255, [Math]::Max(0, [int](($lum - $minL) / $range * 255)))
            $procBmp1.SetPixel($x, $y, [System.Drawing.Color]::FromArgb(255, $newLum, $newLum, $newLum))
        }
    }
    $ppRetry = Join-Path ([System.IO.Path]::GetTempPath()) "img2code_$( [System.Guid]::NewGuid() )_retry.png"
    $procBmp1.Save($ppRetry, [System.Drawing.Imaging.ImageFormat]::Png)
    $procBmp1.Dispose()
    $retryBmp.Dispose()

    # Run OCR on preprocessed version with photo PSM modes
    $retryPsms = @(3, 6, 11)
    foreach ($psm in $retryPsms) {
        $tmpOut = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        & $tesseract $ppRetry $tmpOut -l $Language --psm $psm tsv 2>&1 | Out-Null
        $tsv = Get-Content "${tmpOut}.tsv" -Raw -ErrorAction SilentlyContinue
        Remove-Item "${tmpOut}.tsv" -Force -ErrorAction SilentlyContinue
        if ($tsv) {
            $lines = $tsv -split "`n" | Where-Object { $_.Trim() -ne "" }
            if ($lines.Count -gt 1) {
                $header = $lines[0] -split "`t"
                for ($i = 1; $i -lt $lines.Count; $i++) {
                    $cols = $lines[$i] -split "`t"
                    if ($cols.Count -lt 12) { continue }
                    $text = $cols[$header.IndexOf("text")]
                    $conf = 0.0; [double]::TryParse($cols[$header.IndexOf("conf")], [ref]$conf) | Out-Null
                    if ([string]::IsNullOrWhiteSpace($text) -or $conf -lt $MinConfidence) { continue }
                    $x = 0; [int]::TryParse($cols[$header.IndexOf("left")], [ref]$x) | Out-Null
                    $y = 0; [int]::TryParse($cols[$header.IndexOf("top")], [ref]$y) | Out-Null
                    $rww = 0; [int]::TryParse($cols[$header.IndexOf("width")], [ref]$rww) | Out-Null
                    $rwh = 0; [int]::TryParse($cols[$header.IndexOf("height")], [ref]$rwh) | Out-Null
                    $word = $text.Trim()
                    $dup = $allResults | Where-Object {
                        $_.text -eq $word -and [Math]::Abs($_.x - $x) -lt 40 -and [Math]::Abs($_.y - $y) -lt 40
                    }
                    if (-not $dup) {
                        $allResults += [PSCustomObject]@{
                            text = $word; conf = [Math]::Round($conf, 1); x = $x; y = $y
                            w = $rww; h = $rwh
                            zone = if ($y -lt $h/3) { "top" } elseif ($y -lt $h*2/3) { "middle" } else { "bottom" }
                            src = "retry"; psm = $psm
                        }
                    }
                }
            }
        }
    }
    Remove-Item $ppRetry -Force -ErrorAction SilentlyContinue
}

# Clean up preprocessed files
foreach ($p in $preprocessedPaths) {
    if ($p -ne $resolved.Path -and (Test-Path $p)) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
}

# Run additional plain-text pass for merged Thai text (not available in TSV mode)
$rawText = ""
if ($Json -or $BoundingBoxes) {
    # Try original + preprocessed, pick longest result
    $rawCandidates = @{}
    # Pass 1: original image
    $r1 = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
    & $tesseract $resolved.Path $r1 -l $Language --psm 6 2>&1 | Out-Null
    $t1 = Get-Content "${r1}.txt" -Raw -ErrorAction SilentlyContinue
    Remove-Item "${r1}.txt" -Force -ErrorAction SilentlyContinue
    if ($t1) { $rawCandidates["orig"] = $t1.Trim() }
    # Pass 2: histogram-stretched (if photo or has Thai)
    if ($isPhoto -or $Language -match "tha") {
        $ppRawPath = Join-Path ([System.IO.Path]::GetTempPath()) "img2code_$( [System.Guid]::NewGuid() )_raw.png"
        $rawBmp = New-Object System.Drawing.Bitmap($resolved.Path)
        $minL = 255; $maxL = 0
        for ($y = 0; $y -lt $h; $y++) { for ($x = 0; $x -lt $w; $x++) {
            $px = $rawBmp.GetPixel($x, $y)
            $lum = [int](0.299*$px.R + 0.587*$px.G + 0.114*$px.B)
            if ($lum -lt $minL) { $minL = $lum }
            if ($lum -gt $maxL) { $maxL = $lum }
        }}
        $range = [Math]::Max(1, $maxL - $minL)
        $procRaw = New-Object System.Drawing.Bitmap($w, $h)
        for ($y = 0; $y -lt $h; $y++) { for ($x = 0; $x -lt $w; $x++) {
            $px = $rawBmp.GetPixel($x, $y)
            $lum = [int](0.299*$px.R + 0.587*$px.G + 0.114*$px.B)
            $newLum = [Math]::Min(255, [Math]::Max(0, [int](($lum - $minL) / $range * 255)))
            $procRaw.SetPixel($x, $y, [System.Drawing.Color]::FromArgb(255, $newLum, $newLum, $newLum))
        }}
        $procRaw.Save($ppRawPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $procRaw.Dispose(); $rawBmp.Dispose()
        $r2 = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        & $tesseract $ppRawPath $r2 -l $Language --psm 6 2>&1 | Out-Null
        $t2 = Get-Content "${r2}.txt" -Raw -ErrorAction SilentlyContinue
        Remove-Item "${r2}.txt" -Force -ErrorAction SilentlyContinue
        Remove-Item $ppRawPath -Force -ErrorAction SilentlyContinue
        if ($t2) { $rawCandidates["pp"] = $t2.Trim() }
    }
    # Pick the longest result (usually has most complete text)
    if ($rawCandidates.Count -gt 0) {
        $best = $null; $bestLen = 0
        foreach ($kv in $rawCandidates.GetEnumerator()) {
            if ($kv.Value.Length -gt $bestLen) { $bestLen = $kv.Value.Length; $best = $kv.Value }
        }
        $rawText = $best
    }
} else {
    $rawText = $allText.Trim()
}

# Merge Thai grapheme clusters split by Tesseract (spaces between Thai chars)
function Merge-ThaiText {
    param([string]$text)
    if ([string]::IsNullOrWhiteSpace($text)) { return $text }
    return [regex]::Replace($text, "(?<=[\u0E00-\u0E7F])\s+(?=[\u0E00-\u0E7F])", '')
}

$rawTextOutput = if ($rawText) { Merge-ThaiText $rawText } else { "" }

# Sort: by zone top→bottom, then by y-position
$allResults = $allResults | Sort-Object @{E={if ($_.zone -eq "top") {1} elseif ($_.zone -eq "middle") {2} else {3}}}, y, x

# Clean up preprocessed file (legacy cleanup removed — done in loop above)

if ($BoundingBoxes -or $Json) {
    if ($Json) {
        $byZoneText = [PSCustomObject]@{
            top    = Merge-ThaiText (($allResults | Where-Object { $_.zone -eq "top" }).text -join ' ')
            middle = Merge-ThaiText (($allResults | Where-Object { $_.zone -eq "middle" }).text -join ' ')
            bottom = Merge-ThaiText (($allResults | Where-Object { $_.zone -eq "bottom" }).text -join ' ')
        }
        $ocrOutput = [PSCustomObject]@{
            words   = $allResults.Count
            boxes   = $allResults
            rawText = $rawTextOutput
            byZone  = $byZoneText
        }
        Write-Output ($ocrOutput | ConvertTo-Json -Depth 5)
    } else {
        Write-Output ""
        Write-Output "=== OCR (min conf:${MinConfidence}, photo:$isPhoto) ==="
        Write-Output "zone  conf  text"
        Write-Output "----  ----  ----"
        foreach ($r in $allResults) {
            Write-Output ("{0,-6} {1,3}%  {2}" -f $r.zone, $r.conf, $r.text)
        }
        if ($allResults.Count -eq 0) { Write-Output "(no text >= $MinConfidence%)" }
        if ($rawTextOutput) {
            Write-Output ""
            Write-Output "--- Full text ---"
            Write-Output $rawTextOutput
        }
    }
} else {
    Write-Output ""
    Write-Output "=== OCR Result ==="
    Write-Output ""
    if ($allText.Trim()) {
        Write-Output $allText.Trim()
    } else {
        Write-Output "(no text detected)"
    }
}
