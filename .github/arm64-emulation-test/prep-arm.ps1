# Temporary test: prepares Microsoft's ARM64 Windows 11 image on a virtual disk that QEMU can boot without the setup screens (as
# scan-in-vm.ps1 makes its disk), and installs QEMU from MSYS2.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Work = 'D:\armtest'
New-Item -ItemType Directory -Force $Work | Out-Null
Set-Location $Work
function Log($m) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }

# The Media Creation Tool's current catalog, as scan-in-vm.ps1 gets it
$body = @{ Products = 'PN=Windows.Products.Cab.amd64&Branch=ge_release&V=26100.0.0.0'; DeviceAttributes = 'DUScan=1;OSVersion=10.0.26100.1' } | ConvertTo-Json -Compress
$found = Invoke-RestMethod -Uri 'https://fe3.delivery.mp.microsoft.com/UpdateMetadataService/updates/search/v1/bydeviceinfo' -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 120
$file = @($found)[0].FileLocations | Where-Object { $_.FileName -eq 'products.cab' } | Select-Object -First 1
Invoke-WebRequest $file.Url -OutFile "$Work\products.cab" -UseBasicParsing
$digest = [Convert]::ToBase64String((New-Object Security.Cryptography.SHA256Managed).ComputeHash([IO.File]::ReadAllBytes("$Work\products.cab")))
if ($digest -ne $file.Digest) { throw 'products.cab hash mismatch' }
& expand.exe "$Work\products.cab" -F:products.xml $Work | Out-Null
[xml]$cat = Get-Content "$Work\products.xml"
$all = @($cat.MCT.Catalogs.Catalog.PublishedMedia.Files.File | Where-Object { $_.LanguageCode -eq 'en-us' })
Log ("en-us images: " + (($all | ForEach-Object { "$($_.Architecture)/$($_.Edition)/$($_.FileName)" }) -join '; '))
$pick = $all | Where-Object { $_.Architecture -eq 'ARM64' -and $_.Edition -eq 'Enterprise' } | Sort-Object FileName | Select-Object -Last 1
if (-not $pick) { throw 'No en-us ARM64 Enterprise image in the catalog' }
$esd = Join-Path $Work $pick.FileName
Log "Downloading $($pick.FileName) ($([math]::Round([double]$pick.Size / 1GB, 2)) GB)"
$t = Get-Date
& curl.exe -sS -L --retry 5 -o $esd $pick.FilePath
if ($LASTEXITCODE -ne 0) { throw "Downloading the image failed ($LASTEXITCODE)" }
Log ("Downloaded in {0:N0} s" -f ((Get-Date) - $t).TotalSeconds)
$algorithm, $expected = if ($pick.Sha256) { 'SHA256', $pick.Sha256.ToUpper() } else { 'SHA1', $pick.Sha1.ToUpper() }
if ((Get-FileHash $esd -Algorithm $algorithm).Hash -ne $expected) { throw "$algorithm mismatch for $esd" }
Log "Image: $esd ($algorithm checked)"
Get-WindowsImage -ImagePath $esd | Format-Table ImageIndex, ImageName -AutoSize | Out-String | Write-Host

# The disk: GPT with an EFI system partition, MSR and Windows
$vhd = Join-Path $Work 'arm.vhdx'
New-VHD -Path $vhd -SizeBytes 80GB -Dynamic | Out-Null
$disk = Mount-VHD -Path $vhd -Passthru | Get-Disk
Initialize-Disk -Number $disk.Number -PartitionStyle GPT
$efi = New-Partition -DiskNumber $disk.Number -Size 260MB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -AssignDriveLetter
Format-Volume -Partition $efi -FileSystem FAT32 -NewFileSystemLabel 'System' -Confirm:$false | Out-Null
New-Partition -DiskNumber $disk.Number -Size 16MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' | Out-Null
$win = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
Format-Volume -Partition $win -FileSystem NTFS -NewFileSystemLabel 'Windows' -Confirm:$false | Out-Null
$efiRoot = "$($efi.DriveLetter):\"; $winRoot = "$($win.DriveLetter):\"
$index = (Get-WindowsImage -ImagePath $esd | Where-Object { $_.ImageName -eq 'Windows 11 Enterprise' }).ImageIndex
Log "Applying index $index to $winRoot"
$t = Get-Date
& dism.exe /English /Apply-Image "/ImageFile:$esd" "/Index:$index" "/ApplyDir:$winRoot" | Select-Object -Last 2 | Write-Host
if ($LASTEXITCODE -ne 0) { throw "DISM /Apply-Image failed ($LASTEXITCODE)" }
Log ("Applied in {0:N0} s" -f ((Get-Date) - $t).TotalSeconds)
& bcdboot.exe "$($winRoot)Windows" /s $efiRoot /f UEFI
if ($LASTEXITCODE -ne 0) { throw "bcdboot failed ($LASTEXITCODE)" }
Get-ChildItem "$($efiRoot)EFI" -Recurse -File | Where-Object { $_.Name -match '^boot.*\.efi$|^bootmgfw\.efi$' } | Format-Table FullName, Length -AutoSize | Out-String | Write-Host
# The firmware starts \EFI\Boot\bootaa64.efi on a disk it has no boot entry for
if (-not (Test-Path "$($efiRoot)EFI\Boot\bootaa64.efi")) {
    Log 'Adding \EFI\Boot\bootaa64.efi'
    New-Item -ItemType Directory -Force "$($efiRoot)EFI\Boot" | Out-Null
    Copy-Item "$($efiRoot)EFI\Microsoft\Boot\bootmgfw.efi" "$($efiRoot)EFI\Boot\bootaa64.efi"
}
$reg = 'HKLM\ARMSW'
& reg.exe load $reg "$($winRoot)Windows\System32\config\SOFTWARE" | Out-Null
$build = (& reg.exe query "$reg\Microsoft\Windows NT\CurrentVersion" /v CurrentBuildNumber | Select-String 'REG_SZ\s+(\S+)').Matches.Groups[1].Value
$ubr = [Convert]::ToInt32((& reg.exe query "$reg\Microsoft\Windows NT\CurrentVersion" /v UBR | Select-String 'REG_DWORD\s+(\S+)').Matches.Groups[1].Value, 16)
# As scan-in-vm.ps1 does: Windows Update only installs what it's asked to
& reg.exe add "$reg\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /t REG_DWORD /d 1 /f | Out-Null
[gc]::Collect(); & reg.exe unload $reg | Out-Null
Log "Image build: $build.$ubr"

# First start without the setup screens, as scan-in-vm.ps1's unattend.xml does; the benchmark runs at the first sign-in and shuts Windows down
$pw = 'Arm-' + [guid]::NewGuid().ToString('N').Substring(0, 12) + '#9a'
$arch = 'arm64'
$xml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="$arch" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>ARMTEST</ComputerName>
      <TimeZone>UTC</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="$arch" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"><InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale></component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="$arch" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
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
            <Password><Value>$pw</Value><PlainText>true</PlainText></Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>scan</Username>
        <Password><Value>$pw</Value><PlainText>true</PlainText></Password>
        <LogonCount>9999</LogonCount>
      </AutoLogon>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <CommandLine>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\armtest\bench.ps1</CommandLine>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
"@
New-Item -ItemType Directory -Force "$($winRoot)Windows\Panther", "$($winRoot)armtest", "$($winRoot)Windows\Setup\Scripts" | Out-Null
Set-Content -Path "$($winRoot)Windows\Panther\unattend.xml" -Value $xml -Encoding UTF8
Copy-Item (Join-Path $PSScriptRoot 'bench.ps1') "$($winRoot)armtest\bench.ps1"
# SetupComplete.cmd runs at the end of setup, before the first sign-in
Set-Content -Path "$($winRoot)Windows\Setup\Scripts\SetupComplete.cmd" -Value "echo %DATE% %TIME% setupcomplete>> C:\armtest\setup.txt" -Encoding ASCII
Dismount-VHD -Path $vhd
Log "Disk ready: $vhd"

# QEMU from MSYS2's repository
Log 'Installing QEMU (MSYS2)'
$t = Get-Date
& C:\msys64\usr\bin\bash.exe -lc 'pacman -Sy --noconfirm --needed mingw-w64-ucrt-x86_64-qemu' 2>&1 | Select-Object -Last 5 | Write-Host
Log ("QEMU installed in {0:N0} s" -f ((Get-Date) - $t).TotalSeconds)
& C:\msys64\ucrt64\bin\qemu-system-aarch64.exe --version | Write-Host
# Its UEFI firmware for the virt machine, uncompressed if it comes compressed
foreach ($name in 'edk2-aarch64-code.fd', 'edk2-arm-vars.fd') {
    $path = "C:\msys64\ucrt64\share\qemu\$name"
    if (-not (Test-Path $path) -and (Test-Path "$path.bz2")) { & C:\msys64\usr\bin\bzip2.exe -dk "$path.bz2" }
    if (-not (Test-Path $path)) { throw "No $name in QEMU's share folder" }
}
Get-ChildItem C:\msys64\ucrt64\share\qemu\edk2-a* | Format-Table Name, Length -AutoSize | Out-String | Write-Host
