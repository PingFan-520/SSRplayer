# =============================================================================
#  verify_sd.ps1 -- read-only full verification of the SD card against the image
#
#  Reads the whole image range from PhysicalDrive2 and compares SHA256 with
#  sd_image.img. Nothing is written. Must run as Administrator.
#  If hashes differ, it falls back to a byte scan to report the first bad offset.
# =============================================================================
$ErrorActionPreference = 'Stop'
$LogPath = 'D:\Work\fpga\yuanshen\sd_verify_log.txt'
$ImgPath = 'D:\Work\fpga\yuanshen\sd_image.img'
$DiskNum = 2

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

"=== verify_sd start ===" | Set-Content -Path $LogPath -Encoding UTF8

try {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw "Not running as Administrator" }

    $d = Get-Disk -Number $DiskNum
    if ($d.BusType -ne 'USB') { throw "Disk $DiskNum is not USB, abort" }
    Log ("target: #{0} {1}  {2:N2} GB" -f $d.Number, $d.FriendlyName, ($d.Size/1GB))

    $img = [IO.File]::ReadAllBytes($ImgPath)
    Log ("image : {0} bytes" -f $img.Length)

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
    $hImg = [BitConverter]::ToString($sha.ComputeHash($img)).Replace('-', '')
    $hCard = [BitConverter]::ToString($sha.ComputeHash($buf)).Replace('-', '')
    Log ("sha256 img : {0}" -f $hImg)
    Log ("sha256 card: {0}" -f $hCard)

    if ($hImg -eq $hCard) {
        Log "RESULT: OK - full image identical"
    } else {
        $bad = 0
        $first = -1
        for ($k = 0; $k -lt $img.Length; $k++) {
            if ($buf[$k] -ne $img[$k]) { $bad++; if ($first -lt 0) { $first = $k } }
        }
        Log ("RESULT: MISMATCH - {0} bytes differ, first at 0x{1:X}" -f $bad, $first)
    }
}
catch {
    Log ("RESULT: FAIL - {0}" -f $_.Exception.Message)
}
