# download-vivetool.ps1
# This script downloads and extracts the latest ViVeTool release for the current system architecture.

Write-Host "======================================"
Write-Host "ViVeTool Downloader and Extractor"
Write-Host "======================================"
Write-Host ""

# --- Configuration ---
$urlAmd64 = "https://github.com/thebookisclosed/ViVe/releases/download/v0.3.4/ViVeTool-v0.3.4-IntelAmd.zip"
$urlArm64 = "https://github.com/thebookisclosed/ViVe/releases/download/v0.3.4/ViVeTool-v0.3.4-SnapdragonArm64.zip"
$outputZipFile = "vivetool_temp.zip"

# --- Architecture Detection ---
Write-Host "Detecting system architecture..."
$downloadUrl = ""
if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {
    $downloadUrl = $urlArm64
    Write-Host "ARM64 architecture detected."
} else {
    # Default to AMD64 for any other architecture (e.g., AMD64, x86)
    $downloadUrl = $urlAmd64
    Write-Host "Intel/AMD (x64) architecture detected."
}
Write-Host ""

# --- Download ---
Write-Host "Downloading ViVeTool from: $downloadUrl"

# **FIX**: For PowerShell 5.1 compatibility, we modify the $ProgressPreference
# variable to hide the progress bar, instead of using the -ProgressAction parameter.
$originalProgressPreference = $ProgressPreference
$ProgressPreference = 'SilentlyContinue'

try {
    Invoke-WebRequest -Uri $downloadUrl -OutFile $outputZipFile
    Write-Host "[SUCCESS] ViVeTool zip file downloaded successfully."
}
catch {
    Write-Error "Failed to download ViVeTool. Please check the URL and your network connection."
    Write-Error "Error details: $_"
    exit 1 # Exit the script with an error code
}
finally {
    # Restore the user's original progress preference after the download is complete or fails.
    $ProgressPreference = $originalProgressPreference
}
Write-Host ""

# --- Extraction ---
Write-Host "Extracting files from $outputZipFile..."
try {
    Expand-Archive -Path $outputZipFile -DestinationPath . -Force
    Write-Host "[SUCCESS] Files extracted to the current directory."
}
catch {
    Write-Error "Failed to extract the archive. The file may be corrupt or you may be missing permissions."
    Write-Error "Error details: $_"
    exit 1
}
Write-Host ""

# --- Cleanup ---
Write-Host "Cleaning up downloaded zip file..."
try {
    Remove-Item -Path $outputZipFile -Force
    Write-Host "[SUCCESS] Temporary zip file removed."
}
catch {
    Write-Warning "Could not remove the temporary zip file: $outputZipFile"
    Write-Warning "Error details: $_"
}
Write-Host ""

Write-Host "======================================"
Write-Host "Setup complete. ViVeTool is ready."
Write-Host "======================================"