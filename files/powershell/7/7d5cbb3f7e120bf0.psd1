@{
    ModuleVersion     = '1.0.0'
    GUID              = 'b3e5a5c8-7d2f-4e1a-9c3b-8f6d4a2e1b0c'
    Author            = 'Microsoft Corporation'
    CompanyName       = 'Microsoft Corporation'
    Copyright         = '(c) Microsoft Corporation. All rights reserved.'
    Description       = 'Windows OS License Management Module'
    PowerShellVersion = '5.1'

    NestedModules     = @(
        'OSLicenseInfo.psm1',
        'ADLicenseInfo.psm1',
        'KmsLicenseInfo.psm1',
        'SubscriptionLicenseInfo.psm1'
    )

    FunctionsToExport = @(
        'Get-OSLicenseInfo',
        'Set-OSLicenseInfo',
        'Invoke-OSLicense',
        'Get-ADLicenseInfo',
        'Invoke-ADLicense',
        'Get-KmsLicenseInfo',
        'Set-KmsLicenseInfo',
        'Invoke-KmsLicense',
        'Get-SubscriptionLicenseInfo',
        'Set-SubscriptionLicenseInfo',
        'Invoke-SubscriptionLicense'
    )

    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
}
