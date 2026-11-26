#
# Module manifest for module 'VMDirectStorage'
#
# Generated on: 8/29/2019
#

@{
    GUID              = '62a0b63f-2a15-415f-919a-a48e87f830cc'
    Author            = 'Microsoft Corporation'
    CompanyName       = 'Microsoft Corporation'
    Copyright         = '(c) Microsoft Corporation. All rights reserved.'
    ModuleVersion     = '1.0.0.0'
    HelpInfoUri       = "https://aka.ms/winsvr-2025-pshelp"
    RootModule        = 'VMDirectStorage.psm1'
    FormatsToProcess  = 'VMDirectStorage.format.ps1xml'
    NestedModules     = @('VMDirectStorage.psm1')
    CmdletsToExport   = @()
    FunctionsToExport = @('Get-VMDirectVirtualDisk',
                          'Add-VMDirectVirtualDisk',
                          'Remove-VMDirectVirtualDisk')
}
