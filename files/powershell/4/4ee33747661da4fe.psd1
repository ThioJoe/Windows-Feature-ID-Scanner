
@{
    GUID = 'ef018256-3318-4e74-a823-158022778487'
    Author="Microsoft Corporation"
    CompanyName="Microsoft Corporation"
    Copyright="© Microsoft Corporation. All rights reserved."
    NestedModules = @('SmbWitnessWmiClient.cdxml')
    FormatsToProcess = @('SmbWitness.format.ps1xml')
    TypesToProcess = @('SmbWitness.types.ps1xml')
    ModuleVersion = '2.0.0.0'
    AliasesToExport = @('gsmbw',
                        'msmbw',
                        'Move-SmbClient')
    FunctionsToExport = @('Get-SmbWitnessClient',
                          'Move-SmbWitnessClient')
    PowerShellVersion = '5.1'
    HelpInfoUri= "https://aka.ms/winsvr-2025-pshelp"
    CompatiblePSEditions = @('Desktop', 'Core')
}
