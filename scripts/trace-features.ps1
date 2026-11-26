# trace-features.ps1
# Records which features Windows' code checks while it runs. Each time code checks a feature, Windows can write an event from the
# Microsoft-Windows-FeatureConfiguration ETW provider (its manifest is in fcon.dll), with the feature's ID, the stage compiled into the
# binary that checked it (the event ID: 1007 always disabled, 1008 disabled by default, 1009 enabled by default, 1010 always enabled),
# how the check came out, and in the event header, the process that made it. A feature only shows up if code that checks it runs while
# the trace records, so after leaving Windows alone for a while, the script opens what it can, one at a time in the signed-in user's
# session: the shell's own UI (with its keyboard shortcuts), the Start menu's Microsoft apps, and every ms-settings: page, Windows
# Security page, Control Panel task link and shell folder Super God Mode found (its statistics, from run-super-god-mode.ps1).
#
#   .\scripts\trace-features.ps1 -Prepare        # Start recording at the next restart, so the trace has boot and sign-in (the VM scanner)
#   .\scripts\trace-features.ps1 -OutputDir output-temp\trace -SuperGodModeDir output-temp\super-god-mode
#
# The second form uses the session the restart started if there is one, and otherwise starts one (and restarts the shell, so its
# startup is in the trace). It writes trace.json to -OutputDir (summarize-trace.py's summary, which update-data.py adds to the build's
# data), with the decoded events and the logs it was made from. The trace comes in addition to the scan, so a failure is reported
# (in trace.json too) but this script still succeeds.
#
# The targets run as the signed-in user, elevated (so nothing waits for a UAC prompt), through a scheduled task. That part is this same
# script with -Targets, which opens each target, waits, closes what it opened and records when, so checks can be put down to it.

param(
    [string]$OutputDir,
    [string]$SuperGodModeDir,              # Super God Mode's statistics; without them only the shell's UI and the Start menu's apps are opened
    [switch]$Prepare,
    [int]$IdleMinutes = 5,                 # How long Windows is left alone first (from sign-in, when the trace started at boot)
    [int]$TargetMinutes = 90,              # Time limit for opening targets, for one that hangs (all of them took 68 minutes in a test on the ARM64 runner)
    [string]$Python = 'python',            # For summarize-trace.py
    [string]$Targets,                      # (Internal) Open the targets as the signed-in user, recording them in this CSV file
    [switch]$RestartShell                  # (Internal, with -Targets) Restart Explorer first
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Provider = '{c2f36562-a1e4-4bc3-a6f6-01a7adb643e8}'  # Microsoft-Windows-FeatureConfiguration
$KernelProcess = 'Microsoft-Windows-Kernel-Process'    # Its process start events (keyword 0x10) give each process ID's image name
$Session = 'FeatureUsage'
$TraceDir = 'C:\feature-trace'

function Now { (Get-Date).ToUniversalTime().ToString('o') }

# ---------------------------------------------------------------------------
# The targets, as the signed-in user
# ---------------------------------------------------------------------------

if ($Targets) {
    # An error that stops the targets goes in a file next to their log, for the run's report (the scheduled task has no window)
    trap { "$($_.Exception.Message) $($_.InvocationInfo.PositionMessage)" -replace '\s+', ' ' | Set-Content "$Targets.error" -ErrorAction SilentlyContinue; break }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class TraceKeys {
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    static readonly byte[] Extended = { 0x5B, 0x2E, 0x25, 0x26, 0x27, 0x28 };  // Win, Delete and the arrows are extended keys
    static uint Flags(byte vk) { return Array.IndexOf(Extended, vk) >= 0 ? 1u : 0u; }
    // Presses the keys in order, holds them, and releases them in reverse
    public static void Chord(byte[] keys, int holdMs) {
        foreach (byte k in keys) { keybd_event(k, 0, Flags(k), UIntPtr.Zero); System.Threading.Thread.Sleep(30); }
        System.Threading.Thread.Sleep(holdMs);
        for (int i = keys.Length - 1; i >= 0; i--) { keybd_event(keys[i], 0, Flags(keys[i]) | 2u, UIntPtr.Zero); System.Threading.Thread.Sleep(30); }
    }
}
public static class TracePages {
    // Opens a page through the shell, on a thread of its own: the shell waits until the page's app has taken it, which an app that has
    // stopped responding doesn't (the shell gives up after a minute). The error, "" when the page opened, or null after timeoutMs.
    public static string Open(string page, int timeoutMs) {
        string result = null;
        var thread = new System.Threading.Thread(() => {
            try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(page) { UseShellExecute = true }); result = ""; }
            catch (Exception e) { result = e.Message; }
        });
        thread.IsBackground = true;
        thread.SetApartmentState(System.Threading.ApartmentState.STA);
        thread.Start();
        return thread.Join(timeoutMs) ? result : null;
    }
}
'@
    $session = (Get-Process -Id $PID).SessionId
    $deadline = (Get-Date).AddMinutes($TargetMinutes)
    # Processes a target may start that are part of Windows itself, or of the runner, and stay running
    $keep = 'explorer', 'sihost', 'dwm', 'ctfmon', 'taskhostw', 'RuntimeBroker', 'backgroundTaskHost', 'dllhost', 'svchost', 'conhost', 'powershell',
        'pwsh', 'SearchHost', 'SearchProtocolHost', 'SearchFilterHost', 'StartMenuExperienceHost', 'ShellExperienceHost', 'ShellHost', 'TextInputHost',
        'ApplicationFrameHost', 'smartscreen', 'SecurityHealthSystray', 'Widgets', 'WidgetService', 'LockApp', 'UserOOBEBroker', 'fontdrvhost',
        'WmiPrvSE', 'audiodg', 'CompPkgSrv', 'csrss', 'winlogon', 'SystemSettingsBroker', 'Runner.Listener', 'Runner.Worker', 'Runner.Provisioner'
    $windowed = 'SystemSettings', 'SecHealthUI', 'CalculatorApp', 'GameBar', 'osk', 'mmc', 'rundll32', 'control', 'msdt', 'xwizard', 'SnippingTool', 'ScreenClippingHost'
    function Get-Ours { @(Get-Process | Where-Object { $_.SessionId -eq $session }) }
    function Close-Targets($before, [string[]]$spare = @()) {
        # Closes what the target opened: File Explorer's windows, and processes in this session started since, that aren't part of Windows
        # and have a window, are an app, or are known to open one
        try { (New-Object -ComObject Shell.Application).Windows() | ForEach-Object { try { $_.Quit() } catch {} } } catch {}
        $old = @{}; foreach ($p in $before) { $old[$p.Id] = $true }
        foreach ($p in Get-Ours) {
            if ($old[$p.Id] -or $p.Id -eq $PID -or $keep -contains $p.ProcessName -or $spare -contains $p.ProcessName) { continue }
            $path = try { $p.Path } catch { '' }
            if ($p.MainWindowHandle -ne 0 -or $windowed -contains $p.ProcessName -or $path -match '\\(WindowsApps|SystemApps)\\') {
                try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch {}
            }
        }
    }
    function Write-Target([string]$kind, [string]$label, [string]$target, [string]$opened, [string]$problem) {
        [pscustomobject]@{ kind = $kind; label = $label; target = $target; opened = $opened; closed = (Now); error = $problem } |
            Export-Csv -Path $Targets -Append -NoTypeInformation -Encoding UTF8
    }
    function Open-Target([string]$kind, [string]$label, [string]$target, [scriptblock]$open, [int]$seconds, [string[]]$spare = @()) {
        if ((Get-Date) -gt $deadline) { Write-Target $kind $label $target '' 'time limit'; return }
        $before = Get-Ours
        $opened = Now; $problem = ''
        try { & $open } catch { $problem = $_.Exception.Message -replace '\s+', ' ' }
        Start-Sleep -Seconds $seconds
        [TraceKeys]::Chord([byte[]](0x1B), 50)  # Esc, for a menu, flyout or dialog it left open
        Start-Sleep -Milliseconds 300
        Close-Targets $before $spare
        Start-Sleep -Seconds 1
        Write-Target $kind $label $target $opened $problem
    }
    function Read-List([string]$file) {
        $path = if ($SuperGodModeDir) { Join-Path $SuperGodModeDir $file } else { '' }
        if ($path -and (Test-Path $path)) { @(Import-Csv $path) } else { @() }
    }
    function Split-Command([string]$command) {
        # The program and its arguments, with environment variables expanded
        $c = [Environment]::ExpandEnvironmentVariables($command.Trim())
        if ($c -match '^"([^"]+)"\s*(.*)$' -or $c -match '^(\S+)\s*(.*)$') { return $Matches[1], $Matches[2] }
        return $c, ''
    }
    function Start-Command([string]$command) {
        $exe, $arguments = Split-Command $command
        if ($exe -match '^(shell:|::\{)') { $arguments = "$exe $arguments".Trim(); $exe = 'explorer.exe' }
        if ($arguments) { Start-Process -FilePath $exe -ArgumentList $arguments } else { Start-Process -FilePath $exe }
    }
    function Open-Page([string]$kind, [string]$page, [string]$app, [string]$homePage) {
        # A page in the app's window. Opening one waits until the app has taken it, which an app that has stopped responding doesn't
        # (Windows gives up after a minute): on some runners, Settings stops responding whenever it's sent to another page from Display
        # or Advanced display (from Display even after 15 seconds on it). So after 10 seconds the app is closed and started again on its
        # home page, between targets so that its startup checks count for none, and the page is opened again.
        for ($try = 1; $try -le 2; $try++) {
            $script:pageFailed = $false
            Open-Target $kind $page $page {
                $result = [TracePages]::Open($page, 10000)
                if ($null -eq $result) { $script:pageFailed = $true; throw "$app stopped responding" }
                if ($result) { throw $result }
            } 2 @($app)
            if (-not $script:pageFailed -or (Get-Date) -gt $deadline) { return }
            try { Get-Process $app -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session } | Stop-Process -Force } catch {}
            try { Start-Process $homePage } catch {}
            Start-Sleep -Seconds 6
        }
    }

    Write-Target 'start' 'process' "$PID" (Now) ''  # So the summary can leave out this script's own checks

    if ($RestartShell) {
        # The trace started after sign-in, so the startup of Explorer (with the taskbar) and of the shell's hosts isn't in it yet. They
        # start again by themselves: Explorer through Winlogon, ShellHost (Quick Settings, the notification center, Run) and
        # TextInputHost (the emoji panel, the touch keyboard) at once, the others when they're next used. Their flyouts check few
        # features when they open, having checked them when they started.
        $opened = Now; $problem = ''
        try {
            Get-Process explorer, StartMenuExperienceHost, SearchHost, ShellExperienceHost, ShellHost, TextInputHost -ErrorAction SilentlyContinue |
                Where-Object { $_.SessionId -eq $session } | Stop-Process -Force
            $back = $false
            for ($i = 0; $i -lt 15 -and -not $back; $i++) { Start-Sleep -Seconds 2; $back = [bool](Get-Process explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session }) }
            if (-not $back) { Start-Process explorer.exe }
            Start-Sleep -Seconds 20
        } catch { $problem = $_.Exception.Message -replace '\s+', ' ' }
        Write-Target 'shell' 'Explorer (restarted)' 'explorer.exe' $opened $problem
    }

    # The shell's own UI. Esc closes each; what would lock the PC or start Narrator or Magnifier isn't here.
    $W = 0x5B
    $keys = @(
        @('Start menu (Win)', @($W)), @('Search (Win+S)', @($W, 0x53)), @('Quick Settings (Win+A)', @($W, 0x41)),
        @('Notification center (Win+N)', @($W, 0x4E)), @('Widgets (Win+W)', @($W, 0x57)), @('Task view (Win+Tab)', @($W, 0x09)),
        @('Quick Link menu (Win+X)', @($W, 0x58)), @('Clipboard history (Win+V)', @($W, 0x56)), @('Emoji panel (Win+.)', @($W, 0xBE)),
        @('Cast (Win+K)', @($W, 0x4B)), @('Project (Win+P)', @($W, 0x50)), @('Run (Win+R)', @($W, 0x52)),
        @('Snipping overlay (Win+Shift+S)', @($W, 0x10, 0x53)), @('Notification area (Win+B)', @($W, 0x42)), @('Taskbar (Win+T)', @($W, 0x54)),
        @('Voice typing (Win+H)', @($W, 0x48)), @('Copilot (Win+C)', @($W, 0x43)), @('Game Bar (Win+G)', @($W, 0x47)),
        @('Switcher (Alt+Tab)', @(0x12, 0x09)), @('Show desktop (Win+D)', @($W, 0x44)), @('Desktop context menu (Shift+F10)', @(0x10, 0x79))
    )
    foreach ($k in $keys) {
        $chord = [byte[]]$k[1]
        $hold = if ($k[0] -like 'Switcher*') { 1500 } else { 50 }
        Open-Target 'keys' $k[0] $k[0] { [TraceKeys]::Chord($chord, $hold) } 3
    }
    Open-Target 'keys' 'New virtual desktop (Win+Ctrl+D)' 'Win+Ctrl+D' { [TraceKeys]::Chord([byte[]]($W, 0x11, 0x44), 50); Start-Sleep -Seconds 3; [TraceKeys]::Chord([byte[]]($W, 0x11, 0x73), 50) } 2

    # The Start menu's apps that come with Windows (on a runner, the Start menu also has its tools). Not the accessibility tools that
    # take over input or speak (Narrator, Magnifier, Voice access, On-Screen Keyboard), a console, or the recovery drive wizard.
    $skipApps = 'narrator', 'magnify', 'voiceaccess', 'osk', 'RecoveryDrive', 'cmd', 'powershell', 'PowerShell_ISE'
    $apps = @(Get-StartApps | Where-Object {
        $app = $_
        ($app.AppID -match '_(8wekyb3d8bbwe|cw5n1h2txyewy)!' -or $app.AppID -match '^(Microsoft\.Windows\.|windows\.immersivecontrolpanel)' -or
         $app.AppID -match '^\{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7\}\\[^\\]+\.(exe|msc)$') -and   # FOLDERID_System: System32's own tools
        -not ($skipApps | Where-Object { $app.AppID -match "\\$([regex]::Escape($_))\.exe$" })
    } | Sort-Object Name)
    foreach ($a in $apps) {
        $id = $a.AppID
        Open-Target 'app' $a.Name $id { Start-Process explorer.exe "shell:AppsFolder\$id" } 8
    }

    # Settings pages, in one Settings window (opening a page in it again goes to that page). Its home page first, which takes the checks
    # of the app starting, so they don't count for the first page in the list. In a Settings window that's already open, a page's own
    # checks come within half a second, so each page gets 2 seconds.
    $settings = @(Read-List 'MS_Settings.csv' | ForEach-Object { $_.'Full Setting Command' } | Where-Object { $_ -like 'ms-settings:*' } | Select-Object -Unique)
    if ($settings) { Open-Target 'settings' 'Settings (home)' 'ms-settings:' { Start-Process 'ms-settings:' } 6 @('SystemSettings') }
    foreach ($s in $settings) { Open-Page 'settings' $s 'SystemSettings' 'ms-settings:' }
    Get-Process SystemSettings -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session } | Stop-Process -Force

    # Windows Security pages, the same way
    $security = @(Read-List 'Deep_Links.csv' | ForEach-Object { $_.'Full Command' } | Where-Object { $_ -like 'windowsdefender:*' } | Select-Object -Unique)
    if ($security) { Open-Target 'security' 'Windows Security (home)' 'windowsdefender:' { Start-Process 'windowsdefender:' } 6 @('SecHealthUI') }
    foreach ($s in $security) { Open-Page 'security' $s 'SecHealthUI' 'windowsdefender:' }
    Get-Process SecHealthUI -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session } | Stop-Process -Force

    # Control Panel's task links: its pages, applets, wizards and tools. Not Narrator, the recovery drive wizard or help links.
    $tasks = @(Read-List 'Task_Links.csv' | Where-Object { $_.Command -and $_.Command -notmatch 'narrator|recoverydrive|^mshelp:' } |
        Group-Object Command | ForEach-Object { $_.Group[0] })
    foreach ($t in $tasks) {
        $command = $t.Command
        Open-Target 'task' $t.Name $command { Start-Command $command } 4
    }

    # Shell folders: by CLSID, then by name
    foreach ($f in Read-List 'CLSID_Shell_Folders.csv') {
        $target = "shell:::$($f.CLSID)"
        Open-Target 'folder' $f.Name $target { Start-Process explorer.exe $target } 3
    }
    foreach ($f in Read-List 'Named_Shell_Folders.csv') {
        $target = "shell:$($f.Name)"
        Open-Target 'folder' $f.Name $target { Start-Process explorer.exe $target } 3
    }
    Write-Target 'end' 'done' '' (Now) ''
    exit 0
}

# ---------------------------------------------------------------------------
# Recording, as an administrator
# ---------------------------------------------------------------------------

function Invoke-Logman([string[]]$arguments) {
    $out = & logman.exe @arguments 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw "logman $($arguments[0]) $($arguments[1]) $($arguments[2]): $(($out | Where-Object { $_ }) -join ' ')" }
    $out
}

function Get-SessionInfo {
    # The running session's output file and events lost so far, or $null when it isn't running
    $out = & logman.exe query $Session -ets 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0 -or -not ($out -match '^Status:\s+Running')) { return $null }
    $file = ($out | Where-Object { $_ -match '^Output Location:\s+(.+)$' } | Select-Object -First 1) -replace '^Output Location:\s+', ''
    $lost = ($out | Where-Object { $_ -match '^Buffers Lost:\s+(\d+)' } | Select-Object -First 1) -replace '^Buffers Lost:\s+', ''
    @{ File = $file.Trim(); BuffersLost = [int]("0$lost".Trim()) }
}

if ($Prepare) {
    # An AutoLogger session: Windows starts it early in the next boot, and it records until it's stopped
    New-Item -ItemType Directory -Force $TraceDir | Out-Null
    & logman.exe delete "autosession\$Session" 2>&1 | Out-Null
    Remove-Item "$TraceDir\boot*.etl" -ErrorAction SilentlyContinue
    Invoke-Logman @('create', 'trace', "autosession\$Session", '-p', $Provider, '0xffffffffffffffff', '5', '-o', "$TraceDir\boot.etl", '-bs', '1024', '-nb', '64', '512') | Out-Null
    Invoke-Logman @('update', 'trace', "autosession\$Session", '-p', $KernelProcess, '0x10', '4', '-o', "$TraceDir\boot.etl") | Out-Null  # (Without -o, update moves the file to the current folder)
    # The targets must find the session signed in, unlocked and awake, and not stop at a UAC prompt for one that asks to be elevated
    # (as a GitHub runner is set up). The VM is thrown away after its scan.
    & powercfg.exe /change monitor-timeout-ac 0
    & powercfg.exe /change standby-timeout-ac 0
    Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name ConsentPromptBehaviorAdmin -Value 0
    Write-Host "The feature trace starts at the next restart ($TraceDir\boot.etl)"
    exit 0
}

if (-not $OutputDir) { throw '-OutputDir is needed' }
New-Item -ItemType Directory -Force $OutputDir, $TraceDir | Out-Null
$OutputDir = (Resolve-Path $OutputDir).Path  # The targets' scheduled task starts in another folder, and .NET resolves paths from its own
$run = [ordered]@{ started = (Now); boot = $false; idleMinutes = $IdleMinutes; targetMinutes = $TargetMinutes }
try {
    $os = Get-CimInstance Win32_OperatingSystem
    $run.lastBoot = $os.LastBootUpTime.ToUniversalTime().ToString('o')
    $info = Get-SessionInfo
    if ($info) {
        $run.boot = $true  # Started by the AutoLogger at boot
        Write-Host "Using the trace that started at boot ($($info.File))"
    } else {
        & logman.exe delete "autosession\$Session" 2>&1 | Out-Null
        Remove-Item "$TraceDir\FeatureUsage*.etl" -ErrorAction SilentlyContinue
        Invoke-Logman @('create', 'trace', $Session, '-p', $Provider, '0xffffffffffffffff', '5', '-o', "$TraceDir\FeatureUsage.etl", '-bs', '1024', '-nb', '64', '512', '-ets') | Out-Null
        Invoke-Logman @('update', 'trace', $Session, '-p', $KernelProcess, '0x10', '4', '-ets') | Out-Null
        $info = Get-SessionInfo
        if (-not $info) { throw 'The trace session did not start' }
        Write-Host "Recording feature checks to $($info.File)"
    }
    # Processes already running (the trace's process start events cover the ones started after)
    Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId, SessionId, Name |
        Export-Csv (Join-Path $OutputDir 'processes.csv') -NoTypeInformation -Encoding UTF8

    $user = (Get-CimInstance Win32_ComputerSystem).UserName
    $shell = $null
    for ($i = 0; $i -lt 60 -and -not $shell; $i++) {
        $shell = Get-CimInstance Win32_Process -Filter "Name = 'explorer.exe'" | Where-Object { $_.SessionId -ne 0 } | Sort-Object CreationDate | Select-Object -First 1
        if (-not $shell) { Start-Sleep -Seconds 10 }
    }
    if (-not $user -or -not $shell) { throw 'Nobody is signed in' }
    $run.user = $user
    $run.session = $shell.SessionId
    $run.signedIn = $shell.CreationDate.ToUniversalTime().ToString('o')
    $idleFrom = if ($run.boot) { $shell.CreationDate } else { Get-Date }
    $wait = ($idleFrom.AddMinutes($IdleMinutes) - (Get-Date)).TotalSeconds
    if ($wait -gt 0) { Write-Host "Leaving Windows alone for $([int]$wait) s"; Start-Sleep -Seconds ([int]$wait) }
    $run.targetsStarted = (Now)

    $targetLog = Join-Path $OutputDir 'targets.csv'
    Remove-Item $targetLog, "$targetLog.error" -ErrorAction SilentlyContinue
    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Targets `"$targetLog`" -TargetMinutes $TargetMinutes"
    if ($SuperGodModeDir -and (Test-Path $SuperGodModeDir)) { $arguments += " -SuperGodModeDir `"$((Resolve-Path $SuperGodModeDir).Path)`"" }
    if (-not $run.boot) { $arguments += ' -RestartShell' }
    $task = 'FeatureTraceTargets'
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $task -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments) -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName $task
    Write-Host "Opening targets as $user (time limit $TargetMinutes min)"
    $deadline = (Get-Date).AddMinutes($TargetMinutes + 10)
    $done = $false
    $reported = Get-Date
    while (-not $done -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 15
        $done = (Test-Path $targetLog) -and [bool](Select-String -Path $targetLog -Pattern '^"end",' -Quiet)
        if (-not $done -and (Get-ScheduledTask -TaskName $task).State -ne 'Running') { break }
        if (-not $done -and ((Get-Date) - $reported).TotalMinutes -ge 3) {
            # How far the targets are, every few minutes: each is in their log once it's closed
            $reported = Get-Date
            try {
                $rows = @(Import-Csv $targetLog -ErrorAction Stop | Where-Object { $_.kind -ne 'start' })
                $failed = @($rows | Where-Object { $_.error }).Count
                if ($rows) { Write-Host "Targets opened so far: $($rows.Count)$(if ($failed) { " ($failed with an error)" }); the latest: $($rows[-1].kind) $($rows[-1].label)" }
            } catch { }  # (Being written to just then)
        }
    }
    if (-not $done) {
        $why = Get-Content "$targetLog.error" -Raw -ErrorAction SilentlyContinue
        $run.error = if ($why) { "The targets did not finish: $($why.Trim())" } else { 'The targets did not finish' }
        Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
    }
    $task = Get-ScheduledTaskInfo -TaskName $task -ErrorAction SilentlyContinue
    if ($task) { $run.targetsResult = $task.LastTaskResult }
    Unregister-ScheduledTask -TaskName 'FeatureTraceTargets' -Confirm:$false -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5

    $info = Get-SessionInfo
    $run.buffersLost = if ($info) { $info.BuffersLost } else { $null }
    Invoke-Logman @('stop', $Session, '-ets') | Out-Null
    $run.stopped = (Now)
    & logman.exe delete "autosession\$Session" 2>&1 | Out-Null
    Write-Host 'Decoding the trace'
    $xml = Join-Path $OutputDir 'events.xml'
    $out = & tracerpt.exe $info.File -o $xml -of XML -summary (Join-Path $OutputDir 'tracerpt-summary.txt') -y 2>&1 | ForEach-Object { "$_" }
    if (-not (Test-Path $xml)) { throw "tracerpt wrote nothing: $($out -join ' ')" }
} catch {
    $run.error = $_.Exception.Message
    & logman.exe stop $Session -ets 2>&1 | Out-Null
    & logman.exe delete "autosession\$Session" 2>&1 | Out-Null
}
if ($run.error) {
    Write-Warning "Feature trace: $($run.error)"
    if ($env:GITHUB_ACTIONS -eq 'true') { Write-Host "::warning::Feature trace: $($run.error)" }
}
[IO.File]::WriteAllText((Join-Path $OutputDir 'run.json'), ($run | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false))

$xml = Join-Path $OutputDir 'events.xml'
if (Test-Path $xml) {
    & $Python (Join-Path $PSScriptRoot 'summarize-trace.py') $OutputDir
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "summarize-trace.py failed ($LASTEXITCODE)"
    } else {
        # The decoded events are several times the size of the trace, which can make them again (tracerpt)
        Copy-Item $info.File (Join-Path $OutputDir 'FeatureUsage.etl') -Force
        Remove-Item $xml
    }
}
exit 0
