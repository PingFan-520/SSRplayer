# =============================================================================
#  write_sd.ps1 -- write sd_image.img to SD card (raw sectors)
#
#  Must run as Administrator (called by write_sd.bat).
#
#  Approach:
#    mountvol /P makes the card reader re-enumerate; the following write then
#    fails with "device not ready". The correct way is to LOCK the volume:
#      CreateFile("\\.\X:") + FSCTL_LOCK_VOLUME + FSCTL_DISMOUNT_VOLUME
#    The device stays ready, we just take exclusive write access.
#    The volume handle must be kept open until the write finishes,
#    otherwise the lock is released. (Same trick Win32DiskImager uses.)
#
#  Safety: disk number is fixed to 2 and cross-checked (USB + size > 6GB)
#          before anything is written.
# =============================================================================
$ErrorActionPreference = 'Stop'
$LogPath = 'D:\Work\fpga\yuanshen\sd_write_log.txt'
$ImgPath = 'D:\Work\fpga\yuanshen\sd_image.img'
$DiskNum = 2

function Log($m) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    Write-Host $line
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
}

"=== write_sd start ===" | Set-Content -Path $LogPath -Encoding UTF8

# ---- P/Invoke helpers -------------------------------------------------------
$cs = @'
using System;
using System.Runtime.InteropServices;
public static class VolTool {
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Auto)]
    public static extern IntPtr CreateFile(string lpFileName, uint dwDesiredAccess, uint dwShareMode,
        IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool DeviceIoControl(IntPtr hDevice, uint dwIoControlCode,
        IntPtr lpInBuffer, uint nInBufferSize, IntPtr lpOutBuffer, uint nOutBufferSize,
        out uint lpBytesReturned, IntPtr lpOverlapped);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool CloseHandle(IntPtr hObject);
}
'@
Add-Type -TypeDefinition $cs -ErrorAction Stop

$GENERIC_READ   = 0x80000000
$GENERIC_WRITE  = 0x40000000
$FILE_SHARE_RW  = 3
$OPEN_EXISTING  = 3
$FSCTL_LOCK_VOLUME     = 0x00090018
$FSCTL_DISMOUNT_VOLUME = 0x00090020
$INVALID_HANDLE = [IntPtr](-1)

$vhandle = [IntPtr]::Zero

try {
    # ---------- 0. admin check ----------
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw "Not running as Administrator" }
    Log "admin: OK"

    # ---------- 1. verify target disk ----------
    $d = Get-Disk -Number $DiskNum
    Log ("target: #{0} {1}  {2:N2} GB  {3}" -f $d.Number, $d.FriendlyName, ($d.Size/1GB), $d.BusType)

    if ($d.BusType -ne 'USB') { throw "Disk $DiskNum is not USB, abort" }
    if ($d.Size -lt 6GB)      { throw "Disk $DiskNum size looks wrong, abort" }

    $img = [IO.File]::ReadAllBytes($ImgPath)
    Log ("image : {0} bytes ({1:N2} MB)" -f $img.Length, ($img.Length/1MB))
    if ($d.Size -lt $img.Length) { throw "card smaller than image" }

    # ---------- 2. lock + dismount the volume (keep handle open!) ----------
    $part = Get-Partition -DiskNumber $DiskNum -ErrorAction SilentlyContinue |
            Where-Object { $_.DriveLetter } | Select-Object -First 1
    if ($part) {
        $letter = $part.DriveLetter
        Log ("volume {0}: found, locking..." -f $letter)
        $vhandle = [VolTool]::CreateFile("\\.\$($letter):", ($GENERIC_READ -bor $GENERIC_WRITE),
                                         $FILE_SHARE_RW, [IntPtr]::Zero, $OPEN_EXISTING, 0, [IntPtr]::Zero)
        if ($vhandle -eq $INVALID_HANDLE -or $vhandle -eq [IntPtr]::Zero) {
            Log "CreateFile on volume failed (continue anyway)"
            $vhandle = [IntPtr]::Zero
        } else {
            $br = [uint32]0
            $okL = [VolTool]::DeviceIoControl($vhandle, $FSCTL_LOCK_VOLUME,
                       [IntPtr]::Zero, 0, [IntPtr]::Zero, 0, [ref]$br, [IntPtr]::Zero)
            $okD = [VolTool]::DeviceIoControl($vhandle, $FSCTL_DISMOUNT_VOLUME,
                       [IntPtr]::Zero, 0, [IntPtr]::Zero, 0, [ref]$br, [IntPtr]::Zero)
            Log ("volume lock={0} dismount={1}" -f $okL, $okD)
        }
        Start-Sleep -Milliseconds 600
    } else {
        Log "no mounted volume on this disk, writing directly"
    }

    # ---------- 3. open physical disk with retry ----------
    $fs = $null
    for ($i = 1; $i -le 6; $i++) {
        try {
            $fs = [IO.File]::Open("\\.\PhysicalDrive$DiskNum", 'Open', 'ReadWrite')
            Log ("open PhysicalDrive{0}: OK (attempt {1})" -f $DiskNum, $i)
            break
        } catch {
            Log ("open attempt {0} failed: {1}" -f $i, $_.Exception.Message)
            Start-Sleep -Milliseconds 1200
        }
    }
    if (-not $fs) { throw "cannot open physical drive after retries" }

    # ---------- 4. write ----------
    try {
        $fs.Write($img, 0, $img.Length)
        $fs.Flush()
    } finally {
        $fs.Close()
    }
    Log ("written: {0} bytes" -f $img.Length)

    # ---------- 5. read back and verify ----------
    #  Full SHA256 + per-image slot dump. Nothing is hard-coded:
    #  earlier version checked "1MB + 5 * 922112" which silently broke
    #  as soon as the image layout changed (stride 1801 -> 5408 sectors).
    $buf = New-Object byte[] $img.Length
    $fs = [IO.File]::Open("\\.\PhysicalDrive$DiskNum", 'Open', 'Read')
    try {
        $fs.Seek(0, 'Begin') | Out-Null
        $got = 0
        while ($got -lt $img.Length) {
            $n = $fs.Read($buf, $got, $img.Length - $got)
            if ($n -le 0) { throw "read returned 0 at $got" }
            $got += $n
        }
    } finally {
        $fs.Close()
    }

    $sha = [Security.Cryptography.SHA256]::Create()
    $hImg  = [BitConverter]::ToString($sha.ComputeHash($img)).Replace('-', '')
    $hCard = [BitConverter]::ToString($sha.ComputeHash($buf)).Replace('-', '')
    if ($hImg -eq $hCard) {
        Log "verify sha256 : match (full image)"
    } else {
        $bad = 0; $first = -1
        for ($k = 0; $k -lt $img.Length; $k++) {
            if ($buf[$k] -ne $img[$k]) { $bad++; if ($first -lt 0) { $first = $k } }
        }
        Log ("verify sha256 : MISMATCH - {0} bytes differ, first at 0x{1:X}" -f $bad, $first)
        throw "read-back mismatch"
    }

    # per-image slot dump (stride derived from the image itself)
    $slots = @()
    $pos = 2048 * 512
    while ($pos -lt $img.Length - 54) {
        $p = [Array]::IndexOf($img, [byte]0x42, $pos)
        if ($p -lt 0 -or $p -ge $img.Length - 54) { break }
        $pos = $p + 1
        if ($img[$p+1] -ne 0x4D) { continue }
        $off = [BitConverter]::ToUInt32($img, $p + 10)
        $bpp = [BitConverter]::ToUInt16($img, $p + 28)
        $w   = [BitConverter]::ToInt32($img, $p + 18)
        $h   = [BitConverter]::ToInt32($img, $p + 22)
        $bf  = [BitConverter]::ToUInt32($img, $p + 2)
        if ($off -eq 54 -and $bpp -eq 24 -and $w -gt 0 -and $w -le 4096 -and
            [Math]::Abs($h) -ge 1 -and [Math]::Abs($h) -le 4096 -and
            $bf -gt 54 -and ($p + $bf) -le $img.Length) {
            $slots += [pscustomobject]@{ Pos = $p; W = $w; H = [Math]::Abs($h) }
        }
    }
    $stride = 0
    if ($slots.Count -ge 2) { $stride = $slots[1].Pos - $slots[0].Pos }
    Log ("slots         : {0}   stride {1} bytes ({2} sectors)" -f $slots.Count, $stride, ($stride / 512))
    foreach ($s in $slots) {
        $tag = [Text.Encoding]::ASCII.GetString($buf, $s.Pos, 2)
        Log ("  {0}x{1} @sector {2}  '{3}'" -f $s.W, $s.H, ($s.Pos / 512), $tag)
    }

    Log "RESULT: OK"
}
catch {
    Log ("RESULT: FAIL - {0}" -f $_.Exception.Message)
}
finally {
    if ($vhandle -ne [IntPtr]::Zero -and $vhandle -ne $INVALID_HANDLE) {
        [VolTool]::CloseHandle($vhandle) | Out-Null
    }
}
