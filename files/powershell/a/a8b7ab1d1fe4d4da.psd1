@{
    GUID = "{AEEF2BEF-EBA9-4A1D-A3D2-D0B52DF76DEB}"
    HelpInfoUri="https://aka.ms/winsvr-2025-pshelp"
    AliasesToExport = @(
        'Add-AppPackage',
        'Get-AppPackage',
        'Get-AppPackageAutoUpdateSettings'
        'Get-AppPackageManifest',
        'Remove-AppPackage',
        'Remove-AppPackageAutoUpdateSettings',
        'Reset-AppPackage',
        'Get-AppPackageVolume',
        'Add-AppPackageVolume',
        'Remove-AppPackageVolume',
        'Mount-AppPackageVolume',
        'Dismount-AppPackageVolume',
        'Move-AppPackage',
        'Get-AppPackageDefaultVolume',
        'Set-AppPackageDefaultVolume',
        'Get-AppPackageLastError',
        'Get-AppPackageLog',
        'Set-AppPackageAutoUpdateSettings',
        'Add-MsixPackage',
        'Get-MsixPackage',
        'Get-MsixPackageAutoUpdateSettings'
        'Get-MsixPackageManifest',
        'Remove-MsixPackage',
        'Remove-MsixPackageAutoUpdateSettings',
        'Reset-MsixPackage',
        'Get-MsixPackageVolume',
        'Add-MsixPackageVolume',
        'Remove-MsixPackageVolume',
        'Mount-MsixPackageVolume',
        'Dismount-MsixPackageVolume',
        'Move-MsixPackage',
        'Get-MsixPackageDefaultVolume',
        'Set-MsixPackageDefaultVolume',
        'Get-MsixPackageLastError',
        'Get-MsixPackageLog',
        'Set-MsixPackageAutoUpdateSettings',
        'Get-MsixVolume',
        'Add-MsixVolume',
        'Remove-MsixVolume',
        'Mount-MsixVolume',
        'Dismount-MsixVolume',
        'Get-MsixDefaultVolume',
        'Set-MsixDefaultVolume',
        'Get-MsixLastError',
        'Get-MsixLog'
    )
    Author = "Microsoft Corporation"
    CmdletsToExport = 'Add-AppxPackage', 'Get-AppxPackage', 'Get-AppxPackageAutoUpdateSettings', 'Get-AppxPackageManifest', 'Remove-AppxPackage', 'Remove-AppxPackageAutoUpdateSettings', 'Reset-AppxPackage', 'Get-AppxVolume', 'Add-AppxVolume', 'Remove-AppxVolume', 'Mount-AppxVolume', 'Dismount-AppxVolume', 'Move-AppxPackage', 'Get-AppxDefaultVolume', 'Set-AppxDefaultVolume', 'Invoke-CommandInDesktopPackage', 'Add-AppSharedPackageContainer', 'Get-AppSharedPackageContainer', 'Remove-AppSharedPackageContainer', 'Reset-AppSharedPackageContainer', 'Set-AppxPackageAutoUpdateSettings'
    CompanyName = "Microsoft Corporation"
    Copyright = "© Microsoft Corporation. All rights reserved."
    FunctionsToExport = 'Get-AppxLastError', 'Get-AppxLog'    
    ModuleVersion = "2.0.1.0"
    RootModule = if ($PSEdition -eq 'Desktop') {
      'Microsoft.Windows.Appx.PackageManager.Commands'
    } else {
      'Microsoft.Windows.Appx.PackageManager.Commands.Core'
    }
    FormatsToProcess = 'Appx.format.ps1xml'
    NestedModules = 'Appx.psm1'
    CompatiblePSEditions = @('Desktop','Core')
    PowerShellVersion="5.1"
}
