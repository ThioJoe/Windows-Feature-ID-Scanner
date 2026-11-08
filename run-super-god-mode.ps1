# run-super-god-mode.ps1
# Runs the latest release of ThioJoe's "Super God Mode" script (https://github.com/ThioJoe/Windows-Super-God-Mode) and keeps its
# statistics: the CSV files listing the CLSID shell folders, named special folders, task links, ms-settings: pages, deep links, URL
# protocols and hidden app links it finds, and the XML data the task links and deep links come from, as it writes them. The shortcuts
# it creates aren't kept. update-data.py stores the statistics in data/builds/<build>-<arch>/super-god-mode/.
#
#   .\run-super-god-mode.ps1 -OutputDir output-temp\super-god-mode
#
# Besides the statistics files, -OutputDir gets run.json: the script's version, its signature, the user it ran as and the number of
# rows in each CSV file. What the script finds partly depends on that user (their apps and the URL protocols those register), so the VM
# scanner runs it as the VM's own user. A failure is reported (in run.json too) but this script still succeeds: the statistics come in
# addition to the feature data, which shouldn't be held up by them.

param(
    [Parameter(Mandatory = $true)][string]$OutputDir,
    [string]$WorkDir = (Join-Path $env:TEMP 'super-god-mode')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$url = 'https://github.com/ThioJoe/Windows-Super-God-Mode/releases/latest/download/Super_God_Mode.ps1'
$info = [ordered]@{ source = $url; version = $null; signature = $null; user = $env:USERNAME; rows = [ordered]@{} }
New-Item -ItemType Directory -Force $OutputDir | Out-Null

try {
    New-Item -ItemType Directory -Force $WorkDir | Out-Null
    $script = Join-Path $WorkDir 'Super_God_Mode.ps1'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $url -OutFile $script -UseBasicParsing
    $line = Select-String -Path $script -Pattern '^\$VERSION\s*=\s*"([^"]+)"' | Select-Object -First 1
    if ($line) { $info.version = $line.Matches[0].Groups[1].Value }
    $sig = Get-AuthenticodeSignature $script
    $info.signature = "$($sig.Status)$(if ($sig.SignerCertificate) { ': ' + $sig.SignerCertificate.Subject })"
    Write-Host "Super God Mode $($info.version) (signature $($info.signature)), running as $($info.user)"

    # In its own process, so nothing it does can end this script. The output folder is new, since the script clears the one it's given.
    $out = Join-Path $WorkDir ('output-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    # Its error output is shown rather than taken as a failure (with 'Stop', the first line of it would end this script); its exit code says
    $ErrorActionPreference = 'Continue'
    $lines = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -NoGUI -NoReadMe -Output $out 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    $lines | Select-Object -Last 14 | ForEach-Object { Write-Host $_ }
    if ($code) { throw "Super God Mode exited with code $code" }

    $stats = Join-Path $out '__Script Result Statistics'
    if (-not (Test-Path $stats)) { throw 'Super God Mode wrote no statistics folder' }
    foreach ($file in Get-ChildItem $stats -File | Where-Object { $_.Extension -in '.csv', '.xml' } | Sort-Object Name) {
        Copy-Item $file.FullName $OutputDir -Force
        if ($file.Extension -eq '.csv') { $info.rows[$file.Name] = @(Import-Csv $file.FullName).Count }
    }
    if (-not $info.rows.Count) { throw 'Super God Mode wrote no CSV files' }
    Write-Host "Kept $(@(Get-ChildItem $OutputDir -File).Count) statistics files in $OutputDir"
} catch {
    $info.error = $_.Exception.Message
    Write-Warning "Super God Mode: $($info.error)"
    if ($env:GITHUB_ACTIONS -eq 'true') { Write-Host "::warning::Super God Mode: $($info.error)" }
}

[IO.File]::WriteAllText((Join-Path $OutputDir 'run.json'), ($info | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false))
exit 0
