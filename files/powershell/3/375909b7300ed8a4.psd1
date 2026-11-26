
@{
    ModuleVersion = '2.0.0.0'
    NestedModules = @("MSFT_NetConnectionProfile.cdxml")
    FormatsToProcess = @("MSFT_NetConnectionProfile.format.ps1xml")
    TypesToProcess = @("MSFT_NetConnectionProfile.types.ps1xml")
    HelpInfoUri = "https://aka.ms/winsvr-2025-pshelp"
    GUID = '{CE4FF86E-9416-4f2d-A869-C860AC543B5E}'
    Author = 'Microsoft Corporation'
    CompanyName = 'Microsoft Corporation'
    PowerShellVersion = '5.1'
    Copyright = 'Copyright (C) Microsoft Corporation. All rights reserved.'
    FunctionsToExport = @("Get-NetConnectionProfile", "Set-NetConnectionProfile")
    CompatiblePSEditions = @('Desktop', 'Core')
}
