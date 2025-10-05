# scan-features.ps1
# This script scans for Windows feature configurations using ViVeTool,
# parses the output, and saves the results in various formats.

Write-Host "======================================"
Write-Host "Windows Feature Scanner"
Write-Host "======================================"
Write-Host ""

# --- System Information Gathering ---
Write-Host "[LOG] Gathering system information..."
$osInfo = Get-CimInstance -ClassName Win32_OperatingSystem
$computerInfo = Get-CimInstance -ClassName Win32_ComputerSystem

Write-Host "System Information:"
Write-Host "  OS Name: $($osInfo.Caption)"
Write-Host "  OS Version: $($osInfo.Version)"
Write-Host "  Build Number: $($osInfo.BuildNumber)"
Write-Host "  Architecture: $($env:PROCESSOR_ARCHITECTURE)"
Write-Host "  Computer Name: $($computerInfo.Name)"
Write-Host ""

# --- Create Output Directory Early ---
$outputDir = "output-temp"
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir | Out-Null
    Write-Host "[LOG] Created output directory: $outputDir"
}

# --- ViVeTool Execution and Parsing ---
$viveToolPath = Join-Path $PSScriptRoot "vivetool.exe"
$parsedFeatures = @()

if (-not (Test-Path $viveToolPath)) {
    Write-Error "vivetool.exe was not found. Please place it in the same directory as this script."
} else {
    Write-Host "[LOG] Executing ViVeTool to query features..."
    $viveToolOutput = & $viveToolPath /query *>&1
    Write-Host "[LOG] ViVeTool execution complete. Processing output..."

    $rawOutputFile = Join-Path $outputDir "vivetool-raw-output.txt"
    $viveToolOutput | Out-File -FilePath $rawOutputFile -Encoding UTF8
    Write-Host "[LOG] Saved raw ViVeTool output for debugging to: $rawOutputFile"

    $viveToolOutputString = ($viveToolOutput | Out-String).Trim()
    
    $featureBlocks = [regex]::Split($viveToolOutputString, '(?=\s*^\[)', 'Multiline') | Where-Object { $_ -match '\S' }
    
    Write-Host "[LOG] Found $($featureBlocks.Count) raw feature configuration blocks to parse."

    $blockCounter = 0
    $parsedFeatures = foreach ($block in $featureBlocks) {
        $blockCounter++
        Write-Host "[LOG] Parsing block $blockCounter of $($featureBlocks.Count)..."
        $id = $null
        $name = $null
        $properties = @{}

        if ($block -match '\[(\d+)\](?:\s\(([^)]+)\))?') {
            $id = $matches[1]
            $name = if ($matches.Count -gt 2) { $matches[2] } else { '' }
            Write-Host "  [OK] Extracted ID: $id, Name: '$name'"
        } else {
            Write-Warning "  [SKIP] Could not parse feature ID from block: $block"
            continue
        }

        $propertyLines = $block.Split([System.Environment]::NewLine) | Where-Object { $_ -like '*:*' }
        foreach ($line in $propertyLines) {
            if ($line -match '^\s*([^:]+?)\s*:\s*(.+)$') {
                $key = $matches[1].Trim()
                $value = $matches[2].Trim()
                $properties[$key] = $value
            }
        }
        Write-Host "  [OK] Extracted $($properties.Count) properties."

        [PSCustomObject]@{
            Id          = [uint32]$id
            Name        = $name
            Priority    = $properties['Priority']
            State       = $properties['State']
            Type        = $properties['Type']
            Variant     = $properties['Variant']
            PayloadKind = $properties['PayloadKind']
            Payload     = $properties['Payload']
        }
    }
    Write-Host "[LOG] Successfully parsed $($parsedFeatures.Count) feature configurations."
}
Write-Host ""

# --- File Generation ---
Write-Host "[LOG] Starting file generation..."

# Generate output file 1: System info
$systemInfoFile = Join-Path $outputDir "system-info.txt"
$systemInfoContent = @"
Windows Feature Scanner Output
Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

Operating System Information:
- OS Name: $($osInfo.Caption)
- OS Version: $($osInfo.Version)
- Build Number: $($osInfo.BuildNumber)
- Architecture: $($env:PROCESSOR_ARCHITECTURE)
- Install Date: $($osInfo.InstallDate)
- Last Boot Time: $($osInfo.LastBootUpTime)

Computer Information:
- Name: $($computerInfo.Name)
- Manufacturer: $($computerInfo.Manufacturer)
- Model: $($computerInfo.Model)
- Total Physical Memory: $([math]::Round($computerInfo.TotalPhysicalMemory / 1GB, 2)) GB
"@
$systemInfoContent | Out-File -FilePath $systemInfoFile -Encoding UTF8
Write-Host "[LOG] Created output file: $systemInfoFile"

# Generate output file 2: Detailed feature list
$featureListFile = Join-Path $outputDir "feature-list.txt"
$featureListHeader = @"
Windows Feature List
Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Total Configurations Found: $($parsedFeatures.Count)
"@
$featureListHeader | Out-File -FilePath $featureListFile -Encoding UTF8

$featureListContent = $parsedFeatures | ForEach-Object {
    $featureString = @"

[$($_.Id)] $($_.Name)
  Priority    : $($_.Priority)
  State       : $($_.State)
  Type        : $($_.Type)
"@
    if ($_.Variant) { $featureString += "`n  Variant     : $($_.Variant)" }
    if ($_.PayloadKind) { $featureString += "`n  PayloadKind : $($_.PayloadKind)" }
    if ($_.Payload) { $featureString += "`n  Payload     : $($_.Payload)" }
    return $featureString
}
$featureListContent | Out-File -FilePath $featureListFile -Encoding UTF8 -Append
Write-Host "[LOG] Created output file: $featureListFile"

# Generate output file 3: JSON summary
$jsonOutputFile = Join-Path $outputDir "summary.json"
Write-Host "[LOG] Preparing data for JSON summary..."

$groupedFeatures = $parsedFeatures | Group-Object -Property Id
Write-Host "[LOG] Grouped $($parsedFeatures.Count) configurations into $($groupedFeatures.Count) unique features."

$jsonFeatures = @(foreach ($group in $groupedFeatures) {
    $firstEntry = $group.Group | Select-Object -First 1
    @{
        id   = $firstEntry.Id
        name = $firstEntry.Name
        # **FIX**: Removed the logic that incorrectly stripped properties.
        # We now just select the properties we want for each configuration.
        # ConvertTo-Json will correctly omit properties that are null.
        configurations = @(
            $group.Group | ForEach-Object {
                $_ | Select-Object -Property Priority, State, Type, Variant, PayloadKind, Payload
            }
        )
    }
})

$jsonData = @{
    timestamp    = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    buildNumber  = $osInfo.BuildNumber
    osVersion    = $osInfo.Version
    architecture = $env:PROCESSOR_ARCHITECTURE
    features     = $jsonFeatures
} | ConvertTo-Json -Depth 5

$jsonData | Out-File -FilePath $jsonOutputFile -Encoding UTF8
Write-Host "[LOG] Created output file: $jsonOutputFile"

Write-Host ""
Write-Host "======================================"
Write-Host "Script execution completed successfully!"
Write-Host "Output files created in: $outputDir"
Write-Host "======================================"