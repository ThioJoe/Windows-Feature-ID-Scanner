###########################################################################
#                                                                         #
#   Module Name: NetworkSwitchManager.psd1                                #
#                                                                         #
#   Description: Network switch manager module manifest file               #
#                                                                         #
#   Copyright (c) Microsoft Corporation. All rights reserved.             #
#                                                                         #
###########################################################################
@{
    GUID = '53B60D16-69AD-4453-BF41-83EFA5AC35B8'
    Author = "Microsoft Corporation"
    CompanyName = "Microsoft"
    Copyright = "© Microsoft. All rights reserved."
    HelpInfoUri = "https://aka.ms/winsvr-2025-pshelp"
    ModuleVersion = '1.0.0.0'
    NestedModules=@("NetworkSwitchConfiguration.psm1", "NetworkSwitchEthernetPort.psm1", "NetworkSwitchFeature.psm1", "NetworkSwitchGlobalSettingData.psm1", "NetworkSwitchVlan.psm1")
    AliasesToExport = @()

    FunctionsToExport = @(
        'Disable-NetworkSwitchEthernetPort',
        'Enable-NetworkSwitchEthernetPort',
        'Get-NetworkSwitchEthernetPort',
        'Remove-NetworkSwitchEthernetPortIPAddress',
        'Set-NetworkSwitchEthernetPortIPAddress',
        'Set-NetworkSwitchPortMode',
        'Set-NetworkSwitchPortProperty',

        'Disable-NetworkSwitchFeature',
        'Enable-NetworkSwitchFeature',
        'Get-NetworkSwitchFeature',

        'Disable-NetworkSwitchVlan',
        'Enable-NetworkSwitchVlan',
        'Get-NetworkSwitchVlan',
        'New-NetworkSwitchVlan',
        'Remove-NetworkSwitchVlan',
        'Set-NetworkSwitchVlanProperty',

        'Get-NetworkSwitchGlobalData',

        'Save-NetworkSwitchConfiguration',
        'Restore-NetworkSwitchConfiguration'
    )

    PowerShellVersion = '5.1'
    TypesToProcess = @('NetworkSwitchManager.types.ps1xml')
    FormatsToProcess = @('NetworkSwitchManager.format.ps1xml')
    CompatiblePSEditions = @('Desktop','Core')
}
