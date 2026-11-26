@{
    GUID = 'c85588a4-1180-4635-ba9e-a04581bf10c8'
    Author="Microsoft Corporation"
    CompanyName="Microsoft Corporation"
    Copyright="© Microsoft Corporation. All rights reserved."
    ModuleVersion = '1.0.0.0'
    PowerShellVersion = '3.0'
    HelpInfoUri = "https://aka.ms/winsvr-2025-pshelp"
    FormatsToProcess = 'StorageBusCache.format.ps1xml'
    TypesToProcess = 'StorageBusCache.types.ps1xml'
    NestedModules = @(
        'StorageBusCache.psm1',
        'StorageBusClientDevice.cdxml',
        'StorageBusTargetDeviceInstance.cdxml',
        'StorageBusTargetCacheStoresInstance.cdxml'
        )
    RequiredAssemblies = @(
        "$env:windir\system32\Microsoft.Windows.Storage.Core.dll",
        "$env:windir\system32\Microsoft.Windows.Storage.StorageBusCache.dll"
        )
    CmdletsToExport = @()
    FunctionsToExport = @(
        'Clear-StorageBusDisk',
        'Disable-StorageBusCache',
        'Disable-StorageBusDisk',
        'Enable-StorageBusCache',
        'Enable-StorageBusDisk',
        'Get-StorageBusDisk',
        'Get-StorageBusBinding',
        'New-StorageBusCacheStore',
        'New-StorageBusBinding',
        'Remove-StorageBusBinding',
        'Resume-StorageBusDisk',
        'Set-StorageBusProfile',
        'Suspend-StorageBusDisk',
        'Get-StorageBusCache',
        'Set-StorageBusCache',
        'Update-StorageBusCache',

        'Get-StorageBusClientDevice',
        'Get-StorageBusTargetDevice',
        'Get-StorageBusTargetDeviceInstance',
        'Get-StorageBusTargetCacheStore',
        'Get-StorageBusTargetCacheStoresInstance'
        )
}
