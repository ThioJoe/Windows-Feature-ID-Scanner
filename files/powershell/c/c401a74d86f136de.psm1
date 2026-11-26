###########################################################################
#                                                                         #
#   Module Name: CmdletHelpers.psm1                                        #
#                                                                         #
#   Description: Wrappers for common functions used by all cmdlets.       #
#                                                                         #
#   Copyright (c) Microsoft Corporation. All rights reserved.             #
#                                                                         #
###########################################################################

function CmdletShouldProcess() {
param(
    [Parameter(Mandatory=$true, Position=0)]
    [System.Management.Automation.PSCmdlet] $PSCmdlet,

    [Parameter(Mandatory=$true, Position=1)]
    [object] $Object
    )

    $PSCmdlet.ShouldProcess($Object)
}

function Get-NetworkSwitchRegisteredProfileFromNamespace() {
param(
    [Parameter(Mandatory=$true)]
    [Microsoft.Management.Infrastructure.CimSession]$cimSession,

    [Parameter(Mandatory=$true)]
    [string] $Namespace
    )

    Get-CimInstance -classname CIM_RegisteredProfile -Namespace $Namespace -CimSession $cimSession -ErrorAction Ignore | ? {$_.RegisteredName -ieq 'Ethernet Switch Profile' -and $_.RegisteredOrganization -ieq '1' -and ($_.RegisteredVersion).StartsWith("1.")}
}

# cmdlets should use this, since it will be mocked in unit tests
function Get-NetworkSwitchImplementationNamespace() {
param(
    [Parameter(Mandatory=$true)]
    [Microsoft.Management.Infrastructure.CimSession] $CimSession
    )

    Get-NetworkSwitchImplementationNamespace_Internal -CimSession $CimSession
}

function New-LocalCimInstance() {
param(
    [Parameter(Mandatory=$true)]
    [Microsoft.Management.Infrastructure.CimClass] $CimClass,

    [Parameter(Mandatory=$true)]
    [HashTable] $Property
    )

    New-CimInstance -ClientOnly -CimClass $CimClass -Property $Property
}


# fallback localization data in case it fails to load properly
data networkSwitchLocalizedData
{
    # culture="en-US"
    ConvertFrom-StringData @'
    ErrorMessageNoTarget={0} encountered an error. Ensure that you are using a valid CIM session and that the Ethernet Switch Profile is correctly registered. If you are passing input objects, ensure these are valid instances of the appropriate type. See the Exception member of this error record for more details on the underlying issue.
    ErrorMessageTarget={0} encountered an error while processing {1}. Ensure that you are using a valid CIM session and that the Ethernet Switch Profile is correctly registered. If you are passing input objects, ensure these are valid instances of the appropriate type. See the Exception member of this error record for more details on the underlying issue.
    WarningMessageNoTarget={0} encountered a warning: {1}.
    WarningMessageTarget={0} encountered a warning while processing {1}: {2}.
    UnknownError=An unknown error has occured - error code {0}.
    NoValidAssociatedSwitch=The registered Ethernet Switch Profile is not associated with a conforming switch. Please register your switch as conforming to the Ethernet Switch Profile.
    NoValidAssociatedNamespace=The switch registered as conforming to the Ethernet Switch Profile is not associated with a valid namespace. Please verify your switch implementation and registration.
    NoValidRegisteredProfile=The Ethernet Switch Profile was not registered in root/interop, interop, /root/interop or /interop. Please register the Ethernet Switch Profile in one of these namespaces.
    NoMatchingInstance=Did not find any instances matching search criteria: {0} = {1}.
'@
}

# load localized strings for the locale
Import-LocalizedData networkSwitchLocalizedData -filename NetworkSwitchManager.Resource.psd1

$script:nsLocalizedData = $networkSwitchLocalizedData

function NetworkSwitchExceptionHandler(
    [System.Collections.ArrayList] $ErrorObjects,
    [System.Collections.ArrayList] $WarningObjects,
    [string] $CmdletName,
    [object] $TargetObject) {

    foreach ($ErrorObject in $ErrorObjects) {

        if ($TargetObject) {
            $torExceptionMessage = $script:nsLocalizedData.ErrorMessageTarget -f $CmdletName, $TargetObject
        }
        else {
            $torExceptionMessage = $script:nsLocalizedData.ErrorMessageNoTarget -f $CmdletName
        }

        $baseErrorId = $ErrorObject.FullyQualifiedErrorId
        $errorId = "NetworkSwitchManager : $CmdletName : $baseErrorId"

        $torException = New-Object -TypeName System.Exception -ArgumentList @($torExceptionMessage, $ErrorObject.Exception)

        $torErrorRecord = New-Object -TypeName System.Management.Automation.ErrorRecord `
                                     -ArgumentList @($TorException, `
                                                     $errorId, `
                                                     [System.Management.Automation.ErrorCategory] "NotSpecified", `
                                                     $TargetObject)

        Write-Error -ErrorRecord $torErrorRecord
    }

    foreach ($WarningObject in $WarningObjects) {

        if ($TargetObject) {
            $warningMessage = $script:nsLocalizedData.WarningMessageTarget -f $CmdletName, $TargetObject, $WarningObject.Message
        }
        else {
            $warningMessage = $script:nsLocalizedData.WarningMessageNoTarget -f $CmdletName, $WarningObject.Message
        }

        Write-Warning $warningMessage

    }
}

$global:NETWORK_SWITCH_UNKNOWN_ERROR                 = 0
$global:NETWORK_SWITCH_NO_VALID_ASSOCIATED_SWITCH    = 1
$global:NETWORK_SWITCH_NO_VALID_ASSOCIATED_NAMESPACE = 2
$global:NETWORK_SWITCH_NO_VALID_REGISTERED_PROFILE   = 3
$global:NETWORK_SWITCH_NO_MATCHING_INSTANCE          = 4

$script:nsCustomErrorMessages = @(
    $script:nsLocalizedData.UnknownError,
    $script:nsLocalizedData.NoValidAssociatedSwitch,
    $script:nsLocalizedData.NoValidAssociatedNamespace,
    $script:nsLocalizedData.NoValidRegisteredProfile,
    $script:nsLocalizedData.NoMatchingInstance
    )

function NetworkSwitchErrorHandler(
    [int] $ErrorCode,
    [string] $CmdletName,
    [object] $TargetObject,
    [object] $ExtraData1,
    [object] $ExtraData2) {

    $baseMessage = $script:nsCustomErrorMessages[$ErrorCode]

    if (($ErrorCode -ne 0) -and $baseMessage) {
        $message = $baseMessage -f $ExtraData1, $ExtraData2
    }
    else {
        $message = $script:nsCustomErrorMessages[$global:NETWORK_SWITCH_UNKNOWN_ERROR] -f $ErrorCode
    }

    $nsErrorId = "Error_$ErrorCode"
    $nsException = New-Object -TypeName System.Exception -ArgumentList @($message)
    $nsErrorRecord = New-Object -TypeName System.Management.Automation.ErrorRecord `
                                -ArgumentList @($nsException, `
                                                $nsErrorId, `
                                                [System.Management.Automation.ErrorCategory] "NotSpecified", `
                                                $TargetObject)

    NetworkSwitchExceptionHandler -ErrorObjects @($nsErrorRecord) `
                                  -CmdletName $CmdletName `
                                  -TargetObject $TargetObject
}



function Get-NetworkSwitchService(
    [string] $Namespace,
    [Microsoft.Management.Infrastructure.CimSession] $CimSession,
    [string] $CmdletName) {

    $switchService = Get-CimInstance -ClassName MSFT_SwitchService `
                                     -Namespace $Namespace `
                                     -CimSession $CimSession `
                                     -ErrorVariable cimError `
                                     -WarningVariable cimWarning `
                                     -ErrorAction SilentlyContinue `
                                     -WarningAction SilentlyContinue `

    NetworkSwitchExceptionHandler -ErrorObject $cimError `
                                  -WarningObject $cimWarning `
                                  -CmdletName $cmdletName `
                                  -TargetObject $port

    $switchService
}


function Get-NetworkSwitchAssociatedInstance(
    [Microsoft.Management.Infrastructure.CimInstance] $InputObject,
    [Microsoft.Management.Infrastructure.CimSession] $CimSession,
    [string] $CmdletName,
    [string] $ResultClassName
    ) {

    $instances = Get-CimAssociatedInstance -InputObject $InputObject `
                                           -ResultClassName $ResultClassName `
                                           -CimSession $CimSession `
                                           -ErrorVariable cimError `
                                           -WarningVariable cimWarning `
                                           -ErrorAction SilentlyContinue `
                                           -WarningAction SilentlyContinue 

    NetworkSwitchExceptionHandler -ErrorObject $cimError `
                                  -WarningObject $cimWarning `
                                  -CmdletName $cmdletName `
                                  -TargetObject $InputObject
    $instances
}

function Get-NetworkSwitchClass(
    [Microsoft.Management.Infrastructure.CimSession] $CimSession,
    [string] $ClassName,
    [string] $Namespace,
    [string] $CmdletName) {

    $classDef = Get-CimClass -Namespace $Namespace `
                             -ClassName $ClassName `
                             -CimSession $CimSession `
                             -ErrorVariable cimError `
                             -WarningVariable cimWarning `
                             -ErrorAction SilentlyContinue `
                             -WarningAction SilentlyContinue

    NetworkSwitchExceptionHandler -ErrorObject $cimError `
                                  -WarningObject $cimWarning `
                                  -CmdletName $cmdletName `
                                  -TargetObject $InputObject

    $classDef
}

function Set-NetworkSwitchInstance(
    [Microsoft.Management.Infrastructure.CimSession] $CimSession,
    [Microsoft.Management.Infrastructure.CimInstance] $InputObject,
    [HashTable] $Property,
    [string] $CmdletName) {

    Set-CimInstance -InputObject $InputObject `
                    -Property $Property `
                    -CimSession $CimSession `
                    -Confirm:$false `
                    -ErrorVariable cimError `
                    -WarningVariable cimWarning `
                    -ErrorAction SilentlyContinue `
                    -WarningAction SilentlyContinue `
                    1>$null

    NetworkSwitchExceptionHandler -ErrorObject $cimError `
                                  -WarningObject $cimWarning `
                                  -CmdletName $cmdletName `
                                  -TargetObject $InputObject
}

function Get-NetworkSwitchInstanceNoFilter(
    [string] $Namespace,
    [string] $ClassName,
    [Microsoft.Management.Infrastructure.CimSession] $CimSession,
    [string] $CmdletName) {

    $insts = Get-CimInstance -NameSpace $Namespace `
                             -ClassName $ClassName `
                             -CimSession $CimSession `
                             -ErrorVariable cimError `
                             -WarningVariable cimWarning `
                             -ErrorAction SilentlyContinue `
                             -WarningAction SilentlyContinue

    NetworkSwitchExceptionHandler -ErrorObject $cimError `
                                  -WarningObject $cimWarning `
                                  -CmdletName $CmdletName
    $insts
}

function Filter-NetworkSwitchInstance(
    [Microsoft.Management.Infrastructure.CimInstance[]] $Instances,
    [string] $Property,
    [object] $Value,
    [switch] $UseLike,
    [switch] $UseContains,
    [switch] $AssertNonEmpty,
    [string] $CmdletName) {

    $insts = $null
    if ($Instances) {
        if ($UseLike) {
            $insts = $Instances | where {$_.CimInstanceProperties[$Property].Value -like $Value}
        }
        elseif ($UseContains) {
            $insts = $Instances | where {$Value -contains $_.CimInstanceProperties[$Property].Value}
        }
        else {
            $insts = $Instances | where {$_.CimInstanceProperties[$Property].Value -eq $Value}
        }
    }

    if ($AssertNonEmpty -and (-not $insts)) {
        NetworkSwitchErrorHandler -ErrorCode $global:NETWORK_SWITCH_NO_MATCHING_INSTANCE `
                                  -CmdletName $CmdletName `
                                  -ExtraData1 $Property `
                                  -ExtraData2 $Value
    }

    $insts
}

function Invoke-NetworkSwitchMethod(
    [Microsoft.Management.Infrastructure.CimInstance] $Instance,
    [Microsoft.Management.Infrastructure.CimSession] $CimSession,
    [string] $MethodName,
    [HashTable] $Arguments,
    [string] $CmdletName) {

    Invoke-CimMethod -InputObject $Instance `
                     -MethodName $MethodName `
                     -Arguments  $Arguments `
                     -CimSession $CimSession `
                     -Confirm:$false `
                     -ErrorVariable cimError `
                     -WarningVariable cimWarning `
                     -ErrorAction SilentlyContinue `
                     -WarningAction SilentlyContinue `
                     1>$null

    NetworkSwitchExceptionHandler -ErrorObject $cimError `
                                  -WarningObject $cimWarning `
                                  -CmdletName $cmdletName `
                                  -TargetObject $Instance
}

#cmdlets should never use this; it will be unit-tested.
function Get-NetworkSwitchImplementationNamespace_Internal() {
param(
    [Parameter(Mandatory=$true)]
    [Microsoft.Management.Infrastructure.CimSession]$cimSession
    )

    $cmdletName = "Get-NetworkSwitchImplementationNamespace"
    $ethernetSwitchProfile = Get-NetworkSwitchRegisteredProfileFromNamespace -CimSession $CimSession -Namespace root/interop

    if (-not $ethernetSwitchProfile) {
        $ethernetSwitchProfile = Get-NetworkSwitchRegisteredProfileFromNamespace -CimSession $CimSession -Namespace interop
    }

    if (-not $ethernetSwitchProfile) {
        $ethernetSwitchProfile = Get-NetworkSwitchRegisteredProfileFromNamespace -CimSession $CimSession -Namespace /root/interop
    }

    if (-not $ethernetSwitchProfile) {
        $ethernetSwitchProfile = Get-NetworkSwitchRegisteredProfileFromNamespace -CimSession $CimSession -Namespace /interop
    }

    if (-not $ethernetSwitchProfile) {
        NetworkSwitchErrorHandler -ErrorCode $global:NETWORK_SWITCH_NO_VALID_REGISTERED_PROFILE `
                                  -CmdletName $cmdletName
        return
    }

    $computerSystem = Get-CimAssociatedInstance -InputObject $ethernetSwitchProfile -ResultClassName CIM_ComputerSystem -CimSession $CimSession

    if(-not $computerSystem) {
        NetworkSwitchErrorHandler -ErrorCode $global:NETWORK_SWITCH_NO_VALID_ASSOCIATED_SWITCH `
                                  -CmdletName $cmdletName
        return
    }

    $namespace = $computerSystem.CimSystemProperties.Namespace
 
    if(-not $namespace) {
        NetworkSwitchErrorHandler -ErrorCode $global:NETWORK_SWITCH_NO_VALID_ASSOCIATED_NAMESPACE `
                                  -CmdletName $cmdletName
        return
    }
    
    $namespace
}

Export-ModuleMember -Function *