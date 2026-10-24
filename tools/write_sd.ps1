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
    $fs = [IO.File]::Open("\\.\PhysicalDrive$DiskNum", 'Open', 'Read')
    try {
        $buf = New-Object byte[] 4096

        $fs.Seek(1048576, 'Begin') | Out-Null
        $fs.Read($buf, 0, 4096) | Out-Null
        Log ("check @1MB     : '{0}'  (expect 'BM')" -f [Text.Encoding]::ASCII.GetString($buf, 0, 2))

        $bad = 0
        for ($k = 0; $k -lt 4096; $k++) { if ($buf[$k] -ne $img[1048576 + $k]) { $bad++ } }
        Log ("verify 4096B   : {0} mismatch" -f $bad)

        $tailOff = 1048576 + 5 * 922112
        $fs.Seek($tailOff, 'Begin') | Out-Null
        $t = New-Object byte[] 2
        $fs.Read($t, 0, 2) | Out-Null
        Log ("check @last img: '{0}'  (expect 'BM')" -f [Text.Encoding]::ASCII.GetString($t, 0, 2))
    } finally {
        $fs.Close()
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
