# scan-in-vm.ps1
# Builds a Windows 11 virtual machine at a chosen build, entirely from Microsoft's own servers, and runs the feature scan inside it.
# Used by the VM scanner workflow on an x64 runner, which can run Hyper-V virtual machines.
#
#   1. Base image: the newest Windows 11 image the Media Creation Tool offers (its catalog, products.cab, lists the image files on Microsoft's servers).
#      It's applied to a virtual disk, and the VM boots from it without the setup screens (unattend.xml).
#   2. The target cumulative update, from the Microsoft Update Catalog, is installed inside the running VM with DISM, the way Microsoft
#      documents for cumulative updates that come with checkpoint updates. Windows 11 24H2, 25H2 and 26H2 share their code and their
#      cumulative updates; only the version's enablement package differs.
#   3. Windows Update installs the enablement package of the target version, chosen with Windows Update's own target release version policy.
#   4. The scanner runs inside the VM, the same way the regular workflow runs it on the runner, and its output is copied back.
#
# Steps can be run one at a time with -Step, which is how it was developed and tested.

param(
    [string]$Version = '26H2',             # Target Windows 11 version (enablement package)
    [string]$Kb,                           # Target cumulative update, such as KB5127936
    [string]$ExpectedBuild,                # Fail before scanning unless the VM ends up at this build (such as 26300.9818)
    [string]$Edition = 'Enterprise',       # Edition to install from the image
    [string]$WorkDir = 'D:\vmscan',        # Needs about 60 GB: the image and the virtual disk
    [string]$VmName = 'FeatureScan',
    [int]$VmMemoryGB = 0,                  # 0: what the runner can spare (its free memory less 3 GB), from 4 to 12 GB
    [string]$RepoDir = $PSScriptRoot,      # The scanner's files, copied into the VM
    [string]$OutputDir,                    # Where the scan output is copied back to (default: <WorkDir>\output)
    [ValidateSet('All', 'Image', 'Download', 'Disk', 'VM', 'Install', 'FeatureUpdate', 'Scan')]
    [string]$Step = 'All'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (-not $OutputDir) { $OutputDir = Join-Path $WorkDir 'output' }
New-Item -ItemType Directory -Force $WorkDir, $OutputDir | Out-Null

function Log([string]$msg) { Write-Host ("[vm {0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) }

# ---------------------------------------------------------------------------
# Downloads from Microsoft
# ---------------------------------------------------------------------------

function Save-Url([string]$url, [string]$path) {
    # BITS isn't available in every session, and Invoke-WebRequest is slow for large files on Windows PowerShell, so use curl.exe (part of Windows)
    & curl.exe -fsSL --retry 5 --retry-delay 5 -o $path $url
    if ($LASTEXITCODE -ne 0) { throw "Download failed ($LASTEXITCODE): $url" }
}

function Get-BaseImage {
    # The Media Creation Tool's catalog lists every image file it can download, with its hashes
    $cab = Join-Path $WorkDir 'products.cab'
    Save-Url 'https://go.microsoft.com/fwlink/?LinkId=2156292' $cab
    $xmlDir = Join-Path $WorkDir 'products'
    New-Item -ItemType Directory -Force $xmlDir | Out-Null
    & expand.exe $cab -F:products.xml $xmlDir | Out-Null
    $xmlFile = Get-ChildItem $xmlDir -File | Select-Object -First 1
    [xml]$catalog = Get-Content $xmlFile.FullName
    $file = $catalog.MCT.Catalogs.Catalog.PublishedMedia.Files.File |
        Where-Object { $_.LanguageCode -eq 'en-us' -and $_.Architecture -eq 'x64' -and $_.Edition -eq $Edition } | Select-Object -First 1
    if (-not $file) { throw "The Media Creation Tool catalog has no en-us x64 image with the $Edition edition" }
    $esd = Join-Path $WorkDir $file.FileName
    if (-not (Test-Path $esd) -or (Get-FileHash $esd -Algorithm SHA1).Hash -ne $file.Sha1.ToUpper()) {
        Log "Downloading $($file.FileName) ($([math]::Round([double]$file.Size / 1GB, 1)) GB)"
        Save-Url $file.FilePath $esd
        $hash = (Get-FileHash $esd -Algorithm SHA1).Hash
        if ($hash -ne $file.Sha1.ToUpper()) { throw "SHA1 mismatch for $esd" }
    }
    Log "Base image: $($file.FileName)"
    return $esd
}

function Search-UpdateCatalog([string]$query) {
    # The same requests the Microsoft Update Catalog website makes (see Install-Store-Apps.ps1 in ThioJoe/Windows-Sandbox-Tools)
    $html = (Invoke-WebRequest -Uri "https://www.catalog.update.microsoft.com/Search.aspx?q=$([uri]::EscapeDataString($query))" -UseBasicParsing -Headers @{ 'Accept-Language' = 'en-US' }).Content
    $table = [regex]::Match($html, '(?s)<table[^>]*id="ctl00_catalogBody_updateMatches"[^>]*>(.*?)</table>').Groups[1].Value
    foreach ($row in [regex]::Matches($table, '(?s)<tr[^>]*>(.*?)</tr>')) {
        if ($row.Value -match 'id="headerRow"') { continue }
        $cells = @([regex]::Matches($row.Groups[1].Value, '(?s)<td[^>]*>(.*?)</td>') | ForEach-Object {
            ([System.Net.WebUtility]::HtmlDecode(($_.Groups[1].Value -replace '<[^>]+>', ' ')) -replace '\s+', ' ').Trim() })
        if ($cells.Count -lt 8) { continue }
        [PSCustomObject]@{ Title = $cells[1]; LastUpdated = $cells[4]; Id = [regex]::Match($row.Groups[1].Value, '<input[^>]*id="([0-9a-fA-F-]{36})"').Groups[1].Value }
    }
}

function Get-UpdateCatalogLinks([string]$updateId) {
    $body = @{ updateIDs = "[{`"size`":0,`"updateID`":`"$updateId`",`"uidInfo`":`"$updateId`"}]" }
    $dialog = (Invoke-WebRequest -Uri 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' -Method Post -Body $body -UseBasicParsing).Content
    [regex]::Matches($dialog, "https?://(?:[a-z0-9.-]+\.)?(?:download\.windowsupdate\.com|delivery\.mp\.microsoft\.com)/[^'`"\s]+") | ForEach-Object { $_.Value } | Select-Object -Unique
}

function Get-CumulativeUpdate {
    # The download links of the target cumulative update's files. The same files serve 24H2, 25H2 and 26H2; take the entry for the target version.
    $entry = Search-UpdateCatalog $Kb | Where-Object { $_.Title -match 'x64-based' -and $_.Title -match "version $Version" } | Select-Object -First 1
    if (-not $entry) { throw "No x64 $Version entry for $Kb in the Microsoft Update Catalog" }
    Log "Update: $($entry.Title)"
    # Since 24H2, a cumulative update can come with "checkpoint" updates that have to be installed first; the download dialog lists them all
    $urls = @(Get-UpdateCatalogLinks $entry.Id)
    if (-not $urls) { throw "The Microsoft Update Catalog lists no files for $Kb" }
    foreach ($url in $urls) {
        if ($url -notmatch '^https?://[A-Za-z0-9./_-]+$') { throw "Unexpected download link: $url" }
        Log "File: $url"
    }
    return $urls
}

# ---------------------------------------------------------------------------
# Virtual disk
# ---------------------------------------------------------------------------

function New-ScanDisk([string]$esd) {
    $vhd = Join-Path $WorkDir "$VmName.vhdx"
    if (Get-VM -Name $VmName -ErrorAction SilentlyContinue) { Stop-VM -Name $VmName -TurnOff -Force -ErrorAction SilentlyContinue; Remove-VM -Name $VmName -Force }
    if (Test-Path $vhd) { Dismount-VHD -Path $vhd -ErrorAction SilentlyContinue; Remove-Item $vhd -Force }
    Log "Creating $vhd"
    New-VHD -Path $vhd -SizeBytes 127GB -Dynamic | Out-Null
    $disk = Mount-VHD -Path $vhd -Passthru | Get-Disk
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT
    $efi = New-Partition -DiskNumber $disk.Number -Size 260MB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -AssignDriveLetter
    Format-Volume -Partition $efi -FileSystem FAT32 -NewFileSystemLabel 'System' -Confirm:$false | Out-Null
    New-Partition -DiskNumber $disk.Number -Size 16MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' | Out-Null
    $win = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
    Format-Volume -Partition $win -FileSystem NTFS -NewFileSystemLabel 'Windows' -Confirm:$false | Out-Null
    $efiRoot = "$($efi.DriveLetter):\"
    $winRoot = "$($win.DriveLetter):\"

    $index = (Get-WindowsImage -ImagePath $esd | Where-Object { $_.ImageName -eq "Windows 11 $Edition" }).ImageIndex
    if (-not $index) { throw "No 'Windows 11 $Edition' image in $esd" }
    Log "Applying image index $index to $winRoot"
    & dism.exe /English /Apply-Image "/ImageFile:$esd" "/Index:$index" "/ApplyDir:$winRoot" | Select-Object -Last 2
    if ($LASTEXITCODE -ne 0) { throw "DISM /Apply-Image failed ($LASTEXITCODE)" }

    & bcdboot.exe "$($winRoot)Windows" /s $efiRoot /f UEFI | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "bcdboot failed ($LASTEXITCODE)" }
    Write-Unattend $winRoot
    $reg = "HKLM\OFFLINE_SOFTWARE"
    & reg.exe load $reg "$($winRoot)Windows\System32\config\SOFTWARE" | Out-Null
    # Group Policy 'Configure Automatic Updates: Disabled', so Windows Update only installs what this script asks it for (the enablement
    # package), and doesn't spend the VM's disk on an automatic scan meanwhile
    & reg.exe add "$reg\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /t REG_DWORD /d 1 /f | Out-Null
    $build = (& reg.exe query "$reg\Microsoft\Windows NT\CurrentVersion" /v CurrentBuildNumber | Select-String 'REG_SZ\s+(\S+)').Matches.Groups[1].Value
    $ubr = [Convert]::ToInt32((& reg.exe query "$reg\Microsoft\Windows NT\CurrentVersion" /v UBR | Select-String 'REG_DWORD\s+(\S+)').Matches.Groups[1].Value, 16)
    [gc]::Collect()
    & reg.exe unload $reg | Out-Null
    Log "Base image build: $build.$ubr"
    Dismount-VHD -Path $vhd
    return $vhd
}

function Get-VmPassword {
    # A random password for the VM's local account, kept in the work folder so separate steps can sign in. The VM is thrown away with the runner.
    $file = Join-Path $WorkDir 'vm-password.txt'
    if (-not (Test-Path $file)) {
        $chars = [char[]]'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
        $bytes = New-Object byte[] 20
        [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        Set-Content $file (-join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] }) + '#9a')
    }
    return (Get-Content $file -Raw).Trim()
}

function Get-VmCredential {
    New-Object System.Management.Automation.PSCredential('scan', (ConvertTo-SecureString (Get-VmPassword) -AsPlainText -Force))
}

function Write-Unattend([string]$winRoot) {
    # Skips the setup screens on first boot: a local administrator account 'scan' that signs in automatically, English (US), UTC
    $password = [Security.SecurityElement]::Escape((Get-VmPassword))
    $intl = '<component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"><InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale></component>'
    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>FEATURESCAN</ComputerName>
      <TimeZone>UTC</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    $intl
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>scan</Name>
            <Group>Administrators</Group>
            <Password><Value>$password</Value><PlainText>true</PlainText></Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>scan</Username>
        <Password><Value>$password</Value><PlainText>true</PlainText></Password>
        <LogonCount>9999</LogonCount>
      </AutoLogon>
    </component>
  </settings>
</unattend>
"@
    $panther = Join-Path $winRoot 'Windows\Panther'
    New-Item -ItemType Directory -Force $panther | Out-Null
    Set-Content -Path (Join-Path $panther 'unattend.xml') -Value $xml -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Virtual machine
# ---------------------------------------------------------------------------

$NatPrefix = '192.168.77'

function Initialize-NatNetwork {
    # An internal switch with NAT gives the VM internet access through the runner, without a DHCP server: the VM gets a fixed address
    if (-not (Get-VMSwitch -Name ScanNAT -ErrorAction SilentlyContinue)) { New-VMSwitch -Name ScanNAT -SwitchType Internal | Out-Null }
    $adapter = Get-NetAdapter -Name 'vEthernet (ScanNAT)'
    if (-not (Get-NetIPAddress -IPAddress "$NatPrefix.1" -ErrorAction SilentlyContinue)) {
        New-NetIPAddress -IPAddress "$NatPrefix.1" -PrefixLength 24 -InterfaceIndex $adapter.ifIndex | Out-Null
    }
    if (-not (Get-NetNat -Name ScanNAT -ErrorAction SilentlyContinue)) { New-NetNat -Name ScanNAT -InternalIPInterfaceAddressPrefix "$NatPrefix.0/24" | Out-Null }
}

function Start-ScanVM {
    $vhd = Join-Path $WorkDir "$VmName.vhdx"
    Initialize-NatNetwork
    $memoryGB = $VmMemoryGB
    if (-not $memoryGB) {
        # Hyper-V needs some memory of its own on top of the VM's, and a 16 GB runner has about 13 GB free
        $freeGB = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB
        $memoryGB = [int][Math]::Max(4, [Math]::Min(12, [Math]::Floor($freeGB - 3)))
    }
    if (-not (Get-VM -Name $VmName -ErrorAction SilentlyContinue)) {
        Log "Creating VM $VmName ($memoryGB GB of memory)"
        New-VM -Name $VmName -Generation 2 -MemoryStartupBytes ($memoryGB * 1GB) -VHDPath $vhd -SwitchName ScanNAT | Out-Null
        Set-VM -Name $VmName -ProcessorCount ([Math]::Max(2, [Environment]::ProcessorCount)) -StaticMemory -AutomaticCheckpointsEnabled $false
        Set-VMFirmware -VMName $VmName -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
        try {
            Set-VMKeyProtector -VMName $VmName -NewLocalKeyProtector
            Enable-VMTPM -VMName $VmName
        } catch { Log "No virtual TPM: $($_.Exception.Message)" }
        Enable-VMIntegrationService -VMName $VmName -Name 'Guest Service Interface'
    }
    if ((Get-VM -Name $VmName).State -eq 'Off') {
        Set-VMMemory -VMName $VmName -StartupBytes ($memoryGB * 1GB)
        Start-VM -Name $VmName
    }
}

function Wait-ScanVM([int]$timeoutMinutes = 40) {
    # PowerShell Direct talks to the VM over the virtual machine bus, so it works before the VM has a network
    $deadline = (Get-Date).AddMinutes($timeoutMinutes)
    $cred = Get-VmCredential
    while ((Get-Date) -lt $deadline) {
        try {
            $s = New-PSSession -VMName $VmName -Credential $cred -ErrorAction Stop
            Log 'VM is up (PowerShell Direct connected)'
            return $s
        } catch { Start-Sleep -Seconds 15 }
    }
    throw "The VM didn't come up within $timeoutMinutes minutes"
}

$script:VmSession = $null

function Get-VmSession {
    # The PowerShell Direct session to the VM, reconnected when it broke: installing an update can restart the VM's side of
    # PowerShell Direct (one of its integration services), which ends the session
    $s = $script:VmSession
    if ($s -and $s.State -eq 'Opened') { return $s }
    if ($s) {
        Log "Reconnecting to the VM (the session is $($s.State))"
        Remove-PSSession $s -ErrorAction SilentlyContinue
    }
    $script:VmSession = Wait-ScanVM 30
    return $script:VmSession
}

function Close-VmSession {
    if ($script:VmSession) { Remove-PSSession $script:VmSession -ErrorAction SilentlyContinue }
    $script:VmSession = $null
}

function Invoke-InVM([scriptblock]$block, [object[]]$arguments = @(), [switch]$Retry) {
    # Runs a script block in the VM. With -Retry, for blocks that can safely run twice, a session that breaks meanwhile is reconnected
    # and the block run again; an error from the block itself is never retried.
    for ($attempt = 1; ; $attempt++) {
        $s = Get-VmSession
        try {
            return Invoke-Command -Session $s -ScriptBlock $block -ArgumentList $arguments -ErrorAction Stop
        } catch {
            if (-not $Retry -or $s.State -eq 'Opened' -or $attempt -ge 6) { throw }
            Log "Lost the PowerShell Direct session ($($_.Exception.Message.Trim())); trying again"
            Start-Sleep -Seconds 20
        }
    }
}

function Set-VmNetwork {
    $dns = @((Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike '*ScanNAT*' -and $_.ServerAddresses }).ServerAddresses | Select-Object -Unique) + '1.1.1.1'
    Invoke-InVM -Retry -arguments $NatPrefix, $dns {
        param($prefix, $dns)
        $adapter = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
        if (-not (Get-NetIPAddress -IPAddress "$prefix.10" -ErrorAction SilentlyContinue)) {
            New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress "$prefix.10" -PrefixLength 24 -DefaultGateway "$prefix.1" | Out-Null
        }
        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $dns
        $ok = $false
        for ($i = 0; $i -lt 24 -and -not $ok; $i++) {  # A new address takes a few seconds to become usable
            $ok = Test-NetConnection -ComputerName www.microsoft.com -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue
            if (-not $ok) { Start-Sleep -Seconds 5 }
        }
        if (-not $ok) { throw "The VM can't reach www.microsoft.com through the runner (address $prefix.10, DNS $($dns -join ', '))" }
        "VM network: $prefix.10, DNS $($dns -join ', ')"
    } | ForEach-Object { Log $_ }
}

function Get-VmBuild {
    Invoke-InVM -Retry {
        $r = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        "$($r.CurrentBuildNumber).$($r.UBR) $($r.DisplayVersion) $($r.EditionID)"
    }
}

function Restart-ScanVM {
    # Restarted from inside, so Windows finishes installing updates the way it does on any PC. Installing a cumulative update can take
    # more than one restart (Windows' servicing restarts the VM again by itself, even after it has signed in), so this waits until the
    # VM has stayed up for a couple of minutes with no restart pending.
    Log 'Restarting the VM'
    $before = Invoke-InVM -Retry { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime }
    try { Invoke-InVM { Restart-Computer -Force } } catch { }
    Close-VmSession
    $deadline = (Get-Date).AddMinutes(90)
    $lastBoot = $before
    $stable = 0
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 30
        try {
            $state = Invoke-InVM {
                $cbs = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing'
                @{ Boot = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
                   Pending = (Test-Path "$cbs\RebootPending") -or (Test-Path "$cbs\RebootInProgress") -or (Test-Path "$cbs\PackagesPending") }
            }
        } catch {
            # Shutting down, or not up yet. Until the VM has shut down, this can still reach the instance from before the restart.
            Close-VmSession
            $stable = 0
            continue
        }
        if ($state.Boot -le $before -or $state.Boot -ne $lastBoot -or $state.Pending) {
            $lastBoot = $state.Boot
            $stable = 0
            continue
        }
        $stable++
        if ($stable -ge 4) {
            Log "The VM is up again (since $($state.Boot))"
            return
        }
    }
    throw "The VM didn't finish restarting within 90 minutes"
}

function Invoke-VmTask([string]$name, [string]$script, [int]$timeoutMinutes = 60) {
    # Runs a script inside the VM as a SYSTEM scheduled task, shows its log as it grows, and returns what it passed to Write-Result.
    # Windows Update refuses to download or install from a remote session (PowerShell Direct is one), and long installs and the scan
    # are better off not depending on one either. The script gets two functions: Write-Log (a line in its log) and Write-Result.
    $preamble = @'
$log = 'C:\scan-tasks\__NAME__.log'
function Write-Log([string]$line) {
    for ($i = 0; $i -lt 50; $i++) { try { [IO.File]::AppendAllText($log, $line + "`r`n"); return } catch { Start-Sleep -Milliseconds 200 } }
}
function Write-Result([string]$value) { Write-Log "result: $value"; Set-Content 'C:\scan-tasks\__NAME__.result' $value }
'@.Replace('__NAME__', $name)
    Invoke-InVM -arguments $name, ($preamble + "`r`n" + $script) {
        param($name, $script)
        New-Item -ItemType Directory -Force C:\scan-tasks | Out-Null
        Set-Content "C:\scan-tasks\$name.ps1" $script
        Remove-Item "C:\scan-tasks\$name.log", "C:\scan-tasks\$name.result" -ErrorAction SilentlyContinue
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File C:\scan-tasks\$name.ps1"
        Register-ScheduledTask -TaskName $name -Action $action -User 'NT AUTHORITY\SYSTEM' -RunLevel Highest -Force | Out-Null
        Start-ScheduledTask -TaskName $name
    }
    $deadline = (Get-Date).AddMinutes($timeoutMinutes)
    $shown = 0
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 30
        $state = Invoke-InVM -Retry -arguments $name {
            param($name)
            $done = Test-Path "C:\scan-tasks\$name.result"
            @{ Log = @(Get-Content "C:\scan-tasks\$name.log" -ErrorAction SilentlyContinue)
               Done = $done
               Result = if ($done) { [string](Get-Content "C:\scan-tasks\$name.result" -Raw) } else { '' }
               Running = try { (Get-ScheduledTask -TaskName $name -ErrorAction Stop).State -eq 'Running' } catch { $true } }  # Unknown while the task service is unavailable
        }
        $state.Log | Select-Object -Skip $shown | ForEach-Object { Log "${name}: $_" }
        $shown = [Math]::Max($shown, $state.Log.Count)
        if ($state.Done) { return $state.Result.Trim() }
        if (-not $state.Running) { throw "$name stopped without a result" }
    }
    throw "$name didn't finish within $timeoutMinutes minutes"
}

function Install-CumulativeUpdate([string[]]$urls) {
    # The VM downloads the update's files from Microsoft itself (copying them in through PowerShell Direct is much slower). As Microsoft
    # documents for updates that come with checkpoint updates, DISM is given the update itself; it finds the checkpoint updates in the
    # same folder and installs the ones the VM still needs. (Given the whole folder, it tries all of them, and one that is older than
    # the base image fails to install.) DISM also checks the files' signatures.
    $result = Invoke-VmTask 'ScanLCU' -timeoutMinutes 150 -script (@'
New-Item -ItemType Directory -Force C:\scan-updates | Out-Null
foreach ($url in @(__URLS__)) {
    $name = [IO.Path]::GetFileName(([uri]$url).AbsolutePath)
    $path = Join-Path C:\scan-updates $name
    Write-Log "downloading $name"
    & curl.exe -fsSL --retry 5 --retry-delay 5 -o $path $url
    if ($LASTEXITCODE -ne 0) { Write-Result "download failed (curl $LASTEXITCODE): $url"; return }
}
$target = Get-ChildItem C:\scan-updates -Filter '*-__KB__-*.msu' | Select-Object -First 1
if (-not $target) { Write-Result 'none of the downloaded files is __KB__ itself'; return }
Write-Log "installing $($target.Name) with DISM"
& dism.exe /English /Online /Add-Package "/PackagePath:$($target.FullName)" /NoRestart | Select-Object -Last 4 | ForEach-Object { Write-Log $_ }
Write-Result $LASTEXITCODE
'@).Replace('__URLS__', (($urls | ForEach-Object { "'$_'" }) -join ', ')).Replace('__KB__', $Kb.ToLower())
    if ($result -notin '0', '3010') { throw "Installing the cumulative update failed: $result" }  # 3010: done, restart needed
    Invoke-InVM -Retry { Remove-Item C:\scan-updates -Recurse -Force -ErrorAction SilentlyContinue }
}

function Install-TargetVersion {
    # Windows Update's target release version policy makes it offer that version's enablement package as the feature update
    Invoke-InVM -Retry -arguments $Version {
        param($version)
        $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
        New-Item -Path $policy -Force | Out-Null
        Set-ItemProperty $policy -Name ProductVersion -Value 'Windows 11'
        Set-ItemProperty $policy -Name TargetReleaseVersion -Value 1 -Type DWord
        Set-ItemProperty $policy -Name TargetReleaseVersionInfo -Value $version
    }
    $result = Invoke-VmTask 'ScanWU' -timeoutMinutes 60 -script (@'
Write-Log 'searching Windows Update'
try {
    $session = New-Object -ComObject Microsoft.Update.Session
    $found = $session.CreateUpdateSearcher().Search("IsInstalled=0 and Type='Software'").Updates
    $wanted = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $found) {
        Write-Log "offered: $($u.Title)"
        # Offered as "Windows 11, version 26H2" (or "Feature update to Windows 11, version 26H2", or as an enablement package)
        if ($u.Title -match '^(Feature update to )?Windows 11, version __VERSION__\b|__VERSION__.*Enablement') {
            if (-not $u.EulaAccepted) { $u.AcceptEula() }
            [void]$wanted.Add($u)
        }
    }
    if ($wanted.Count -eq 0) { Write-Result 'nothing to install'; return }
    $dl = $session.CreateUpdateDownloader(); $dl.Updates = $wanted; $d = $dl.Download()
    Write-Log "download result: $($d.ResultCode)"
    $inst = $session.CreateUpdateInstaller(); $inst.Updates = $wanted; $i = $inst.Install()
    Write-Result "installed $($i.ResultCode), reboot required: $($i.RebootRequired)"
} catch { Write-Result "error $($_.Exception.Message)" }
'@).Replace('__VERSION__', $Version)
    if ($result -notmatch '^installed 2') { throw "Windows Update didn't install the $Version enablement package: $result" }  # 2 = succeeded
    return ($result -match 'reboot required: True')
}

# ---------------------------------------------------------------------------
# Scan inside the VM
# ---------------------------------------------------------------------------

function Copy-ToVM([string]$path, [string]$destination) {
    # Copy-VMFile goes through the VM's guest service interface, which is much faster than a PowerShell Direct session (about 3 MB/s)
    try {
        Copy-VMFile -Name $VmName -SourcePath $path -DestinationPath $destination -CreateFullPath -FileSource Host -Force
    } catch {
        Log "Copy-VMFile failed ($($_.Exception.Message)); copying through PowerShell Direct instead"
        Copy-Item -ToSession (Get-VmSession) -Path $path -Destination $destination -Force
    }
}

function Invoke-ScanInVM([string]$resultsCache) {
    # The VM gets the runner's Python and the scanner's files; the scan then runs the way the regular workflow runs it on the runner.
    # Python goes in as one zip with what the scanner needs: the interpreter and the standard library, without tests, Tcl/Tk, IDLE,
    # installed packages and the like (6,000 files otherwise).
    $python = Split-Path -Parent (Get-Command python.exe).Source
    $stage = Join-Path $WorkDir 'python-stage'
    $zip = Join-Path $WorkDir 'python.zip'
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    & robocopy.exe $python $stage /E /NFL /NDL /NJH /NJS /NP /XD test tests idlelib tkinter turtledemo tcl site-packages ensurepip __pycache__ Doc include libs Scripts | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Copying Python failed (robocopy exit code $LASTEXITCODE)" }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip)
    Log ("Copying Python ({0} from {1}, {2:N0} MB zipped) and the scanner into the VM" -f (& "$python\python.exe" --version), $python, ((Get-Item $zip).Length / 1MB))
    Invoke-InVM -Retry { Remove-Item C:\scan -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force C:\scan | Out-Null }
    Copy-ToVM $zip 'C:\scan\python.zip'
    Invoke-InVM {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory('C:\scan\python.zip', 'C:\scan\python')
        Remove-Item C:\scan\python.zip
    }
    foreach ($f in 'scan-symbols.py', 'scan-features.ps1', 'download-vivetool.ps1') {
        Copy-Item -ToSession (Get-VmSession) -Path (Join-Path $RepoDir $f) -Destination C:\scan\ -Force
    }
    if ($resultsCache -and (Test-Path $resultsCache)) { Copy-ToVM $resultsCache 'C:\scan\symbol-cache.json' }

    Log 'Running the scan inside the VM'
    $result = Invoke-VmTask 'ScanFeatures' -timeoutMinutes 240 -script @'
try {
    Set-Location C:\scan
    $env:PATH = "C:\scan\python;C:\scan\python\Scripts;$env:PATH"
    & .\download-vivetool.ps1 *>&1 | Select-Object -Last 2 | ForEach-Object { Write-Log "$_" }
    & python.exe scan-symbols.py --results-cache symbol-cache.json --names-out extracted-names.txt --json-out symbol-features.json 2>&1 | ForEach-Object { Write-Log "$_" }
    if ($LASTEXITCODE -ne 0) { throw "scan-symbols.py failed ($LASTEXITCODE)" }
    & .\scan-features.ps1 *>&1 | Select-Object -Last 5 | ForEach-Object { Write-Log "$_" }
    if (-not (Test-Path C:\scan\output-temp\summary.json)) { throw 'scan-features.ps1 wrote no summary.json' }
    Write-Result 'ok'
} catch { Write-Result "error $($_.Exception.Message)" }
'@
    if ($result -ne 'ok') { throw "The scan inside the VM failed: $result" }

    Log "Copying the results to $OutputDir"
    $s = Get-VmSession
    Copy-Item -FromSession $s -Path C:\scan\output-temp\* -Destination $OutputDir -Recurse -Force
    foreach ($f in 'symbol-features.json', 'extracted-names.txt') { Copy-Item -FromSession $s -Path "C:\scan\$f" -Destination $OutputDir -Force }
    if ($resultsCache) { Copy-Item -FromSession $s -Path C:\scan\symbol-cache.json -Destination $resultsCache -Force }
}

# ---------------------------------------------------------------------------

$esd = $null; $updateUrls = $null
if ($Step -in 'All', 'Image', 'Disk') { $esd = Get-BaseImage }
if ($Step -in 'All', 'Download', 'Install' -and $Kb) { $updateUrls = Get-CumulativeUpdate }  # A version's first release can be its enablement package alone
if ($Step -in 'All', 'Disk') { New-ScanDisk $esd | Out-Null }
if ($Step -in 'All', 'VM', 'Install', 'FeatureUpdate', 'Scan') {
    Start-ScanVM
    $script:VmSession = Wait-ScanVM
    Set-VmNetwork
    Log "VM build: $(Get-VmBuild)"
}
if ($Step -in 'All', 'Install' -and $updateUrls) {
    Install-CumulativeUpdate $updateUrls
    Restart-ScanVM
    Set-VmNetwork
    Log "VM build after the cumulative update: $(Get-VmBuild)"
}
if ($Step -in 'All', 'FeatureUpdate') {
    if (Install-TargetVersion) {
        Restart-ScanVM
        Set-VmNetwork
    }
    Log "VM build after the feature update: $(Get-VmBuild)"
}
if ($Step -in 'All', 'Scan') {
    $build = (Get-VmBuild).Split(' ')[0]
    if ($ExpectedBuild -and $build -ne $ExpectedBuild) { throw "The VM is at build $build, not $ExpectedBuild" }
    Invoke-ScanInVM (Join-Path $RepoDir 'data\symbol-cache-AMD64.json')
}
Log "Done: $Step"
