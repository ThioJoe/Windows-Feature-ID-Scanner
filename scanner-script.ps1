# Windows Feature Scanner Script
# Placeholder script that demonstrates file output functionality

Write-Host "======================================"
Write-Host "Windows Feature Scanner - Hello World"
Write-Host "======================================"
Write-Host ""

# Get system information
$osInfo = Get-CimInstance -ClassName Win32_OperatingSystem
$computerInfo = Get-CimInstance -ClassName Win32_ComputerSystem

Write-Host "System Information:"
Write-Host "  OS Name: $($osInfo.Caption)"
Write-Host "  OS Version: $($osInfo.Version)"
Write-Host "  Build Number: $($osInfo.BuildNumber)"
Write-Host "  Architecture: $($env:PROCESSOR_ARCHITECTURE)"
Write-Host "  Computer Name: $($computerInfo.Name)"
Write-Host ""

# Create output directory
$outputDir = "output-temp"
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir | Out-Null
    Write-Host "Created output directory: $outputDir"
}

# Generate sample output file 1: System info
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
Write-Host "Created output file: $systemInfoFile"

# Generate sample output file 2: Feature list (placeholder)
$featureListFile = Join-Path $outputDir "feature-list.txt"
$featureListContent = @"
Windows Feature List (Placeholder)
Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

This is a placeholder for actual feature scanning functionality.
In a real implementation, this would contain:
- Feature IDs
- Feature names
- Feature states (enabled/disabled)
- Feature descriptions

Example placeholder features:
- Feature-001: Sample Feature Alpha (Enabled)
- Feature-002: Sample Feature Beta (Disabled)
- Feature-003: Sample Feature Gamma (Enabled)
"@

$featureListContent | Out-File -FilePath $featureListFile -Encoding UTF8
Write-Host "Created output file: $featureListFile"

# Generate sample output file 3: JSON summary
$jsonOutputFile = Join-Path $outputDir "summary.json"
$jsonData = @{
    timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    buildNumber = $osInfo.BuildNumber
    osVersion = $osInfo.Version
    architecture = $env:PROCESSOR_ARCHITECTURE
    features = @(
        @{ id = "Feature-001"; name = "Sample Feature Alpha"; enabled = $true }
        @{ id = "Feature-002"; name = "Sample Feature Beta"; enabled = $false }
        @{ id = "Feature-003"; name = "Sample Feature Gamma"; enabled = $true }
    )
} | ConvertTo-Json -Depth 3

$jsonData | Out-File -FilePath $jsonOutputFile -Encoding UTF8
Write-Host "Created output file: $jsonOutputFile"

Write-Host ""
Write-Host "======================================"
Write-Host "Script execution completed successfully!"
Write-Host "Output files created in: $outputDir"
Write-Host "======================================"
