# Temporary test: runs the ARM64 guest in QEMU, emulated (TCG), and takes a screenshot through QMP (every 3 minutes for the first hour,
# then every 10) until the guest powers itself off (the benchmark at its first sign-in ends with that) or the time limit, when QEMU is told
# to quit, which closes the disk cleanly so it can be read afterwards.
param([string]$Cpu = 'max,pauth-impdef=on', [int]$Smp = 4, [string]$Mem = '8G', [int]$LimitMinutes = 180)
$Work = 'D:\armtest'
$q = 'C:\msys64\ucrt64'
function Log($m) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }
Copy-Item "$q\share\qemu\edk2-arm-vars.fd" "$Work\vars.fd" -Force
New-Item -ItemType Directory -Force "$Work\shots" | Out-Null
$qargs = @('-M', 'virt,gic-version=3,highmem=on', '-cpu', $Cpu, '-smp', "$Smp", '-m', $Mem, '-accel', 'tcg,thread=multi,tb-size=1024',
    '-drive', "if=pflash,format=raw,readonly=on,file=$q\share\qemu\edk2-aarch64-code.fd", '-drive', "if=pflash,format=raw,file=$Work\vars.fd",
    '-device', 'ramfb', '-device', 'qemu-xhci', '-device', 'usb-kbd', '-device', 'usb-tablet', '-rtc', 'base=utc',
    '-drive', "file=$Work\arm.vhdx,if=none,id=nvm,format=vhdx,cache=writeback", '-device', 'nvme,drive=nvm,serial=armtest',
    '-nic', 'none', '-qmp', 'tcp:127.0.0.1:4444,server=on,wait=off', '-display', 'none', '-serial', "file:$Work\serial.txt")
Log "Starting QEMU: qemu-system-aarch64 $($qargs -join ' ')"
$started = Get-Date
$p = Start-Process -FilePath "$q\bin\qemu-system-aarch64.exe" -ArgumentList $qargs -PassThru -RedirectStandardError "$Work\qemu-stderr.txt" -RedirectStandardOutput "$Work\qemu-stdout.txt"
function Qmp([string]$cmd) {
    # QMP's answer to the command (events it sends first are skipped)
    $c = New-Object Net.Sockets.TcpClient('127.0.0.1', 4444)
    try {
        $s = $c.GetStream(); $w = New-Object IO.StreamWriter($s); $r = New-Object IO.StreamReader($s)
        [void]$r.ReadLine(); $w.WriteLine('{"execute":"qmp_capabilities"}'); $w.Flush(); [void]$r.ReadLine()
        $w.WriteLine($cmd); $w.Flush()
        do { $line = $r.ReadLine() } while ($line -and $line -match '"event"')
        return $line
    } finally { $c.Close() }
}
Start-Sleep -Seconds 20
while (-not $p.HasExited -and ((Get-Date) - $started).TotalMinutes -lt $LimitMinutes) {
    $minutes = [int]((Get-Date) - $started).TotalMinutes
    $name = "$Work\shots\" + ('{0:D3}' -f $minutes) + 'min.ppm'
    $answer = try { Qmp ('{"execute":"screendump","arguments":{"filename":"' + ($name -replace '\\', '/') + '"}}') } catch { "QMP error: $($_.Exception.Message)" }
    $saved = if (Test-Path $name) { '{0:N0} KB' -f ((Get-Item $name).Length / 1KB) } else { 'not saved' }
    $cpu = try { [math]::Round((Get-Process -Id $p.Id).CPU / 60, 1) } catch { '?' }
    Log "running for $minutes min (QEMU CPU time $cpu min); screenshot $saved; QMP: $answer"
    $wait = if ($minutes -lt 60) { 180 } else { 600 }
    for ($i = 0; $i -lt $wait -and -not $p.HasExited; $i++) { Start-Sleep -Seconds 1 }
}
if ($p.HasExited) {
    Log ("The guest powered off after {0:N1} min (QEMU exit code {1})" -f ((Get-Date) - $started).TotalMinutes, $p.ExitCode)
} else {
    Log "Time limit of $LimitMinutes min reached; telling QEMU to quit"
    try { Log "QMP: $(Qmp '{"execute":"quit"}')" } catch { Log "QMP error: $($_.Exception.Message)" }
    if (-not $p.WaitForExit(120000)) { Log 'QEMU is still running; stopping it'; Stop-Process -Id $p.Id -Force; Start-Sleep -Seconds 5 }
}
Get-Content "$Work\qemu-stderr.txt" -ErrorAction SilentlyContinue | Select-Object -Last 20 | ForEach-Object { Log "qemu: $_" }
Get-Content "$Work\serial.txt" -ErrorAction SilentlyContinue | Select-Object -Last 30 | ForEach-Object { Log "serial: $_" }
