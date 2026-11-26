$script:modulePath = Split-Path -Parent $PSCommandPath
$script:WindowsAppId = '55c92734-d682-4d71-983e-d6ec3f16059f'
Import-LocalizedData -BindingVariable LocalizedData -BaseDirectory $modulePath -FileName "LicenseInfoData"

function Get-LocalizedString {
    param([string]$Key)
    return $LocalizedData[$Key]
}


<#
.SYNOPSIS
    Get Active Directory license info
    
.DESCRIPTION
    Retrieves AD-based licensing information, including activation objects and forest installation ID.
    
.PARAMETER ForestInstallationId
    Product key to get forest installation ID for
    
.PARAMETER ActivationObjects
    List all AD activation objects
    
.EXAMPLE
    Get-ADLicenseInfo
    
.EXAMPLE
    Get-ADLicenseInfo -ForestInstallationId "XXXXX-XXXXX-XXXXX-XXXXX-XXXXX"
    
.EXAMPLE
    Get-ADLicenseInfo -ActivationObjects
#>
function Get-ADLicenseInfo {
    [CmdletBinding(DefaultParameterSetName='Default')]
    param (
        [Parameter(ParameterSetName='ForestInstallationId')]
        [string]$ProductKey,
        
        [Parameter(ParameterSetName='ActivationObjects')]
        [switch]$ActivationObjects
    )
    
    try {
        $licenseService = Get-CimInstance -ClassName SoftwareLicensingService -ErrorAction Stop
        
        if (-not $licenseService) {
            return $null
        }

        if ($ProductKey) {
            $result = Invoke-CimMethod -InputObject $licenseService -MethodName GenerateActiveDirectoryOfflineActivationId -Arguments @{
                ProductKey = $ProductKey
            } -ErrorAction Stop
            
            return [PSCustomObject]@{
                ProductKey = $ProductKey
                ForestInstallationId = $result.InstallationID
            }
        }

        if ($ActivationObjects) {
            try {
                if (Get-Module -ListAvailable -Name ActiveDirectory) {
                    Import-Module ActiveDirectory -ErrorAction SilentlyContinue
                    
                    $searchBase = (Get-ADRootDSE -ErrorAction Stop).configurationNamingContext
                    $activationObjectsPath = "CN=Activation Objects,CN=Microsoft SPP,$searchBase"
                    
                    $adObjects = Get-ADObject -SearchBase $activationObjectsPath -Filter * -Properties * -ErrorAction Stop
                    
                    return $adObjects | ForEach-Object {
                        [PSCustomObject]@{
                            DistinguishedName = $_.DistinguishedName
                            Name= $_.Name
                            ObjectClass = $_.ObjectClass
                            Created = $_.Created
                            Modified = $_.Modified
                        }
                    }
                }
                else {
                    $rootDSE = [ADSI]"LDAP://RootDSE"
                    $configNC = $rootDSE.configurationNamingContext
                    $activationObjectsPath = "LDAP://CN=Activation Objects,CN=Microsoft SPP,$configNC"
                    
                    $searcher = New-Object System.DirectoryServices.DirectorySearcher
                    $searcher.SearchRoot = [ADSI]$activationObjectsPath
                    $searcher.Filter = "(objectClass=*)"
                    $results = $searcher.FindAll()
                    
                    return $results | ForEach-Object {
                        [PSCustomObject]@{
                            DistinguishedName = if ($_.Properties["distinguishedName"].Count -gt 0) { $_.Properties["distinguishedName"][0] } else { $null }
                            Name = if ($_.Properties["name"].Count -gt 0) { $_.Properties["name"][0] } else { $null }
                            ObjectClass = if ($_.Properties["objectClass"].Count -gt 0) { $_.Properties["objectClass"][0] } else { $null }
                        }
                    }
                }
            }
            catch {
                return $null
            }
        }
        
        $osProduct = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL" -ErrorAction SilentlyContinue |
                     Where-Object { $_.ApplicationID -eq $script:WindowsAppId -and -not $_.LicenseIsAddon } |
                     Select-Object -First 1
        
        if ($osProduct) {
            return [PSCustomObject]@{
                Name = $osProduct.Name
                Description= $osProduct.Description
                ActivationID = $osProduct.ID
                LicenseStatus = switch ($osProduct.LicenseStatus) {
                    0 { Get-LocalizedString 'LicenseStatusUnlicensed' }
                    1 { Get-LocalizedString 'LicenseStatusLicensed' }
                    2 { Get-LocalizedString 'LicenseStatusOOBGrace' }
                    3 { Get-LocalizedString 'LicenseStatusOOTGrace' }
                    4 { Get-LocalizedString 'LicenseStatusNonGenuineGrace' }
                    5{ Get-LocalizedString 'LicenseStatusNotification' }
                    6 { Get-LocalizedString 'LicenseStatusExtendedGrace' }
                    default { (Get-LocalizedString 'LicenseStatusUnknown') + " ($($osProduct.LicenseStatus))" }
                }
                ADActivationObjectName = $osProduct.ADActivationObjectName
                ADActivationObjectDN = $osProduct.ADActivationObjectDN
                ADActivationCsvlkPid = $osProduct.ADActivationCsvlkPid
                ADActivationCsvlkSkuId = $osProduct.ADActivationCsvlkSkuId
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
    Perform AD licensing operations
    
.DESCRIPTION
    Run AD-based licensing tasks including activation and managing activation objects.
    
.PARAMETER ActivateOnline
    Activate online via Active Directory
    
.PARAMETER ActivateForest
    Activate using AD forest
    
.PARAMETER ProductKey
    Product key to use for activation
    
.PARAMETER ConfirmationID
    Confirmation ID for offline activation
    
.PARAMETER ActivationObjectName
    Name of the activation object
    
.PARAMETER DeleteActivationObjects
    Delete activation object by DN or RDN
    
.EXAMPLE
    Invoke-ADLicense -ActivateOnline -ProductKey "XXXXX-XXXXX-XXXXX-XXXXX-XXXXX"
    Does online AD activation.
    
.EXAMPLE
    Invoke-ADLicense -ActivateForest -ProductKey "XXXXX-XXXXX-XXXXX-XXXXX-XXXXX" -ConfirmationID "123456"
    Does forest AD activation.
    
.EXAMPLE
    Invoke-ADLicense -DeleteActivationObjects "CN=MyActivationObject,CN=Activation Objects,CN=Microsoft SPP,CN=Configuration,DC=contoso,DC=com"
    Deletes the activation object.
#>
function Invoke-ADLicense {
    [CmdletBinding(DefaultParameterSetName='None')]
    param (
        [Parameter(ParameterSetName='ActivateOnline')]
        [switch]$ActivateOnline,
        
        [Parameter(ParameterSetName='ActivateForest')]
        [switch]$ActivateForest,
        
        [Parameter(ParameterSetName='ActivateOnline')]
        [Parameter(ParameterSetName='ActivateForest')]
        [string]$ProductKey,
        
        [Parameter(ParameterSetName='ActivateOnline')]
        [Parameter(ParameterSetName='ActivateForest')]
        [string]$ConfirmationID,
        
        [Parameter(ParameterSetName='ActivateOnline')]
        [Parameter(ParameterSetName='ActivateForest')]
        [string]$ActivationObjectName,
        
        [Parameter(ParameterSetName='DeleteActivationObjects')]
        [string]$DeleteActivationObjects
    )
    
    try {
        $licenseService = Get-CimInstance -ClassName SoftwareLicensingService -ErrorAction Stop
        
        if (-not $licenseService) {
            return $null
        }
        
        if ($ActivateOnline -or $ActivateForest) {
            if (-not $ProductKey) {
                throw (Get-LocalizedString 'NoLicenseFound')
            }
            
            if ($ActivateOnline) {
                $adArgs = @{
                    ProductKey = $ProductKey
                    ActivationObjectName = if ($ActivationObjectName) { $ActivationObjectName } else { '' }
                }
                
                Invoke-CimMethod -InputObject $licenseService -MethodName DoActiveDirectoryOnlineActivation -Arguments $adArgs -ErrorAction Stop | Out-Null
            }
            elseif ($ActivateForest) {
                if (-not $ConfirmationID) {
                    throw (Get-LocalizedString 'NoLicenseFound')
                }
                
                $adArgs = @{
                    ProductKey = $ProductKey
                    ConfirmationID = $ConfirmationID
                    ActivationObjectName = if ($ActivationObjectName) { $ActivationObjectName } else { '' }
                }
                
                Invoke-CimMethod -InputObject $licenseService -MethodName DepositActiveDirectoryOfflineActivationConfirmation -Arguments $adArgs -ErrorAction Stop | Out-Null
            }
            
            return [PSCustomObject]@{
                Success = $true
                Operation = if ($ActivateOnline) { 'ActivateOnline' } else { 'ActivateForest' }
                ProductKey = $ProductKey
                ActivationObjectName = $ActivationObjectName
            }
        }
        
        if ($DeleteActivationObjects) {
            try {
                # Try to use Active Directory module if available
                if (Get-Module -ListAvailable -Name ActiveDirectory) {
                    Import-Module ActiveDirectory -ErrorAction SilentlyContinue
                    
                    if ($DeleteActivationObjects -match '^CN=') {
                        Remove-ADObject -Identity $DeleteActivationObjects -Confirm:$false -ErrorAction Stop
                    }
                    else {
                        $rootDSE = Get-ADRootDSE -ErrorAction Stop
                        $configNC = $rootDSE.configurationNamingContext
                        $fullDN = "CN=$DeleteActivationObjects,CN=Activation Objects,CN=Microsoft SPP,$configNC"
                        Remove-ADObject -Identity $fullDN -Confirm:$false -ErrorAction Stop
                    }
                }
                else {
                    if ($DeleteActivationObjects -match '^CN=') {
                        $objectPath = "LDAP://$DeleteActivationObjects"
                    }
                    else {
                        $rootDSE = [ADSI]"LDAP://RootDSE"
                        $configNC = $rootDSE.configurationNamingContext
                        $objectPath = "LDAP://CN=$DeleteActivationObjects,CN=Activation Objects,CN=Microsoft SPP,$configNC"
                    }
                    
                    $adObject = [ADSI]$objectPath
                    $adObject.DeleteTree()
                }
                
                return [PSCustomObject]@{
                    Success = $true
                    Operation= 'DeleteActivationObject'
                    ActivationObject = $DeleteActivationObjects
                }
            }
            catch {
                throw (Get-LocalizedString 'InvalidActivationObject')
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
        if (-not $errMsg) { $errMsg = $errException.Message }
        return [PSCustomObject]@{
            Success = $false
            ErrorCode = if ($hr) { "0x{0:X8}" -f $hr } else { $null }
            ErrorMessage = if ($errMsg) { $errMsg } else { "$_" }
        }
    }
}

Export-ModuleMember -Function Get-ADLicenseInfo, Invoke-ADLicense
