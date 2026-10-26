# =============================================================================
#  verify_sd.ps1 -- read-only verification of the SD card against sd_image.img
#
#  Two independent checks:
#    1. SHA256 of the whole image range (definitive, covers every byte)
#    2. Per-image BMP header dump at each slot (shows what is really on the card)
#
#  Nothing is written. Must run as Administrator (called by verify_sd.bat).
# =============================================================================
$ErrorActionPreference = 'Stop'
$LogPath = 'D:\Work\fpga\yuanshen\sd_verify_log.txt'
$ImgPath = 'D:\Work\fpga\yuanshen\sd_image.img'
$DiskNum = 2
$SEC     = 512
$SECBASE = 2048

function Log($m) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    Write-Host $line
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
}

function Read-Exact($fs, [byte[]]$buf, [int]$count) {
    $got = 0
    while ($got -lt $count) {
        $n = $fs.Read($buf, $got, $count - $got)
        if ($n -le 0) { throw "read returned 0 at $got" }
        $got += $n
    }
}

# ---- find image slots inside the .img (so nothing is hard-coded) ------------
function Get-Slots([byte[]]$d) {
    $slots = @()
    $start = $SECBASE * $SEC
    $pos = $start
    # [Array]::IndexOf scans natively; a byte-by-byte PS loop over 23MB takes minutes
    while ($pos -lt $d.Length - 54) {
        $p = [Array]::IndexOf($d, [byte]0x42, $pos)
        if ($p -lt 0 -or $p -ge $d.Length - 54) { break }
        $pos = $p + 1
        if ($d[$p+1] -ne 0x4D) { continue }                       # 'BM'
        $off = [BitConverter]::ToUInt32($d, $p + 10)
        $bpp = [BitConverter]::ToUInt16($d, $p + 28)
        $w   = [BitConverter]::ToInt32($d, $p + 18)
        $h   = [BitConverter]::ToInt32($d, $p + 22)
        $bf  = [BitConverter]::ToUInt32($d, $p + 2)
        if ($off -eq 54 -and $bpp -eq 24 -and $w -gt 0 -and $w -le 4096 -and
            [Math]::Abs($h) -ge 1 -and [Math]::Abs($h) -le 4096 -and
            $bf -gt 54 -and ($p + $bf) -le $d.Length) {
            $slots += [pscustomobject]@{ Pos = $p; W = $w; H = [Math]::Abs($h); Bf = $bf }
        }
    }
    return $slots
}

"=== verify_sd start ===" | Set-Content -Path $LogPath -Encoding UTF8

try {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw "Not running as Administrator" }

    $d = Get-Disk -Number $DiskNum
    if ($d.BusType -ne 'USB') { throw "Disk $DiskNum is not USB, abort" }
    Log ("target: #{0} {1}  {2:N2} GB" -f $d.Number, $d.FriendlyName, ($d.Size/1GB))

    $img = [IO.File]::ReadAllBytes($ImgPath)
    Log ("image : {0} bytes ({1:N2} MB)" -f $img.Length, ($img.Length/1MB))

    # ---------- 1. full read back + SHA256 ----------
    $buf = New-Object byte[] $img.Length
    $fs = [IO.File]::Open("\\.\PhysicalDrive$DiskNum", 'Open', 'Read')
    try {
        $fs.Seek(0, 'Begin') | Out-Null
        Read-Exact $fs $buf $img.Length
    } finally {
        $fs.Close()
    }
    Log "read back: OK"

    $sha = [Security.Cryptography.SHA256]::Create()
    $hImg  = [BitConverter]::ToString($sha.ComputeHash($img)).Replace('-', '')
    $hCard = [BitConverter]::ToString($sha.ComputeHash($buf)).Replace('-', '')
    Log ("sha256 img : {0}" -f $hImg)
    Log ("sha256 card: {0}" -f $hCard)

    $hashOk = ($hImg -eq $hCard)
    if ($hashOk) {
        Log "byte compare: 0 mismatch (0 / $($img.Length))"
    } else {
        $bad = 0; $first = -1
        for ($k = 0; $k -lt $img.Length; $k++) {
            if ($buf[$k] -ne $img[$k]) { $bad++; if ($first -lt 0) { $first = $k } }
        }
        Log ("byte compare: {0} mismatch, first at 0x{1:X} (sector {2})" -f $bad, $first, [Math]::Floor($first/$SEC))
    }

    # ---------- 2. per-image slot check on the card ----------
    $slots = Get-Slots $img
    $stride = 0
    if ($slots.Count -ge 2) { $stride = $slots[1].Pos - $slots[0].Pos }
    Log ("slots in image: {0}   stride: {1} bytes ({2} sectors)" -f $slots.Count, $stride, ($stride / $SEC))

    $slotBad = 0
    for ($i = 0; $i -lt $slots.Count; $i++) {
        $s = $slots[$i]
        $tag = [Text.Encoding]::ASCII.GetString($buf, $s.Pos, 2)
        $ok  = ($tag -eq 'BM')
        # header must be identical to the image
        $diff = 0
        for ($k = 0; $k -lt 54; $k++) { if ($buf[$s.Pos + $k] -ne $img[$s.Pos + $k]) { $diff++ } }
        if (-not $ok -or $diff -ne 0) { $slotBad++ }
        Log ("  [{0}] @sector {1,-6} {2}  {3}x{4}  bfSize={5}  hdrDiff={6}" -f `
              $i, ($s.Pos / $SEC), $tag, $s.W, $s.H, $s.Bf, $diff)
    }

    # ---------- 3. music slots (RIFF/WAVE), sector aligned ----------
    #  RTL 里 MUS_BASE=18272 / MUS_STRIDE=49328（3 图之后），
    #  wav_player 会校验曲目首扇区的头两个字是否为 "RI"/"FF"。
    #  卡上这里若是图片像素，就会静音并把数码管最高位点亮成 F。
    $mus = @()
    $pos = 0
    while ($true) {
        $p = [Array]::IndexOf($img, [byte]0x52, $pos)      # 'R'，native 扫描
        if ($p -lt 0 -or $p -ge ($img.Length - 44)) { break }
        $pos = $p + 1
        if (($p % $SEC) -ne 0) { continue }                # 必须在扇区边界
        if ($img[$p+1] -ne 0x49 -or $img[$p+2] -ne 0x46 -or $img[$p+3] -ne 0x46) { continue }
        if ([Text.Encoding]::ASCII.GetString($img, $p + 8, 4) -ne 'WAVE') { continue }
        $dsz = [BitConverter]::ToUInt32($img, $p + 40)
        $mus += [pscustomobject]@{ Pos = $p; Bytes = $dsz }
    }
    Log ("music slots in image: {0}" -f $mus.Count)
    $musBad = 0
    for ($i = 0; $i -lt $mus.Count; $i++) {
        $m = $mus[$i]
        $tag = [Text.Encoding]::ASCII.GetString($buf, $m.Pos, 4)
        $ok  = ($tag -eq 'RIFF')
        if (-not $ok) { $musBad++ }
        Log ("  [M{0}] @sector {1,-6} card='{2}'  {3:N1} s  {4}" -f `
              ($i + 1), ($m.Pos / $SEC), $tag, ($m.Bytes / 2.0 / 48000),
              $(if ($ok) { 'OK' } else { 'BAD - RTL 会静音并显示 F' }))
    }
    if ($mus.Count -eq 0) {
        Log "  (image has no RIFF slot -- run tools/make_sd_image.py first)"
    }

    # ---------- verdict ----------
    if ($hashOk -and $slotBad -eq 0 -and $musBad -eq 0) {
        Log "RESULT: OK - card identical to image; $($slots.Count) images + $($mus.Count) music slots valid"
    } elseif ($slotBad -ne 0) {
        Log "RESULT: FAIL - $slotBad slot(s) bad on card"
    } else {
        Log "RESULT: MISMATCH - card differs from image"
    }
}
catch {
    Log ("RESULT: FAIL - {0}" -f $_.Exception.Message)
}
