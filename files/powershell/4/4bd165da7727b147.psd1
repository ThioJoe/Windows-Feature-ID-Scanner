@{
    GUID = '576ff287-7d01-46a3-8a88-94df7581a2b0'
    Author="Microsoft Corporation"
    CompanyName="Microsoft"
    Copyright="© Microsoft. All rights reserved."
    HelpInfoUri="https://aka.ms/winsvr-2025-pshelp"
    NestedModules = @('CIM_PhysicalComputerSystemView.cdxml')
    ModuleVersion = '1.0.0.0'
    AliasesToExport = @()
    CmdletsToExport = @()
    FunctionsToExport = @(
        'Get-PcsvDevice', 
        'Start-PcsvDevice',
        'Stop-PcsvDevice',
        'Restart-PcsvDevice',
        'Set-PcsvDeviceBootConfiguration',
        'Set-PcsvDeviceNetworkConfiguration',
        'Set-PcsvDeviceUserPassword',
        'Clear-PcsvDeviceLog',
        'Get-PcsvDeviceLog'
        )
    PowerShellVersion = '5.1'
    TypesToProcess = @('PCSVDevice.types.ps1xml')
    FormatsToProcess = @('PCSVDevice.format.ps1xml')
    CompatiblePSEditions = @('Desktop', 'Core')
}
