$script:modulePath = Split-Path -Parent $PSCommandPath
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
    
    Write-Verbose (Get-LocalizedString 'OSLicenseInfoVerbose')
    
    try {
        if ($TokenBasedLicenses) {
            $tokenLicenses = Get-CimInstance -Namespace root/cimv2 -ClassName SoftwareLicensingTokenActivationLicense -ErrorAction SilentlyContinue
            
            if (-not $tokenLicenses) {
                Write-Verbose (Get-LocalizedString 'NoLicenseFound')
                return $null
            }
            
            return $tokenLicenses | ForEach-Object {
                [PSCustomObject]@{
                    ILID = $_.ILID
                    ILvID= $_.ILvID
                    AuthorizationStatus = $_.AuthorizationStatus
                    Description = $_.Description
                    ExpirationDate = $_.ExpirationDate
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
                          Where-Object { $_.Name -match 'Windows' } |
                          Select-Object -First 1
        }
        
        $licenseService = Get-CimInstance -ClassName SoftwareLicensingService -ErrorAction Stop
        
        if (-not $osProducts -or -not $licenseService) {
            Write-Verbose (Get-LocalizedString 'NoLicenseFound')
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
                EvaluationEndDate = $product.EvaluationEndDate
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
                TrustedTime = $product.TrustedTime
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
        Write-Debug ((Get-LocalizedString 'ErrorException') -f $_)
        Write-Error $_
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
    
    Write-Verbose (Get-LocalizedString 'OSLicenseInfoVerbose')
    
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
        Write-Debug ((Get-LocalizedString 'ErrorException') -f $_)
        Write-Error $_
        return $null
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
        [string]$Rearm,
        
        [Parameter(ParameterSetName='UninstallKey')]
        [string]$UninstallProductKey,
        
        [Parameter(ParameterSetName='ActivateOnline')]
        [string]$ActivateOnline,
        
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
    
    try {
        $licenseService = Get-CimInstance -ClassName SoftwareLicensingService -ErrorAction Stop
        
        if (-not $licenseService) {
            throw (Get-LocalizedString 'NoLicenseFound')
        }

        if ($ClearProductKeyFromRegistry) {
            Invoke-CimMethod -InputObject $licenseService -MethodName ClearProductKeyFromRegistry -ErrorAction Stop | Out-Null
            
            return [PSCustomObject]@{
                Success = $true
                Operation = 'ClearProductKey'
            }
        }
        
        if ($InstallProductKey) {
            Invoke-CimMethod -InputObject $licenseService -MethodName InstallProductKey -Arguments @{
                ProductKey = $InstallProductKey
            } -ErrorAction Stop | Out-Null
            
            return [PSCustomObject]@{
                Success = $true
                Operation = 'InstallProductKey'
                ProductKey = $InstallProductKey
            }
        }
        
        if ($InstallLicenseFile) {
            if (-not (Test-Path $InstallLicenseFile)) {
                throw (Get-LocalizedString 'InvalidLicenseFile')
            }
            
            Invoke-CimMethod -InputObject $licenseService -MethodName InstallLicense -Arguments @{
                LicenseFile = $InstallLicenseFile
            } -ErrorAction Stop | Out-Null
            
            return [PSCustomObject]@{
                Success = $true
                Operation = 'InstallLicenseFile'
                LicenseFile = $InstallLicenseFile
            }
        }
        
        if ($ReinstallSystemLicenses) {
            Invoke-CimMethod -InputObject $licenseService -MethodName RefreshLicenseStatus -ErrorAction Stop | Out-Null
            
            return [PSCustomObject]@{
                Success = $true
                Operation = 'ReinstallSystemLicenses'
            }
        }
        
        if ($Rearm) {
            if ($Rearm -eq [string]::Empty -or $Rearm -eq $true) {
                Invoke-CimMethod -InputObject $licenseService -MethodName ReArmWindows -ErrorAction Stop | Out-Null
            }
            else {
                # Rearm specific application or SKU
                $product = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "ID = '$Rearm'" -ErrorAction Stop
                if ($product) {
                    Invoke-CimMethod -InputObject $product -MethodName ReArmSKU -ErrorAction Stop | Out-Null
                }
                else {
                    throw (Get-LocalizedString 'InvalidActivationID')
                }
            }
            
            return [PSCustomObject]@{
                Success = $true
                Operation = 'Rearm'
                Target = $Rearm
            }
        }
        
        if ($UninstallProductKey) {
            $product = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "ID = '$UninstallProductKey'" -ErrorAction Stop
            if ($product) {
                Invoke-CimMethod -InputObject $product -MethodName UninstallProductKey -ErrorAction Stop | Out-Null
                
                return [PSCustomObject]@{
                    Success = $true
                    Operation = 'UninstallProductKey'
                    ActivationID = $UninstallProductKey
                }
            }
            else {
                throw (Get-LocalizedString 'InvalidActivationID')
            }
        }
        
        if ($ActivateOnline) {
            $product = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "ID = '$ActivateOnline'" -ErrorAction Stop
            if ($product) {
                Invoke-CimMethod -InputObject $product -MethodName Activate -ErrorAction Stop | Out-Null
                
                return [PSCustomObject]@{
                    Success = $true
                    Operation = 'ActivateOnline'
                    ActivationID = $ActivateOnline
                }
            }
            else {
                throw (Get-LocalizedString 'InvalidActivationID')
            }
        }
        
        if ($ActivateOffline) {
            $product = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "ID = '$ActivateOffline'" -ErrorAction Stop
            if ($product) {
                Invoke-CimMethod -InputObject $product -MethodName DepositOfflineConfirmationId -Arguments @{
                    ConfirmationId = $ConfirmationID
                } -ErrorAction Stop | Out-Null
                
                return [PSCustomObject]@{
                    Success = $true
                    Operation = 'ActivateOffline'
                    ActivationID = $ActivateOffline
                    ConfirmationID = $ConfirmationID
                }
            }
            else {
                throw (Get-LocalizedString 'InvalidActivationID')
            }
        }
        
        if ($TokenCertThumbprint) {
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

            return [PSCustomObject]@{
                Success = $true
                Operation = 'ActivateByToken'
                CertificateThumbprint = $TokenCertThumbprint
            }
        }
        
        if ($ILID -and $PSBoundParameters.ContainsKey('ILvID')) {
            $tokenLicense = Get-CimInstance -Namespace root/cimv2 -ClassName SoftwareLicensingTokenActivationLicense -Filter "ILID = '$ILID' AND ILvID = $ILvID" -ErrorAction Stop
            if ($tokenLicense) {
                Invoke-CimMethod -InputObject $tokenLicense -MethodName Uninstall -ErrorAction Stop | Out-Null
                
                return [PSCustomObject]@{
                    Success = $true
                    Operation = 'RemoveTokenBasedLicense'
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
        Write-Debug ((Get-LocalizedString 'ErrorException') -f $_)
        Write-Error $_
        return $null
    }
}

Export-ModuleMember -Function Get-OSLicenseInfo, Set-OSLicenseInfo, Invoke-OSLicense
