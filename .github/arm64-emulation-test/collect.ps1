# Temporary test: collects the screenshots, then reads what the guest wrote from its disk (read-only), for the artifact and the log.
$Work = 'D:\armtest'
$out = "$Work\out"
New-Item -ItemType Directory -Force $out | Out-Null
function Log($m) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }
Copy-Item "$Work\shots" $out -Recurse -ErrorAction SilentlyContinue
Copy-Item "$Work\qemu-*.txt", "$Work\serial.txt" $out -ErrorAction SilentlyContinue
Log "Screenshots: $(@(Get-ChildItem "$Work\shots" -File -ErrorAction SilentlyContinue).Count)"

$vhd = "$Work\arm.vhdx"
$disk = try { Mount-VHD -Path $vhd -ReadOnly -Passthru -ErrorAction Stop | Get-Disk } catch { Log "Mount-VHD: $($_.Exception.Message)"; $null }
if (-not $disk) {
    # A copy made by QEMU's own tool, which reads what QEMU wrote
    $ErrorActionPreference = 'Continue'
    & C:\msys64\ucrt64\bin\qemu-img.exe check $vhd 2>&1 | Select-Object -Last 5 | ForEach-Object { Log "qemu-img check: $_" }
    $vhd = "$Work\arm-copy.vhdx"
    & C:\msys64\ucrt64\bin\qemu-img.exe convert -O vhdx -o subformat=dynamic "$Work\arm.vhdx" $vhd 2>&1 | Select-Object -Last 5 | ForEach-Object { Log "qemu-img convert: $_" }
    $disk = try { Mount-VHD -Path $vhd -ReadOnly -Passthru -ErrorAction Stop | Get-Disk } catch { Log "Mount-VHD of the copy: $($_.Exception.Message)"; $null }
}
if (-not $disk) { Log "The guest's disk can't be read"; return }
try {
    $part = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 10GB } | Select-Object -First 1
    if (-not $part.DriveLetter) { $part | Add-PartitionAccessPath -AssignDriveLetter; $part = Get-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber }
    $root = "$($part.DriveLetter):\"
    Log "Guest disk at $root"
    Copy-Item "${root}armtest\*.txt" $out -ErrorAction SilentlyContinue
    foreach ($log in 'Windows\Panther\setupact.log', 'Windows\Panther\setuperr.log', 'Windows\Panther\UnattendGC\setupact.log', 'Windows\Setup\State\State.ini', 'Windows\System32\winevt\Logs\System.evtx', 'Windows\System32\winevt\Logs\Setup.evtx') {
        $path = Join-Path $root $log
        if (Test-Path $path) { Copy-Item $path (Join-Path $out (($log -replace '[\\:]', '_'))) }
    }
    foreach ($f in 'setup.txt', 'results.txt') {
        $path = Join-Path $out $f
        if (Test-Path $path) { Log "== $f"; Get-Content $path | ForEach-Object { Log $_ } } else { Log "== no $f" }
    }
    $state = Join-Path $root 'Windows\Setup\State\State.ini'
    if (Test-Path $state) { Log '== State.ini'; Get-Content $state | ForEach-Object { Log $_ } }
    $setupact = Join-Path $root 'Windows\Panther\setupact.log'
    if (Test-Path $setupact) { Log '== the end of Panther\setupact.log'; Get-Content $setupact -Tail 25 | ForEach-Object { Log $_ } }
    Log "Crash dumps: $(@(Get-ChildItem "${root}Windows\Minidump" -File -ErrorAction SilentlyContinue).Count) minidumps, MEMORY.DMP $(Test-Path "${root}Windows\MEMORY.DMP")"
} finally {
    Dismount-VHD -Path $vhd
}
