$script:modulePath = Split-Path -Parent $PSCommandPath
$script:WindowsAppId = '55c92734-d682-4d71-983e-d6ec3f16059f'
Import-LocalizedData -BindingVariable LocalizedData -BaseDirectory $modulePath -FileName "LicenseInfoData"
function Get-LocalizedString {
    param([string]$Key)
    return $LocalizedData[$Key]
}
function Get-LicenseStatusString {
    param([int]$Status)
    
    switch ($Status) {
        0 { return Get-LocalizedString 'LicenseStatusUnlicensed' }
        1 { return Get-LocalizedString 'LicenseStatusLicensed' }
        2 { return Get-LocalizedString 'LicenseStatusOOBGrace' }
        3 { return Get-LocalizedString 'LicenseStatusOOTGrace' }
        4 { return Get-LocalizedString 'LicenseStatusNonGenuineGrace' }
        5 { return Get-LocalizedString 'LicenseStatusNotification' }
        6 { return Get-LocalizedString 'LicenseStatusExtendedGrace' }
        default { return (Get-LocalizedString 'LicenseStatusUnknown') + " ($Status)" }
    }
}
function Format-ContextualValue {
    param(
        [Parameter(Mandatory=$true)]
        [string]$PropertyName,
        
        [Parameter(Mandatory=$false)]
        $Value
    )
    
    if ($Value -eq 4294967295) {
        switch -Wildcard ($PropertyName) {
            '*ReArmCount' { return 'Unlimited' }
            'RequiredClientCount' { return 'No Limit' }
            'ExtendedGrace' { return 'Not Applicable' }
            'KeyManagementService*Count' { return 'N/A' }
            'KeyManagementService*Requests' { return 'N/A' }
            'TokenBasedActivationGrantNumber' { return 'Not Configured' }
            'TokenBasedActivationILVID' { return 'Not Set' }
            default { return 'Not Set' }
        }
    }
    
    return $Value
}

<#
.SYNOPSIS
    Gets OS license info.
    
.DESCRIPTION
    Gets Windows OS licensing info like activation status, product key,
    expiration dates, and installation ID.
    
.PARAMETER All
    Returns full details for all licenses.
    
.PARAMETER ActivationID
    Returns full details for a specific Activation ID.
    
.PARAMETER TokenBasedLicenses
    Returns information about token-based licenses.
    
.PARAMETER TokenBasedCertificates
    Returns information about token-based certificates.
    
.EXAMPLE
    Get-OSLicenseInfo
    Gets license info for the current/default license.
    
.EXAMPLE
    Get-OSLicenseInfo -All
    Gets license info for all licenses.
    
.EXAMPLE
    Get-OSLicenseInfo -ActivationID "12345678-1234-1234-1234-123456789012"
    Gets license info for a specific activation ID.
#>
function Get-OSLicenseInfo {
    [CmdletBinding(DefaultParameterSetName='Default')]
    param (
        [Parameter(ParameterSetName='All')]
        [switch]$All,
        
        [Parameter(ParameterSetName='ActivationID')]
        [string]$ActivationID,
        
        [Parameter(ParameterSetName='TokenLicenses')]
        [switch]$TokenBasedLicenses,
        
        [Parameter(ParameterSetName='TokenCertificates')]
        [switch]$TokenBasedCertificates
    )
    
    try {
        if ($TokenBasedLicenses) {
            $tokenLicenses = Get-CimInstance -Namespace root/cimv2 -ClassName SoftwareLicensingTokenActivationLicense -ErrorAction SilentlyContinue
            
            if (-not $tokenLicenses) {
                return $null
            }
            
            return $tokenLicenses | ForEach-Object {
                [PSCustomObject]@{
                    ILID = $_.ILID
                    ILvID= $_.ILvID
                    AuthorizationStatus = $_.AuthorizationStatus
                    Description = $_.Description
                    ExpirationDate = if ($_.ExpirationDate -and $_.ExpirationDate.Year -gt 1601) { $_.ExpirationDate } else { $null }
                }
            }
        }
        
        if ($TokenBasedCertificates) {
            $licenseService = Get-CimInstance -ClassName SoftwareLicensingService
            
            if ($licenseService) {
                return [PSCustomObject]@{
                    TokenBasedActivationCertificateIssuedList = $licenseService.TokenActivationCertificateThumbprint
                    TokenBasedActivationGrantNumber= Format-ContextualValue -PropertyName 'TokenBasedActivationGrantNumber' -Value $licenseService.TokenActivationGrantNumber
                    TokenBasedActivationILID = $licenseService.TokenActivationILID
                    TokenBasedActivationILVID = Format-ContextualValue -PropertyName 'TokenBasedActivationILVID' -Value $licenseService.TokenActivationILVID
                    TokenBasedActivationAdditionalInfo = $licenseService.TokenActivationAdditionalInfo
                }
            }
            
            return $null
        }
        
        if ($ActivationID) {
            $filter = "ID = '$ActivationID'"
            $osProducts = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter $filter -ErrorAction Stop
        }
        elseif ($All) {
            # Filter to only products with ApplicationID (excludes empty/invalid entries)
            $osProducts = Get-CimInstance -ClassName SoftwareLicensingProduct -ErrorAction Stop |
                          Where-Object { $_.ApplicationID -and $_.Name }
        }
        else {
            # Default: Get only Windows products with a product key installed
            $filter = "PartialProductKey IS NOT NULL"
            $osProducts = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter $filter -ErrorAction Stop |
                          Where-Object { $_.ApplicationID -eq $script:WindowsAppId -and -not $_.LicenseIsAddon } |
                          Select-Object -First 1
        }
        
        $licenseService = Get-CimInstance -ClassName SoftwareLicensingService -ErrorAction Stop
        
        if (-not $osProducts -or -not $licenseService) {
            return $null
        }
        
        $results = $osProducts | ForEach-Object {
            $product = $_
            
            # Determine if this is KMS activated (has KMS server configured or discovered)
            $isKmsActivated = ($product.KeyManagementServiceMachine -or $product.DiscoveredKeyManagementServiceMachineName)
            
            # Build base properties
            $properties = [ordered]@{
                Name = $product.Name
                Description = $product.Description
                ActivationID = $product.ID
                ApplicationID = $product.ApplicationID
                ProductKeyID = $product.ProductKeyID
                ProductKeyID2 = $product.ProductKeyID2
                PartialProductKey = $product.PartialProductKey
                LicenseStatus = Get-LicenseStatusString -Status $product.LicenseStatus
                LicenseStatusReason = if ($null -ne $product.LicenseStatusReason) { "0x{0:X}" -f $product.LicenseStatusReason } else { $product.LicenseStatusReason }
                GracePeriodRemaining = $product.GracePeriodRemaining
                EvaluationEndDate = if ($product.EvaluationEndDate -and $product.EvaluationEndDate.Year -gt 1601) { $product.EvaluationEndDate } else { $null }
                ExtendedGrace = Format-ContextualValue -PropertyName 'ExtendedGrace' -Value $product.ExtendedGrace
                LicenseFamily = $product.LicenseFamily
                LicenseIsAddon = $product.LicenseIsAddon
                ProcessorURL = $product.ProcessorURL
                MachineURL = $product.MachineURL
                UseLicenseURL = $product.UseLicenseURL
                ValidationURL = $product.ValidationURL
                OfflineInstallationId = $product.OfflineInstallationId
                RemainingAppReArmCount = Format-ContextualValue -PropertyName 'RemainingAppReArmCount' -Value $product.RemainingAppReArmCount
                RemainingSkuReArmCount = Format-ContextualValue -PropertyName 'RemainingSkuReArmCount' -Value $product.RemainingSkuReArmCount
                RequiredClientCount = Format-ContextualValue -PropertyName 'RequiredClientCount' -Value $product.RequiredClientCount
                TrustedTime = if ($product.TrustedTime -and $product.TrustedTime.Year -gt 1601) { $product.TrustedTime } else { $null }
            }
            
            # Add KMS-related properties only if KMS activated
            if ($isKmsActivated) {
                $properties['KeyManagementServiceMachine'] = $product.KeyManagementServiceMachine
                $properties['KeyManagementServicePort'] = $product.KeyManagementServicePort
                $properties['KeyManagementServiceProductKeyID'] = $product.KeyManagementServiceProductKeyID
                $properties['DiscoveredKeyManagementServiceMachineName'] = $product.DiscoveredKeyManagementServiceMachineName
                $properties['DiscoveredKeyManagementServiceMachinePort'] = $product.DiscoveredKeyManagementServiceMachinePort
                $properties['VLActivationInterval'] = $product.VLActivationInterval
                $properties['VLRenewalInterval'] = $product.VLRenewalInterval
                $properties['KeyManagementServiceLookupDomain'] = $product.KeyManagementServiceLookupDomain
                $properties['KeyManagementServiceListeningPort'] = $product.KeyManagementServiceListeningPort
                $properties['KeyManagementServiceCurrentCount'] = Format-ContextualValue -PropertyName 'KeyManagementServiceCurrentCount' -Value $product.KeyManagementServiceCurrentCount
            }
            
            # Add common service properties
            $properties['Version'] = $licenseService.Version
            $properties['OA3xOriginalProductKey'] = $licenseService.OA3xOriginalProductKey
            $properties['OA3xOriginalProductKeyDescription'] = $licenseService.OA3xOriginalProductKeyDescription
            $properties['OA3xOriginalProductKeyPkPn'] = $licenseService.OA3xOriginalProductKeyPkPn
            $properties['ClientMachineID'] = $licenseService.ClientMachineID
            $properties['RemainingWindowsReArmCount'] = Format-ContextualValue -PropertyName 'RemainingWindowsReArmCount' -Value $licenseService.RemainingWindowsReArmCount
            $properties['IsKeyManagementServiceMachine'] = $licenseService.IsKeyManagementServiceMachine
            
            [PSCustomObject]$properties
        }
        
        return $results
    }
    catch {
        return $null
    }
}

<#
.SYNOPSIS
    Sets OS license activation type.
    
.DESCRIPTION
    Configures the activation type for Windows OS licensing.
    
.PARAMETER ActivationType
    The activation type to set (0-3).
    0 = Default activation
    1 = Active Directory-based activation
    2 = KMS activation
    3 = Token-based activation
    
.EXAMPLE
    Set-OSLicenseInfo -ActivationType 1
    Sets activation type to Active Directory-based activation.
#>
function Set-OSLicenseInfo {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [ValidateRange(0, 3)]
        [int]$ActivationType
    )
    
    try {
        $licenseService = Get-CimInstance -ClassName SoftwareLicensingService -ErrorAction Stop
        
        if ($licenseService) {
            Invoke-CimMethod -InputObject $licenseService -MethodName SetVLActivationTypeEnabled -Arguments @{
                ActivationType = $ActivationType
            } -ErrorAction Stop | Out-Null
            
            return [PSCustomObject]@{
                Success = $true
                ActivationType = $ActivationType
            }
        }
        
        return $null
    }
    catch {
        $errException = $_.Exception
        $hr = $null
        $errMsg = $null
        if ($errException.PSObject.Properties['ErrorData'] -and $errException.ErrorData) {
            $errorCode = $errException.ErrorData.CimInstanceProperties['error_Code']
            if ($errorCode) { $hr = $errorCode.Value }
            $winMsg = $errException.ErrorData.CimInstanceProperties['error_WindowsErrorMessage']
            if ($winMsg -and $winMsg.Value) { $errMsg = $winMsg.Value }
        }
        if (-not $hr) { $hr = $errException.HResult }
        if (-not $errMsg) { $errMsg = $errException.Message }
        return [PSCustomObject]@{
            Success = $false
            ErrorCode = if ($hr) { "0x{0:X8}" -f $hr } else { $null }
            ErrorMessage = if ($errMsg) { $errMsg } else { "$_" }
        }
    }
}

<#
.SYNOPSIS
    Invokes OS license operations.
    
.DESCRIPTION
    Performs various OS licensing operations including product key installation,
    license activation, and system license management.
    
.PARAMETER ClearProductKeyFromRegistry
    Clears the product key from the registry.
    
.PARAMETER InstallProductKey
    Installs a product key.
    
.PARAMETER InstallLicenseFile
    Installs a license file.
    
.PARAMETER ReinstallSystemLicenses
    Reinstalls system licenses.
    
.PARAMETER Rearm
    Rearms the license. Can optionally specify Application ID or SKU.
    
.PARAMETER UninstallProductKey
    Uninstalls a product key using the Activation ID.
    
.PARAMETER ActivateOnline
    Activates the license online using Activation ID.
    
.PARAMETER ActivateOffline
    Activates the license offline using Activation ID and Confirmation ID.
    
.PARAMETER ConfirmationID
    The confirmation ID for offline activation.
    
.PARAMETER TokenCertThumbprint
    Token certificate thumbprint for token-based activation.
    
.PARAMETER TokenPIN
    PIN for token-based activation.
    
.PARAMETER RemoveTokenBasedLicenses
    Removes a token-based license using ILID and ILvID.
    
.PARAMETER ILID
    The ILID of the token-based license to remove.
    
.PARAMETER ILvID
    The ILvID of the token-based license to remove.
    
.EXAMPLE
    Invoke-OSLicense -InstallProductKey "XXXXX-XXXXX-XXXXX-XXXXX-XXXXX"
    Installs the specified product key.
    
.EXAMPLE
    Invoke-OSLicense -ActivateOnline "12345678-1234-1234-1234-123456789012"
    Activates the license online.
    
.EXAMPLE
    Invoke-OSLicense -ClearProductKeyFromRegistry
    Clears the product key from the registry.
#>
function Invoke-OSLicense {
    [CmdletBinding(DefaultParameterSetName='None')]
    param (
        [Parameter(ParameterSetName='ClearKey')]
        [switch]$ClearProductKeyFromRegistry,
        
        [Parameter(ParameterSetName='InstallKey')]
        [string]$InstallProductKey,
        
        [Parameter(ParameterSetName='InstallLicense')]
        [string]$InstallLicenseFile,
        
        [Parameter(ParameterSetName='ReinstallLicenses')]
        [switch]$ReinstallSystemLicenses,
        
        [Parameter(ParameterSetName='Rearm')]
        [switch]$Rearm,

        [Parameter(ParameterSetName='Rearm')]
        [string]$RearmID,
        
        [Parameter(ParameterSetName='UninstallKey')]
        [switch]$UninstallProductKey,

        [Parameter(ParameterSetName='UninstallKey')]
        [Parameter(ParameterSetName='ActivateOnline')]
        [string]$ActivationID,
        
        [Parameter(ParameterSetName='ActivateOnline')]
        [switch]$ActivateOnline,
        
        [Parameter(ParameterSetName='ActivateOffline')]
        [string]$ActivateOffline,
        
        [Parameter(ParameterSetName='ActivateOffline')]
        [string]$ConfirmationID,
        
        [Parameter(ParameterSetName='ActivateToken')]
        [string]$TokenCertThumbprint,
        
        [Parameter(ParameterSetName='ActivateToken')]
        [string]$TokenPIN,
        
        [Parameter(ParameterSetName='RemoveToken')]
        [string]$ILID,
        
        [Parameter(ParameterSetName='RemoveToken')]
        [int]$ILvID
    )
    
    $currentOperation = $null
    $currentProduct = $null
    
    try {
        $licenseService = Get-CimInstance -ClassName SoftwareLicensingService -ErrorAction Stop
        
        if (-not $licenseService) {
            throw (Get-LocalizedString 'NoLicenseFound')
        }

        if ($ClearProductKeyFromRegistry) {
            $currentOperation = 'ClearProductKey'
            Invoke-CimMethod -InputObject $licenseService -MethodName ClearProductKeyFromRegistry -ErrorAction Stop | Out-Null
            
            return [PSCustomObject]@{
                Success = $true
                Operation = $currentOperation
            }
        }
        
        if ($InstallProductKey) {
            $currentOperation = 'InstallProductKey'
            Invoke-CimMethod -InputObject $licenseService -MethodName InstallProductKey -Arguments @{
                ProductKey = $InstallProductKey
            } -ErrorAction Stop | Out-Null
            Invoke-CimMethod -InputObject $licenseService -MethodName RefreshLicenseStatus -ErrorAction SilentlyContinue | Out-Null
            
            return [PSCustomObject]@{
                Success = $true
                Operation = $currentOperation
                ProductKey = $InstallProductKey
            }
        }
        
        if ($InstallLicenseFile) {
            $currentOperation = 'InstallLicenseFile'
            if (-not (Test-Path $InstallLicenseFile)) {
                throw (Get-LocalizedString 'InvalidLicenseFile')
            }
            
            $licenseContent = Get-Content -Path $InstallLicenseFile -Raw -ErrorAction Stop
            Invoke-CimMethod -InputObject $licenseService -MethodName InstallLicense -Arguments @{
                License = $licenseContent
            } -ErrorAction Stop | Out-Null
            
            return [PSCustomObject]@{
                Success = $true
                Operation = $currentOperation
                LicenseFile = $InstallLicenseFile
            }
        }
        
        if ($ReinstallSystemLicenses) {
            $currentOperation = 'ReinstallSystemLicenses'
            $sppTokensFolder = Join-Path $env:SystemRoot 'system32\spp\tokens'
            $oemFolder = Join-Path $env:SystemRoot 'system32\oem'
            $installedFiles = [System.Collections.Generic.List[string]]::new()
            $failedFiles = [System.Collections.Generic.List[string]]::new()

            Get-ChildItem -Path $sppTokensFolder -Filter '*.xrm-ms' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                try {
                    $licContent = Get-Content -Path $_.FullName -Raw -ErrorAction Stop
                    Invoke-CimMethod -InputObject $licenseService -MethodName InstallLicense -Arguments @{
                        License = $licContent
                    } -ErrorAction Stop | Out-Null
                    $installedFiles.Add($_.FullName)
                }
                catch { $failedFiles.Add($_.FullName) }
            }
            
            if (Test-Path $oemFolder) {
                Get-ChildItem -Path $oemFolder -Filter '*.xrm-ms' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                    try {
                        $licContent = Get-Content -Path $_.FullName -Raw -ErrorAction Stop
                        Invoke-CimMethod -InputObject $licenseService -MethodName InstallLicense -Arguments @{
                            License = $licContent
                        } -ErrorAction Stop | Out-Null
                        $installedFiles.Add($_.FullName)
                    }
                    catch { $failedFiles.Add($_.FullName) }
                }
            }

            return [PSCustomObject]@{
                Success = ($failedFiles.Count -eq 0)
                Operation = $currentOperation
                LicensesInstalled = $installedFiles.Count
                LicensesFailed = $failedFiles.Count
                InstalledFiles = $installedFiles.ToArray()
                FailedFiles = $failedFiles.ToArray()
            }
        }
        
        if ($Rearm) {
            $currentOperation = 'Rearm'
            if ($RearmID) {
                # Try lookup by Activation ID first (SKU-level rearm)
                $product = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "ID = '$RearmID'" -ErrorAction Stop
                if ($product) {
                    Invoke-CimMethod -InputObject $product -MethodName ReArmSku -ErrorAction Stop | Out-Null
                }
                else {
                    # Try as Application ID (app-level rearm on the service)
                    Invoke-CimMethod -InputObject $licenseService -MethodName ReArmApp -Arguments @{
                        ApplicationId = $RearmID
                    } -ErrorAction Stop | Out-Null
                }
            }
            else {
                Invoke-CimMethod -InputObject $licenseService -MethodName ReArmWindows -ErrorAction Stop | Out-Null
            }
            
            return [PSCustomObject]@{
                Success = $true
                Operation = $currentOperation
                Target = if ($RearmID) { $RearmID } else { 'Windows' }
                RestartRequired = $true
            }
        }
        
        if ($UninstallProductKey) {
            $currentOperation = 'UninstallProductKey'
            if ($ActivationID) {
                $product = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "ID = '$ActivationID'" -ErrorAction Stop
            }
            else {
                # Auto-detect primary Windows product
                $product = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL" -ErrorAction Stop |
                           Where-Object { $_.ApplicationID -eq $script:WindowsAppId -and -not $_.LicenseIsAddon } |
                           Select-Object -First 1
            }
            if ($product) {
                Invoke-CimMethod -InputObject $product -MethodName UninstallProductKey -ErrorAction Stop | Out-Null
                Invoke-CimMethod -InputObject $licenseService -MethodName RefreshLicenseStatus -ErrorAction SilentlyContinue | Out-Null
                
                return [PSCustomObject]@{
                    Success = $true
                    Operation = $currentOperation
                    ActivationID = $product.ID
                }
            }
            else {
                throw (Get-LocalizedString 'InvalidActivationID')
            }
        }
        
        if ($ActivateOnline) {
            $currentOperation = 'ActivateOnline'
            if ($ActivationID) {
                $product = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "ID = '$ActivationID'" -ErrorAction Stop
            }
            else {
                # Auto-detect active Windows product
                $product = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL" -ErrorAction Stop |
                           Where-Object { $_.ApplicationID -eq $script:WindowsAppId -and -not $_.LicenseIsAddon } |
                           Select-Object -First 1
            }
            if ($product) {
                $currentProduct = $product
                Invoke-CimMethod -InputObject $product -MethodName Activate -ErrorAction Stop | Out-Null
                Invoke-CimMethod -InputObject $licenseService -MethodName RefreshLicenseStatus -ErrorAction SilentlyContinue | Out-Null
                
                return [PSCustomObject]@{
                    Success = $true
                    Operation = $currentOperation
                    ActivationID = $product.ID
                    ProductName = $product.Name
                }
            }
            else {
                throw (Get-LocalizedString 'InvalidActivationID')
            }
        }
        
        if ($ActivateOffline -or $ConfirmationID) {
            $currentOperation = 'ActivateOffline'
            if (-not $ConfirmationID) {
                throw (Get-LocalizedString 'InvalidActivationID')
            }

            if ($ActivateOffline) {
                # Look up by Activation ID first, then by OfflineInstallationId
                $product = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "ID = '$ActivateOffline'" -ErrorAction Stop
                if (-not $product) {
                    $product = Get-CimInstance -ClassName SoftwareLicensingProduct -ErrorAction Stop |
                               Where-Object { $_.OfflineInstallationId -eq $ActivateOffline }
                }
            }
            else {
                # Auto-detect active Windows product
                $product = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL" -ErrorAction Stop |
                           Where-Object { $_.ApplicationID -eq $script:WindowsAppId -and -not $_.LicenseIsAddon -and $_.OfflineInstallationId } |
                           Select-Object -First 1
            }
            if ($product) {
                $currentProduct = $product
                Invoke-CimMethod -InputObject $product -MethodName DepositOfflineConfirmationId -Arguments @{
                    InstallationId = $product.OfflineInstallationId
                    ConfirmationId = $ConfirmationID
                } -ErrorAction Stop | Out-Null
                Invoke-CimMethod -InputObject $licenseService -MethodName RefreshLicenseStatus -ErrorAction SilentlyContinue | Out-Null
                
                return [PSCustomObject]@{
                    Success = $true
                    Operation = $currentOperation
                    ActivationID = $product.ID
                    ProductName = $product.Name
                    ConfirmationID = $ConfirmationID
                }
            }
            else {
                throw (Get-LocalizedString 'InvalidActivationID')
            }
        }
        
        if ($TokenCertThumbprint) {
            $currentOperation = 'ActivateByToken'
            # Token activation is a product-level operation using DepositTokenActivationResponse.
            # First get the product, generate a challenge, then deposit the response with the cert chain.
            $product = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL" -ErrorAction Stop |
                       Where-Object { $_.ApplicationID -and $_.Name } |
                       Select-Object -First 1

            if (-not $product) {
                throw (Get-LocalizedString 'NoLicenseFound')
            }

            $challenge = Invoke-CimMethod -InputObject $product -MethodName GenerateTokenActivationChallenge -ErrorAction Stop

            if ($challenge.ReturnValue -ne 0) {
                throw ((Get-LocalizedString 'ErrorException') -f $challenge.ReturnValue)
            }

            # Retrieve the certificate and chain from the local machine store using the thumbprint
            $cert = Get-ChildItem -Path Cert:\LocalMachine -Recurse | Where-Object { $_.Thumbprint -eq $TokenCertThumbprint } | Select-Object -First 1
            if (-not $cert) {
                throw (Get-LocalizedString 'NoLicenseFound')
            }

            # Build the certificate chain and export as PKCS#7 (CMS) format
            $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
            if (-not $chain.Build($cert)) {
                throw (Get-LocalizedString 'NoLicenseFound')
            }
            $chainCerts = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
            foreach ($element in $chain.ChainElements) {
                $chainCerts.Add($element.Certificate) | Out-Null
            }
            $certChainBytes = $chainCerts.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pkcs7)
            $certChainBase64 = [Convert]::ToBase64String($certChainBytes)

            # Sign the challenge with the certificate's private key
            $rsaKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
            if (-not $rsaKey) {
                throw (Get-LocalizedString 'NoLicenseFound')
            }
            $challengeBytes = [System.Text.Encoding]::UTF8.GetBytes($challenge.Challenge)
            $signatureBytes = $rsaKey.SignData($challengeBytes, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
            $responseBase64 = [Convert]::ToBase64String($signatureBytes)

            $responseArgs = @{
                Challenge = $challenge.Challenge
                Response  = $responseBase64
                CertChain = $certChainBase64
            }
            if ($TokenPIN) {
                $responseArgs.Add('PIN', $TokenPIN)
            }

            Invoke-CimMethod -InputObject $product -MethodName DepositTokenActivationResponse -Arguments $responseArgs -ErrorAction Stop | Out-Null
            Invoke-CimMethod -InputObject $licenseService -MethodName RefreshLicenseStatus -ErrorAction SilentlyContinue | Out-Null

            return [PSCustomObject]@{
                Success = $true
                Operation = $currentOperation
                CertificateThumbprint = $TokenCertThumbprint
            }
        }
        
        if ($ILID -and $PSBoundParameters.ContainsKey('ILvID')) {
            $currentOperation = 'RemoveTokenBasedLicense'
            $tokenLicense = Get-CimInstance -Namespace root/cimv2 -ClassName SoftwareLicensingTokenActivationLicense -Filter "ILID = '$ILID' AND ILvID = $ILvID" -ErrorAction Stop
            if ($tokenLicense) {
                Invoke-CimMethod -InputObject $tokenLicense -MethodName Uninstall -ErrorAction Stop | Out-Null
                
                return [PSCustomObject]@{
                    Success = $true
                    Operation = $currentOperation
                    ILID = $ILID
                    ILvID = $ILvID
                }
            }
            else {
                throw (Get-LocalizedString 'NoLicenseFound')
            }
        }
        
        return $null
    }
    catch {
        # CIM exceptions store the actual Windows HRESULT in ErrorData.error_Code.
        # For non-CIM exceptions (our own throws), there is no meaningful HRESULT.
        $errException = $_.Exception
        $hr = $null
        $errMsg = $null
        if ($errException.PSObject.Properties['ErrorData'] -and $errException.ErrorData) {
            $errorCode = $errException.ErrorData.CimInstanceProperties['error_Code']
            if ($errorCode) { $hr = $errorCode.Value }
            $winMsg = $errException.ErrorData.CimInstanceProperties['error_WindowsErrorMessage']
            if ($winMsg -and $winMsg.Value) { $errMsg = $winMsg.Value }
        }
        if (-not $errMsg) { $errMsg = $errException.Message }
        $errorResult = [ordered]@{
            Success = $false
            Operation = $currentOperation
            ErrorCode = if ($hr) { "0x{0:X8}" -f $hr } else { $null }
            ErrorMessage = if ($errMsg) { $errMsg } else { "$_" }
        }
        if ($currentProduct) {
            $errorResult['ActivationID'] = $currentProduct.ID
            $errorResult['ProductName'] = $currentProduct.Name
        }
        return [PSCustomObject]$errorResult
    }
}

Export-ModuleMember -Function Get-OSLicenseInfo, Set-OSLicenseInfo, Invoke-OSLicense
