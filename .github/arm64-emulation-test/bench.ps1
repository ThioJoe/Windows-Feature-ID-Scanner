# A fixed workload, timed: run in the emulated ARM64 guest at first sign-in, and natively for comparison.
param([string]$Out = 'C:\armtest\results.txt', [switch]$NoShutdown)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null
function W($s) { Add-Content -Path $Out -Value ("{0:o} {1}" -f (Get-Date), $s) }
$os = Get-CimInstance Win32_OperatingSystem
W "start; boot $($os.LastBootUpTime.ToString('o')); $($os.Caption) $($os.Version) $($os.OSArchitecture); $env:PROCESSOR_ARCHITECTURE; cpus $([Environment]::ProcessorCount)"
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
W "build $($cv.CurrentBuildNumber).$($cv.UBR) $($cv.DisplayVersion) $($cv.EditionID)"
$t = Measure-Command { $x = 0; for ($i = 0; $i -lt 1000000; $i++) { $x += $i } }; W ("loop1e6 {0:N2}" -f $t.TotalSeconds)
$t = Measure-Command { $b = New-Object byte[] (256MB); [void](New-Object Security.Cryptography.SHA256Managed).ComputeHash($b) }; W ("sha256_256MB {0:N2}" -f $t.TotalSeconds)
$t = Measure-Command { $n = (Get-AppxPackage -AllUsers | Measure-Object).Count }; W ("appx_list {0:N2} ({1} packages)" -f $t.TotalSeconds, $n)
$t = Measure-Command { $n = (Get-ChildItem C:\Windows\System32 -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object).Count }; W ("dir_system32 {0:N2} ({1} items)" -f $t.TotalSeconds, $n)
$t = Measure-Command { & dism.exe /English /online /get-features /format:table | Out-Null }; W ("dism_get_features {0:N2}" -f $t.TotalSeconds)
$t = Measure-Command { $p = Start-Process powershell.exe -ArgumentList '-NoProfile', '-Command', 'exit 0' -PassThru -Wait }; W ("powershell_start {0:N2}" -f $t.TotalSeconds)
$t = Measure-Command { $s = New-Object -ComObject Shell.Application; $n = @($s.NameSpace('shell:::{ED7BA470-8E54-465E-825C-99712043E01C}').Items()).Count }; W ("shell_godmode_items {0:N2} ({1} items)" -f $t.TotalSeconds, $n)
W 'done'
if (-not $NoShutdown) { Stop-Computer -Force }
