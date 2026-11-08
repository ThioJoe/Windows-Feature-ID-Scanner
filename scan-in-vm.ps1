# scan-in-vm.ps1
# Builds a Windows 11 virtual machine at a chosen build, entirely from Microsoft's own servers, and runs the feature scan inside it.
# Used by the VM scanner workflow on an x64 runner, which can run Hyper-V virtual machines.
#
#   1. Base image: the newest Windows 11 image from the Media Creation Tool's catalogs (products.cab, which lists the image files on
#      Microsoft's servers with their hashes) that the target version can be reached from. The tool's link still points to a 24H2
#      catalog from June 2025; the tool then asks Windows Update's metadata service for the current one, as this script does too.
#      The image is applied to a virtual disk, and the VM boots from it without the setup screens (unattend.xml).
#   2. The target cumulative update, from the Microsoft Update Catalog, is installed inside the running VM with DISM, the way Microsoft
#      documents for cumulative updates that come with checkpoint updates. Windows 11 24H2, 25H2 and 26H2 share their code and their
#      cumulative updates; only the version's enablement package differs.
#   3. Unless the image is that version already, Windows Update installs the enablement package of the target version, chosen with
#      Windows Update's own target release version policy.
#      A Windows Insider build (-InsiderChannel) has no cumulative update or enablement package in the catalog: Windows Update installs
#      it instead once the VM is configured to receive that channel's updates (Install-InsiderBuild). The setup function,
#      Register-InsiderDevice, is unfinished, so Insider scans aren't enabled yet.
#   4. Windows Update installs whatever else it offers that doesn't change the build, and the Microsoft Store updates the apps that
#      come with Windows (cumulative updates don't). What still can't be installed after retries is noted in the build's data.
#   5. After a last restart, the VM is checked against what the build is supposed to be (Test-VmInstallation): Windows' servicing,
#      DISM /ScanHealth, sfc /verifyonly and the installed files against Microsoft's file lists (verify-windows-files.py). If a check
#      fails, the run stops before the scan.
#   6. The scanner runs inside the VM, the same way the regular workflow runs it on the runner, then Super God Mode
#      (run-super-god-mode.ps1) as the VM's own user, and their output is copied back.
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
    [string]$BaseImage,                    # Start from the catalog's image of this build (such as 26100.4349) instead of the newest one that fits
    [string]$InsiderChannel,               # Install the newest build of this Windows Insider channel (such as Beta) instead of -Kb and -Version
    [string]$InsiderDevice = $env:INSIDER_DEVICE,  # Placeholder for device/account information if the chosen Insider setup approach needs it (empty for now)
    [ValidateSet('All', 'Image', 'Download', 'Disk', 'VM', 'Install', 'FeatureUpdate', 'Updates', 'Apps', 'Verify', 'Scan')]
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

function Get-ProductsCatalogs {
    # The Media Creation Tool's catalogs, products.cab. Its link (fwlink 2156292) still gives the June 2025 24H2 catalog; the tool then
    # asks Windows Update's metadata service for the product Windows.Products.Cab.amd64 and uses the newer catalog that comes back
    # (seen by tracing the tool; the request is the one its SetupMgr.dll and udiapi.dll make). Both are returned, so an older
    # version can still start from the older image.
    $cabs = @()
    $cab = Join-Path $WorkDir 'products-fwlink.cab'
    Save-Url 'https://go.microsoft.com/fwlink/?LinkId=2156292' $cab
    $cabs += $cab
    try {
        $body = @{ Products = 'PN=Windows.Products.Cab.amd64&Branch=ge_release&V=26100.0.0.0'; DeviceAttributes = 'DUScan=1;OSVersion=10.0.26100.1' } | ConvertTo-Json -Compress
        $found = Invoke-RestMethod -Uri 'https://fe3.delivery.mp.microsoft.com/UpdateMetadataService/updates/search/v1/bydeviceinfo' -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 120
        $file = @($found)[0].FileLocations | Where-Object { $_.FileName -eq 'products.cab' } | Select-Object -First 1
        if (-not $file) { throw 'no products.cab in the response' }
        $cab = Join-Path $WorkDir 'products-wu.cab'
        Save-Url $file.Url $cab
        $sha = New-Object Security.Cryptography.SHA256Managed
        $digest = [Convert]::ToBase64String($sha.ComputeHash([IO.File]::ReadAllBytes($cab)))
        if ($digest -ne $file.Digest) { throw "SHA-256 mismatch ($digest, expected $($file.Digest))" }
        $cabs += $cab
    } catch { Log "Couldn't get the current catalog from Windows Update ($($_.Exception.Message)); using the older one only" }
    return $cabs
}

function Get-BaseImage {
    # Every image file in the catalogs, with its hash; the newest image whose base build isn't past the target version's (an image of
    # 26H2, base build 26300, can't become 25H2, 26200, while a 24H2 one, 26100, can become either)
    $images = @()
    foreach ($cab in Get-ProductsCatalogs) {
        $xmlDir = Join-Path $WorkDir ([IO.Path]::GetFileNameWithoutExtension($cab))
        Remove-Item $xmlDir -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force $xmlDir | Out-Null
        & expand.exe $cab -F:products.xml $xmlDir | Out-Null
        [xml]$catalog = Get-Content (Get-ChildItem $xmlDir -File | Select-Object -First 1).FullName
        $images += $catalog.MCT.Catalogs.Catalog.PublishedMedia.Files.File |
            Where-Object { $_.LanguageCode -eq 'en-us' -and $_.Architecture -eq 'x64' -and $_.Edition -eq $Edition -and $_.FileName -match '^(\d+)\.(\d+)\.' } |
            ForEach-Object { [PSCustomObject]@{ File = $_; Base = [int]($_.FileName -split '\.')[0]; Ubr = [int]($_.FileName -split '\.')[1] } }
    }
    $targetBase = if ($ExpectedBuild) { [int]($ExpectedBuild -split '\.')[0] } else { @{ '24H2' = 26100; '25H2' = 26200; '26H2' = 26300 }[$Version] }
    $pick = $images | Where-Object { if ($BaseImage) { "$($_.Base).$($_.Ubr)" -eq $BaseImage } else { -not $targetBase -or $_.Base -le $targetBase } } | Sort-Object Base, Ubr | Select-Object -Last 1
    if (-not $pick) { throw "The Media Creation Tool's catalogs have no en-us x64 image with the $Edition edition for $Version" }
    Log "Images in the catalogs: $((($images | ForEach-Object { "$($_.Base).$($_.Ubr)" }) | Sort-Object -Unique) -join ', ')"
    $file = $pick.File
    $esd = Join-Path $WorkDir $file.FileName
    # Newer catalogs list a SHA-256 hash, older ones SHA-1
    $algorithm, $expected = if ($file.Sha256) { 'SHA256', $file.Sha256.ToUpper() } elseif ($file.Sha1) { 'SHA1', $file.Sha1.ToUpper() } else { throw "No hash for $($file.FileName) in the catalog" }
    if (-not (Test-Path $esd) -or (Get-FileHash $esd -Algorithm $algorithm).Hash -ne $expected) {
        Log "Downloading $($file.FileName) ($([math]::Round([double]$file.Size / 1GB, 1)) GB)"
        Save-Url $file.FilePath $esd
        $hash = (Get-FileHash $esd -Algorithm $algorithm).Hash
        if ($hash -ne $expected) { throw "$algorithm mismatch for $esd" }
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

    # The image's files before Windows first starts, for the file check before the scan (files no update lists must be the image's)
    Log 'Listing the files of the image'
    & python.exe (Join-Path $RepoDir 'verify-windows-files.py') image --root $winRoot --out (Join-Path $WorkDir 'image-files.csv.gz')
    if ($LASTEXITCODE -ne 0) { throw "Listing the image's files failed ($LASTEXITCODE)" }

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

function Invoke-VmTask([string]$name, [string]$script, [int]$timeoutMinutes = 60, [switch]$AsUser) {
    # Runs a script inside the VM as a SYSTEM scheduled task, shows its log as it grows, and returns what it passed to Write-Result.
    # Windows Update refuses to download or install from a remote session (PowerShell Direct is one), and long installs and the scan
    # are better off not depending on one either. The script gets two functions: Write-Log (a line in its log) and Write-Result.
    # With -AsUser, the task runs as the VM's own user instead (scan, an administrator, elevated), with that user's apps and settings.
    $preamble = @'
$log = 'C:\scan-tasks\__NAME__.log'
function Write-Log([string]$line) {
    for ($i = 0; $i -lt 50; $i++) { try { [IO.File]::AppendAllText($log, $line + "`r`n"); return } catch { Start-Sleep -Milliseconds 200 } }
}
function Write-Result([string]$value) { Write-Log "result: $value"; Set-Content 'C:\scan-tasks\__NAME__.result' $value }
'@.Replace('__NAME__', $name)
    Invoke-InVM -arguments $name, ($preamble + "`r`n" + $script), $(if ($AsUser) { Get-VmPassword } else { '' }) {
        param($name, $script, $password)
        New-Item -ItemType Directory -Force C:\scan-tasks | Out-Null
        Set-Content "C:\scan-tasks\$name.ps1" $script
        Remove-Item "C:\scan-tasks\$name.log", "C:\scan-tasks\$name.result" -ErrorAction SilentlyContinue
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File C:\scan-tasks\$name.ps1"
        if ($password) {
            Register-ScheduledTask -TaskName $name -Action $action -User 'scan' -Password $password -RunLevel Highest -Force | Out-Null
        } else {
            Register-ScheduledTask -TaskName $name -Action $action -User 'NT AUTHORITY\SYSTEM' -RunLevel Highest -Force | Out-Null
        }
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
    # Windows Update's target release version policy makes it offer that version's enablement package as the feature update.
    # Returns whether the VM needs a restart.
    if ((Get-VmBuild).Split(' ')[1] -eq $Version) {
        Log "The VM is $Version already"
        return $false
    }
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
    $kbs = @($wanted | ForEach-Object { $_.KBArticleIDs | ForEach-Object { "KB$_" } }) -join ' '
    Write-Result "installed $($i.ResultCode), reboot required: $($i.RebootRequired), KB: $kbs"
} catch { Write-Result "error $($_.Exception.Message)" }
'@).Replace('__VERSION__', $Version)
    if ($result -notmatch '^installed 2') { throw "Windows Update didn't install the $Version enablement package: $result" }  # 2 = succeeded
    Save-Report 'enablement-package.json' @{ result = $result; kbs = @([regex]::Matches($result, 'KB\d+') | ForEach-Object { $_.Value }) }
    return ($result -match 'reboot required: True')
}

function Register-InsiderDevice {
    # Unfinished. Currently the daily check doesn't start Insider scans, and this stops one that's started anyway.
    # Insider build requests typically come after registering device in the Settings GUI. 
    # This function is where we'd enroll if that's the approach we end up going with. Might see if there's a way to just fetch it directly or automate enrollment.
    # $InsiderChannel for which channel. $InsiderDevice for the enrolled device or account. (the WINDOWS_INSIDER_DEVICE secret in the workflow)
    # Apparently they don't actually check if a machine is enrolled.
    if (-not $InsiderDevice) {
        throw "Insider build support not yet implemented (determined because the WINDOWS_INSIDER_DEVICE secret is empty)"
    }
    throw "Windows Insider builds support isn't written yet (Register-InsiderDevice in scan-in-vm.ps1)"
}

function Install-InsiderBuild {
    # Once the VM is configured to receive updates for the requested Insider channel, Windows Update can offer that channel's build
    # as a feature update, followed by its cumulative update. Installs what it offers until the VM reaches the expected build.
    Register-InsiderDevice
    for ($round = 1; $round -le 4; $round++) {
        $build = (Get-VmBuild).Split(' ')[0]
        if ($ExpectedBuild -and $build -eq $ExpectedBuild) { break }
        $result = Invoke-VmTask 'InsiderBuild' -timeoutMinutes 240 -script @'
Write-Log 'searching Windows Update'
try {
    $session = New-Object -ComObject Microsoft.Update.Session
    $found = $session.CreateUpdateSearcher().Search("IsInstalled=0 and Type='Software'").Updates
    $wanted = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $found) {
        Write-Log "offered: $($u.Title)"
        if ($u.Title -match 'Insider Preview') {
            if (-not $u.EulaAccepted) { $u.AcceptEula() }
            [void]$wanted.Add($u)
        }
    }
    if ($wanted.Count -eq 0) { Write-Result 'nothing to install'; return }
    $dl = $session.CreateUpdateDownloader(); $dl.Updates = $wanted; $d = $dl.Download()
    Write-Log "download result: $($d.ResultCode)"
    $inst = $session.CreateUpdateInstaller(); $inst.Updates = $wanted; $i = $inst.Install()
    Write-Result "installed $($i.ResultCode), reboot required: $($i.RebootRequired), titles: $(@($wanted | ForEach-Object { $_.Title }) -join '; ')"
} catch { Write-Result "error $($_.Exception.Message)" }
'@
        Log "Windows Update, round ${round}: $result"
        if ($result -notmatch '^installed [23]') { throw "Windows Update didn't install the $InsiderChannel channel's build: $result" }  # 2 = succeeded, 3 = with errors
        Restart-ScanVM
        Set-VmNetwork
        Log "VM build: $(Get-VmBuild)"
    }
    Save-Report 'insider-build.json' @{ channel = $InsiderChannel; build = (Get-VmBuild) }
}

function Save-Report([string]$name, $data) {
    $data | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $OutputDir $name) -Encoding UTF8
}

function Install-OtherUpdates {
    # Everything else Windows Update offers the VM, as it would to any PC at this build: Defender and Windows Security platform updates,
    # .NET, the Malicious Software Removal Tool and the like, some of which replace files the scan reads. Left out: updates that would
    # change the build (cumulative and feature updates), optional ones (a PC only gets those when someone asks for them), drivers and
    # Defender's definition updates (several a day). Repeats, restarting the VM when an update asks for it, until Windows Update has
    # nothing left to offer.
    $installed = @(); $kbs = @(); $failedTitles = @()
    for ($round = 1; $round -le 5; $round++) {
        $r = (Invoke-VmTask 'ScanUpdates' -timeoutMinutes 120 -script @'
try {
    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'FeatureScan'
    Write-Log 'searching Windows Update'
    $found = $session.CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0 and Type='Software'").Updates
    $wanted = New-Object -ComObject Microsoft.Update.UpdateColl
    $leftOut = @()
    foreach ($u in $found) {
        $categories = @($u.Categories | ForEach-Object { $_.Name }) -join ', '
        # (The Windows Security platform update is filed under Definition Updates too, so only the definitions themselves are left out)
        if ($u.BrowseOnly -or $u.Title -match 'Cumulative Update (Preview )?for Windows|Feature update|Windows 11, version|Insider Preview|Upgrade|Security Intelligence Update') {
            $leftOut += "$($u.Title) [$categories$(if ($u.BrowseOnly) { ', optional' })]"
            continue
        }
        if (-not $u.EulaAccepted) { $u.AcceptEula() }
        [void]$wanted.Add($u)
        Write-Log "to install: $($u.Title)"
    }
    $leftOut | ForEach-Object { Write-Log "left out: $_" }
    $ok = @(); $failed = @(); $kbs = @(); $reboot = $false
    if ($wanted.Count) {
        $downloader = $session.CreateUpdateDownloader(); $downloader.Updates = $wanted; [void]$downloader.Download()
        $installer = $session.CreateUpdateInstaller(); $installer.Updates = $wanted; $result = $installer.Install()
        for ($i = 0; $i -lt $wanted.Count; $i++) {
            $one = $result.GetUpdateResult($i)
            Write-Log ("{0}: result {1}, 0x{2:X8}" -f $wanted.Item($i).Title, $one.ResultCode, $one.HResult)
            if ($one.ResultCode -in 2, 3) {  # 2 = succeeded, 3 = with errors
                $ok += $wanted.Item($i).Title
                $kbs += @($wanted.Item($i).KBArticleIDs | ForEach-Object { "KB$_" })
            } else { $failed += $wanted.Item($i).Title }
        }
        $reboot = $result.RebootRequired
    }
    Write-Result (@{ installed = $ok; kbs = $kbs; failed = $failed; reboot = $reboot; leftOut = $leftOut } | ConvertTo-Json -Compress)
} catch { Write-Result (@{ error = $_.Exception.Message } | ConvertTo-Json -Compress) }
'@) | ConvertFrom-Json
        if ($r.error) { throw "Windows Update failed: $($r.error)" }
        if (-not $r.installed -and -not $r.failed) {
            Save-Report 'windows-update.json' @{ installed = $installed; kbs = $kbs; leftOut = @($r.leftOut); notInstalled = @() }
            Log "Windows Update has nothing left to install ($($installed.Count) updates installed)"
            return
        }
        $installed += @($r.installed)
        $kbs += @($r.kbs)
        $failedTitles = @($r.failed)
        if ($r.reboot -or $r.failed) {
            # Also after a failure: a restart can clear what was in its way, and the next round tries again
            if ($r.failed) { Log "Failed: $($r.failed -join '; '); restarting the VM before trying again" }
            Restart-ScanVM
            Set-VmNetwork
        }
    }
    # These updates don't decide the build (the cumulative update and the enablement package do, and the checks look at those), so
    # this doesn't stop the scan; the build's data notes it (Add-ScanNotes)
    Save-Report 'windows-update.json' @{ installed = $installed; kbs = $kbs; leftOut = @($r.leftOut); notInstalled = $failedTitles }
    Log "WARNING: Windows Update still has updates it couldn't install after 5 rounds: $($failedTitles -join '; ')"
}

function Add-ScanNotes {
    # Notes for the build's data (update-data.py copies them from summary.json): updates the VM couldn't install, and the Insider
    # channel of an Insider build
    $notes = @()
    $store = Join-Path $OutputDir 'store-apps.json'
    if (Test-Path $store) {
        $r = Get-Content $store -Raw | ConvertFrom-Json
        $left = @(@($r.left) + @($r.errors) | Where-Object { $_ })
        if ($left) { $notes += "Store apps that couldn't be updated, so the scan saw an older version: $($left -join '; ')" }
    }
    $wu = Join-Path $OutputDir 'windows-update.json'
    if (Test-Path $wu) {
        $r = Get-Content $wu -Raw | ConvertFrom-Json
        $left = @(@($r.notInstalled) | Where-Object { $_ })
        if ($left) { $notes += "Updates Windows Update offered that couldn't be installed: $($left -join '; ')" }
    }
    $fields = @()
    if ($InsiderChannel) { $fields += '"insiderChannel": ' + (ConvertTo-Json $InsiderChannel -Compress) }
    if ($notes) { $fields += '"notes": ' + (ConvertTo-Json @($notes) -Compress) }
    if (-not $fields) { return }
    $summary = Join-Path $OutputDir 'summary.json'
    $text = (Get-Content $summary -Raw -Encoding UTF8) -replace '^\s*\{', ('{' + ($fields -join ', ').Replace('$', '$$') + ', ')
    Set-Content $summary $text -Encoding UTF8
    $notes | ForEach-Object { Log "Note for the build's data: $_" }
}

function Update-StoreApps {
    # The apps that come with Windows (Windows Security, the Windows App Runtime, Photos and so on) are updated by the Microsoft Store,
    # not by Windows Update, so an image keeps the versions it was made with. The Store's own update search, the one a PC runs
    # by itself, brings them to the versions a PC gets today. On a PC some of these updates wait for a convenient time, and one for an
    # app that's running waits until it's closed. Here they're started right away; once the others are done, each one that failed
    # because something was in use is tried again after closing what the deployment log names. Every change is logged as it
    # happens. Done when a search finds nothing more; if one still does, or an update still fails, the VM is restarted and it all
    # runs once more.
    $script = @'
try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
    function Wait-Async($operation, [Type]$type) { $task = $asTask.MakeGenericMethod($type).Invoke($null, @($operation)); [void]$task.Wait(-1); $task.Result }
    [void][Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallManager, Windows.ApplicationModel.Store.Preview, ContentType = WindowsRuntime]
    $listType = [System.Collections.Generic.IReadOnlyList[Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallItem]]
    $manager = New-Object Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallManager

    $seen = @{}; $changed = @{}
    function Watch-Queue([string]$only) {
        # Waits until the queue's updates (or only the one for the app $only) have finished or failed, logging every change and
        # starting background updates that sit waiting. Returns $false if nothing changed for 10 minutes.
        $lastChange = Get-Date
        while ($true) {
            Start-Sleep -Seconds 15
            $active = 0
            foreach ($item in @($manager.AppInstallItems)) {
                $name = $item.PackageFamilyName
                $status = $item.GetCurrentStatus()
                $state = "$($status.InstallState)"
                $key = "$state $([int]($status.PercentComplete / 25))"
                if ($seen[$name] -ne $key) {
                    $seen[$name] = $key; $changed[$name] = Get-Date; $lastChange = Get-Date
                    Write-Log "  ${name}: $state$(if ($state -eq 'Error') { " - $($status.ErrorCode)" } elseif ($status.PercentComplete) { " $([int]$status.PercentComplete)%" })"
                }
                if ($state -in 'Completed', 'Canceled', 'Error' -or ($only -and $name -ne $only)) { continue }
                $active++
                if ($state -in 'ReadyToDownload', 'Paused' -and ((Get-Date) - $changed[$name]).TotalSeconds -ge 60) {
                    $item.Restart()
                    $changed[$name] = Get-Date
                    Write-Log "  ${name}: started ($state)"
                }
            }
            if (-not $active) { return $true }
            if (((Get-Date) - $lastChange).TotalMinutes -ge 10) {
                Write-Log "no progress for 10 minutes: $((@($manager.AppInstallItems) | ForEach-Object { "$($_.PackageFamilyName) ($($_.GetCurrentStatus().InstallState))" }) -join ', ')"
                return $false
            }
        }
    }

    function Close-AppsInTheWay([string]$family) {
        # For error 0x80073D02, the deployment log (event 404) names what has to be closed: "AppX Deployment operation failed for
        # package <package> with error 0x80073D02. ... Unable to install because the following apps need to be closed <packages>."
        # The newest such event for the app since the VM started counts; the Store may have tried it by itself before this task.
        $familyOf = { param($fullName) $parts = $fullName -split '_'; "$($parts[0])_$($parts[-1])" }  # Name_Version_Arch_Resource_Publisher
        $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
        $names = @()
        foreach ($event in @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-AppXDeploymentServer/Operational'; Id = 404; StartTime = $boot } -ErrorAction SilentlyContinue)) {
            $message = $event.Message -replace '\s+', ' '  # Newest first
            if ($message -match 'failed for package (\S+) with error 0x80073D02.*need to be closed (.+?)\.?\s*$' -and (& $familyOf $Matches[1]) -eq $family) {
                $names = @($Matches[2] -split '[,\s]+' | Where-Object { $_ })
                break
            }
        }
        if (-not $names) { Write-Log "  ${family}: the deployment log names nothing to close"; return }
        foreach ($name in $names) {
            $location = (Get-AppxPackage -AllUsers | Where-Object { $_.PackageFullName -eq $name } | Select-Object -First 1).InstallLocation
            $processes = @(Get-Process | Where-Object { $_.Path -and $location -and $_.Path.StartsWith($location + '\', [StringComparison]::OrdinalIgnoreCase) })
            Write-Log "  ${family}: closing $name ($(if ($processes) { ($processes | ForEach-Object { "$($_.ProcessName) $($_.Id)" }) -join ', ' } else { 'none of its processes is running' }))"
            $processes | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }

    $before = @{}
    Get-AppxPackage -AllUsers | ForEach-Object { $before[$_.PackageFullName] = $true }
    for ($round = 1; $round -le 4; $round++) {
        $items = @(Wait-Async ($manager.SearchForAllUpdatesAsync()) $listType)
        Write-Log "search ${round}: $($items.Count) updates"
        if (-not $items.Count) { break }
        $items | ForEach-Object { Write-Log "  $($_.PackageFamilyName)" }
        [void](Watch-Queue)
        # Then the ones that failed, one at a time, once nothing else is installing
        foreach ($item in @($manager.AppInstallItems | Where-Object { "$($_.GetCurrentStatus().InstallState)" -eq 'Error' })) {
            $family = $item.PackageFamilyName
            for ($try = 1; $try -le 3 -and "$($item.GetCurrentStatus().InstallState)" -eq 'Error'; $try++) {
                if ("$($item.GetCurrentStatus().ErrorCode)" -match '80073D02') { Close-AppsInTheWay $family }
                Write-Log "  ${family}: trying again ($try)"
                $item.Restart()
                [void](Watch-Queue $family)
            }
        }
    }
    # The final state: what a new search still finds, and what's still failing
    $left = @(Wait-Async ($manager.SearchForAllUpdatesAsync()) $listType | ForEach-Object { $_.PackageFamilyName })
    $failed = @(@($manager.AppInstallItems) | Where-Object { "$($_.GetCurrentStatus().InstallState)" -eq 'Error' } | ForEach-Object { "$($_.PackageFamilyName): $($_.GetCurrentStatus().ErrorCode)" })
    $new = @(Get-AppxPackage -AllUsers | Where-Object { -not $before[$_.PackageFullName] } | ForEach-Object { $_.PackageFullName })
    $new | ForEach-Object { Write-Log "installed: $_" }
    Write-Result (@{ installed = $new; left = $left; errors = $failed } | ConvertTo-Json -Compress)
} catch { Write-Result (@{ error = $_.Exception.Message } | ConvertTo-Json -Compress) }
'@
    $installed = @()
    for ($pass = 1; $pass -le 2; $pass++) {
        $r = (Invoke-VmTask 'ScanApps' -timeoutMinutes 150 -script $script) | ConvertFrom-Json
        if ($r.error) { throw "Updating the Store apps failed: $($r.error)" }
        $installed += @($r.installed)
        Save-Report 'store-apps.json' @{ installed = $installed; left = @($r.left); errors = @($r.errors); passes = $pass }
        if (-not $r.left -and -not $r.errors) {
            Log "The Store has no app updates left ($($installed.Count) packages installed)"
            return
        }
        if ($pass -eq 1) {
            Log "Store apps not all up to date ($((@($r.left) + @($r.errors)) -join '; ')); restarting the VM and trying again"
            Restart-ScanVM
            Set-VmNetwork
        }
    }
    # Apps don't decide the build, so this doesn't stop the scan; the build's data notes it (Add-ScanNotes)
    Log "WARNING: the Store apps aren't all up to date, even after a restart: $((@($r.left) + @($r.errors)) -join '; ')"
}

function Test-VmInstallation([string[]]$kbs) {
    # Checks, before the scan, that the VM's Windows is complete for its build. Any failure stops the run, so nothing is recorded.
    #   1. Windows' servicing: the build's cumulative update is installed, and no update is half installed or waiting for a restart
    #   2. DISM /ScanHealth: the files in the component store match their manifests, which Microsoft signs
    #   3. sfc /verifyonly: so do the installed system files
    #   4. verify-windows-files.py: the installed files against the SHA-256 hashes in Microsoft's file lists for the update (see there)
    $build = (Get-VmBuild).Split(' ')[0]
    if ($ExpectedBuild -and $build -ne $ExpectedBuild) { throw "The VM is at build $build, not $ExpectedBuild" }
    $ubr = [int]$build.Split('.')[1]
    $query = {
        $packages = @(Get-WindowsPackage -Online)
        $cbs = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing'
        @{ Rollups = @($packages | Where-Object { $_.PackageName -like 'Package_for_RollupFix~*' -and "$($_.PackageState)" -eq 'Installed' } | ForEach-Object { $_.PackageName })
           Unfinished = @($packages | Where-Object { "$($_.PackageState)" -in 'InstallPending', 'UninstallPending', 'PartiallyInstalled' } | ForEach-Object { "$($_.PackageName) ($($_.PackageState))" })
           RestartPending = (Test-Path "$cbs\RebootPending") -or (Test-Path "$cbs\PackagesPending") -or (Test-Path "$cbs\RebootInProgress")
           Packages = $packages.Count }
    }
    $servicing = Invoke-InVM -Retry $query
    if ($servicing.RestartPending -or $servicing.Unfinished) {
        # Windows' setup leaves servicing work for the first restart, as on a new PC; a restart has to finish it
        Log 'Windows has servicing work pending until a restart; restarting the VM first'
        Restart-ScanVM
        Set-VmNetwork
        $servicing = Invoke-InVM -Retry $query
    }
    # The cumulative update's package is named after the build it brings, in the shared base build (26100.9818 for 26300.9818)
    $rollup = @($servicing.Rollups | Where-Object { $_ -match "~~\d+\.$ubr\." })
    Log "Servicing: $($servicing.Packages) packages; cumulative update package $(if ($rollup) { $rollup[0] } else { 'missing' }); $($servicing.Unfinished.Count) unfinished; restart pending: $($servicing.RestartPending)"

    $health = (Invoke-VmTask 'ScanHealth' -timeoutMinutes 150 -script @'
try {
    Write-Log 'DISM /Cleanup-Image /ScanHealth'
    $dism = @(& dism.exe /English /Online /Cleanup-Image /ScanHealth)
    $dismCode = $LASTEXITCODE
    $dism | Where-Object { $_.Trim() } | Select-Object -Last 2 | ForEach-Object { Write-Log $_.Trim() }
    Write-Log 'sfc /verifyonly'
    $sfc = ((& sfc.exe /verifyonly) -join "`n") -replace "`0", ''  # sfc writes UTF-16
    $sfcCode = $LASTEXITCODE
    $sfc -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 2 | ForEach-Object { Write-Log $_.Trim() }
    $sfcOk = $sfc -match 'did not find any integrity violations'
    $details = if ($sfcOk) { @() } else { @(Select-String -Path C:\Windows\Logs\CBS\CBS.log -Pattern '\[SR\]' | Select-Object -Last 50 | ForEach-Object { $_.Line }) }
    Write-Result (@{ dism = (($dism -join "`n") -match 'No component store corruption detected'); dismCode = $dismCode; sfc = $sfcOk; sfcCode = $sfcCode; sfcDetails = $details } | ConvertTo-Json -Compress)
} catch { Write-Result (@{ error = $_.Exception.Message } | ConvertTo-Json -Compress) }
'@) | ConvertFrom-Json

    $files = $null
    if ($kbs) {
        Copy-ScannerToVM
        # The other updates installed in the VM replace files too: the .NET Framework update that comes with the enablement package,
        # what the Windows Update pass installed, and what the image came with. Windows lists them all as installed updates.
        $installed = @(Invoke-InVM -Retry { Get-HotFix | ForEach-Object { $_.HotFixID } })
        $others = @(@($installed) + @(foreach ($report in 'enablement-package.json', 'windows-update.json') {
            $path = Join-Path $OutputDir $report
            if (Test-Path $path) { @((Get-Content $path -Raw | ConvertFrom-Json).kbs) }
        }) | Where-Object { $_ -match '^KB\d+$' -and $_ -notin $kbs } | Select-Object -Unique)
        $arguments = @($kbs | ForEach-Object { "--kb $_" }) + @($others | ForEach-Object { "--other-kb $_" })
        $image = Join-Path $WorkDir 'image-files.csv.gz'
        if (Test-Path $image) {
            Copy-ToVM $image 'C:\scan\image-files.csv.gz'
            $arguments += '--image C:\scan\image-files.csv.gz'
        } else {
            Log "No list of the image's files ($image); files no update lists can't be checked"
        }
        $code = Invoke-VmTask 'ScanFiles' -timeoutMinutes 180 -script (@'
try {
    Set-Location C:\scan
    # Python checks certificates against the Windows certificate store, which fetches the root certificates it lacks only when
    # Windows itself connects, so connect once from PowerShell
    foreach ($url in 'https://learn.microsoft.com/', 'https://support.microsoft.com/', 'https://go.microsoft.com/', 'https://download.microsoft.com/') {
        try { Invoke-WebRequest $url -UseBasicParsing -Method Head -TimeoutSec 60 | Out-Null } catch { }
    }
    & C:\scan\python\python.exe verify-windows-files.py check __ARGUMENTS__ --cache-dir C:\scan\kb --out C:\scan\verification-files.json --inventory C:\scan\files.csv.gz 2>&1 | ForEach-Object { Write-Log "$_" }
    Write-Result $LASTEXITCODE
} catch { Write-Result "error $($_.Exception.Message)" }
'@).Replace('__ARGUMENTS__', ($arguments -join ' '))
        $s = Get-VmSession
        foreach ($f in 'verification-files.json', 'files.csv.gz') { Copy-Item -FromSession $s -Path "C:\scan\$f" -Destination $OutputDir -Force -ErrorAction SilentlyContinue }
        $files = @{ exitCode = $code; report = 'verification-files.json' }
    } else {
        Log 'No update to check the files against (the build has no cumulative update of its own)'
    }

    Save-Report 'verification.json' @{ build = $build; servicing = $servicing; cumulativeUpdatePackage = $rollup; health = $health; files = $files }
    $failures = @()
    # (An Insider build installed as a feature update can be all in its base packages, with no cumulative update of its own)
    if (-not $rollup -and -not $InsiderChannel) { $failures += "no installed cumulative update package for build $build" }
    if ($servicing.Unfinished) { $failures += "unfinished packages: $($servicing.Unfinished -join ', ')" }
    if ($servicing.RestartPending) { $failures += 'a restart is pending' }
    if ($health.error) { $failures += "health checks failed: $($health.error)" }
    else {
        if (-not $health.dism) { $failures += "DISM /ScanHealth found problems (exit code $($health.dismCode))" }
        if (-not $health.sfc) { $failures += "sfc /verifyonly found integrity violations: $($health.sfcDetails -join ' | ')" }
    }
    if ($files -and $files.exitCode -ne '0') { $failures += "the file check found problems or failed ($($files.exitCode)); see verification-files.json" }
    if ($failures) { throw "The VM's Windows isn't what build $build should be: $($failures -join '; ')" }
    Log "Verified build $build"
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

function Copy-ScannerToVM {
    # The VM gets the runner's Python and the scanner's files, for the checks and the scan. Python goes in as one zip with what the
    # scanner needs: the interpreter and the standard library, without tests, Tcl/Tk, IDLE, installed packages and the like (6,000
    # files otherwise).
    if (-not (Invoke-InVM -Retry { Test-Path C:\scan\python\python.exe })) {
        $python = Split-Path -Parent (Get-Command python.exe).Source
        $stage = Join-Path $WorkDir 'python-stage'
        $zip = Join-Path $WorkDir 'python.zip'
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        & robocopy.exe $python $stage /E /NFL /NDL /NJH /NJS /NP /XD test tests idlelib tkinter turtledemo tcl site-packages ensurepip __pycache__ Doc include libs Scripts | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "Copying Python failed (robocopy exit code $LASTEXITCODE)" }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip)
        Log ("Copying Python ({0} from {1}, {2:N0} MB zipped) into the VM" -f (& "$python\python.exe" --version), $python, ((Get-Item $zip).Length / 1MB))
        Invoke-InVM -Retry { Remove-Item C:\scan -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force C:\scan | Out-Null }
        Copy-ToVM $zip 'C:\scan\python.zip'
        Invoke-InVM {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [IO.Compression.ZipFile]::ExtractToDirectory('C:\scan\python.zip', 'C:\scan\python')
            Remove-Item C:\scan\python.zip
        }
    }
    foreach ($f in 'scan-symbols.py', 'scan-features.ps1', 'download-vivetool.ps1', 'verify-windows-files.py', 'microsoft_learn.py', 'run-super-god-mode.ps1') {
        Copy-Item -ToSession (Get-VmSession) -Path (Join-Path $RepoDir $f) -Destination C:\scan\ -Force
    }
}

function Invoke-ScanInVM([string]$resultsCache) {
    # The scan runs the way the regular workflow runs it on the runner
    Copy-ScannerToVM
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

    # Super God Mode's statistics, as the VM's user would get them. They come in addition to the scan, so a failure only means the
    # build's data has none (run-super-god-mode.ps1 reports its own failures in run.json and still succeeds).
    try {
        $godMode = Invoke-VmTask 'SuperGodMode' -AsUser -timeoutMinutes 60 -script @'
try {
    & C:\scan\run-super-god-mode.ps1 -OutputDir C:\scan\output-temp\super-god-mode *>&1 | ForEach-Object { Write-Log "$_" }
    Write-Result 'ok'
} catch { Write-Result "error $($_.Exception.Message)" }
'@
        if ($godMode -ne 'ok') { Log "Super God Mode didn't run: $godMode" }
    } catch {
        Log "Super God Mode didn't run: $($_.Exception.Message)"
    }

    Log "Copying the results to $OutputDir"
    $s = Get-VmSession
    Copy-Item -FromSession $s -Path C:\scan\output-temp\* -Destination $OutputDir -Recurse -Force
    foreach ($f in 'symbol-features.json', 'extracted-names.txt') { Copy-Item -FromSession $s -Path "C:\scan\$f" -Destination $OutputDir -Force }
    if ($resultsCache) { Copy-Item -FromSession $s -Path C:\scan\symbol-cache.json -Destination $resultsCache -Force }
    Add-ScanNotes
}

# ---------------------------------------------------------------------------

$esd = $null; $updateUrls = $null
if ($Step -in 'All', 'Image', 'Disk') { $esd = Get-BaseImage }
if ($Step -in 'All', 'Download', 'Install', 'Verify' -and $Kb) { $updateUrls = Get-CumulativeUpdate }  # A version's first release can be its enablement package alone
if ($Step -in 'All', 'Disk') { New-ScanDisk $esd | Out-Null }
if ($Step -in 'All', 'VM', 'Install', 'FeatureUpdate', 'Updates', 'Apps', 'Verify', 'Scan') {
    Start-ScanVM
    $script:VmSession = Wait-ScanVM
    Set-VmNetwork
    Log "VM build: $(Get-VmBuild)"
}
if ($Step -in 'All', 'Install' -and $updateUrls) {
    $current = (Get-VmBuild).Split(' ')[0]
    if ($ExpectedBuild -and [version]$current -ge [version]$ExpectedBuild) {
        Log "The VM is at build $current already"
    } else {
        Install-CumulativeUpdate $updateUrls
        Restart-ScanVM
        Set-VmNetwork
        Log "VM build after the cumulative update: $(Get-VmBuild)"
    }
}
if ($Step -in 'All', 'FeatureUpdate') {
    if ($InsiderChannel) {
        Install-InsiderBuild
    } elseif (Install-TargetVersion) {
        Restart-ScanVM
        Set-VmNetwork
    }
    Log "VM build after the feature update: $(Get-VmBuild)"
}
if ($Step -in 'All', 'Updates') { Install-OtherUpdates }
if ($Step -in 'All', 'Apps') { Update-StoreApps }
if ($Step -in 'All', 'Verify') {
    # A last restart after all the updates, as a PC gets, so the checks and then the scan see Windows as it starts from now on
    # (restarting after the checks could change what they checked)
    Restart-ScanVM
    Set-VmNetwork
    # The target update first, then the checkpoint updates the Microsoft Update Catalog lists with it
    $kbs = @(@(if ($Kb) { $Kb.ToUpper() }) + @($updateUrls | ForEach-Object { if ($_ -match '-(kb\d+)-') { $Matches[1].ToUpper() } }) | Where-Object { $_ } | Select-Object -Unique)
    Test-VmInstallation $kbs
}
if ($Step -in 'All', 'Scan') {
    $build = (Get-VmBuild).Split(' ')[0]
    if ($ExpectedBuild -and $build -ne $ExpectedBuild) { throw "The VM is at build $build, not $ExpectedBuild" }
    Invoke-ScanInVM (Join-Path $RepoDir 'data\symbol-cache-AMD64.json')
}
Log "Done: $Step"
