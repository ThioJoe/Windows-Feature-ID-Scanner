@{
    GUID = "{1323f046-a4bd-47df-a8bc-8253eabc49b2}"
    Author = "Microsoft Corporation"
    CompanyName = "Microsoft Corporation"
    Copyright = "© Microsoft Corporation. All rights reserved."
    CLRVersion = '4.0'
    ModuleVersion = "3.0"
    PowerShellVersion = '5.1'
    RootModule = "provisioning.psm1"
    NestedModules = "provcmdlets.dll"
    FormatsToProcess = @()
    CmdletsToExport =
        'Install-ProvisioningPackage',
        'Export-ProvisioningPackage',
        'Install-TrustedProvisioningCertificate',
        'Export-Trace',
        'Get-ProvisioningPackage',
        'Get-TrustedProvisioningCertificate',
        'New-ProvisioningRepro',
        'Uninstall-ProvisioningPackage',
        'Uninstall-TrustedProvisioningCertificate',
        'Resume-ProvisioningSession'
    AliasesToExport = @(
        'Add-ProvisioningPackage',
        'Add-TrustedProvisioningCertificate',
        'Remove-ProvisioningPackage',
        'Remove-TrustedProvisioningCertificate'
    )
    FunctionsToExport = @()
    HelpInfoUri="https://aka.ms/winsvr-2025-pshelp"
    CompatiblePSEditions = @('Desktop', 'Core')
}
