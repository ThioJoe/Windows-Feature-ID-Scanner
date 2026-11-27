# Temporary test: reads what the guest wrote from its disk (read-only), for the artifact and the log.
$Work = 'D:\armtest'
$out = "$Work\out"
New-Item -ItemType Directory -Force $out | Out-Null
function Log($m) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }
$vhd = "$Work\arm.vhdx"
$disk = Mount-VHD -Path $vhd -ReadOnly -Passthru | Get-Disk
try {
    $letter = (Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Type -eq 'Basic' -and $_.Size -gt 10GB } | Select-Object -First 1).DriveLetter
    if (-not $letter) {
        $part = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 10GB } | Select-Object -First 1
        $part | Add-PartitionAccessPath -AssignDriveLetter
        $letter = (Get-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber).DriveLetter
    }
    $root = "${letter}:\"
    Log "Guest disk at $root"
    Copy-Item "${root}armtest\*.txt" $out -ErrorAction SilentlyContinue
    foreach ($log in 'Windows\Panther\setupact.log', 'Windows\Panther\UnattendGC\setupact.log', 'Windows\Setup\State\State.ini') {
        $path = Join-Path $root $log
        if (Test-Path $path) { Copy-Item $path (Join-Path $out (($log -replace '[\\:]', '_'))) }
    }
    foreach ($f in 'setup.txt', 'results.txt') {
        $path = Join-Path $out $f
        if (Test-Path $path) { Log "== $f"; Get-Content $path | ForEach-Object { Log $_ } } else { Log "== no $f" }
    }
    $state = Join-Path $root 'Windows\Setup\State\State.ini'
    if (Test-Path $state) { Log "== State.ini"; Get-Content $state | ForEach-Object { Log $_ } }
} finally {
    Dismount-VHD -Path $vhd
}
Copy-Item "$Work\shots" $out -Recurse -ErrorAction SilentlyContinue
Copy-Item "$Work\qemu-*.txt" $out -ErrorAction SilentlyContinue
