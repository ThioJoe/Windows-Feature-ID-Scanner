###########################################################################
#                                                                         #
#   Module Name: NetworkSwitchVlan.psm1                                    #
#                                                                         #
#   Description: Cmdlets for managing VLANs                               #
#                                                                         #
#   Copyright (c) Microsoft Corporation. All rights reserved.             #
#                                                                         #
###########################################################################

import-module "$PSScriptRoot\CmdletHelpers.psm1" -Force -DisableNameChecking

function Disable-NetworkSwitchVlan() {
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)]
    [Microsoft.Management.Infrastructure.CimSession] $CimSession,

    [Parameter(Mandatory=$true, ParameterSetName="InstanceIdSet")]
    [string] $InstanceId,

    [Parameter(Mandatory=$true, ParameterSetName="NameSet")]
    [string] $Name,

    [Parameter(Mandatory=$true, ParameterSetName="VlanIdSet")]
    [int] $VlanID
    )

    Begin {
        $cmdletName = "Disable-NetworkSwitchVlan"
        $nsNamespace = Get-NetworkSwitchImplementationNamespace -CimSession $CimSession
    }

    Process {
        if (-not $nsNamespace) { return }

        $vlans = Get-NetworkSwitchInstanceNoFilter -Namespace $nsNamespace `
                                                   -ClassName CIM_NetworkVLAN `
                                                   -CimSession $CimSession `
                                                   -CmdletName $cmdletName

        if ($InstanceId) {
            $vlans = Filter-NetworkSwitchInstance -Instances $vlans `
                                                  -Property InstanceId `
                                                  -Value $InstanceId `
                                                  -AssertNonEmpty `
                                                  -CmdletName $cmdletName
        }
        elseif ($VlanID) {
            $vlans = Filter-NetworkSwitchInstance -Instances $vlans `
                                                  -Property VlanId `
                                                  -Value $VlanId `
                                                  -AssertNonEmpty `
                                                  -CmdletName $cmdletName
        }
        elseif ($Name) {
            $vlans = Filter-NetworkSwitchInstance -Instances $vlans `
                                                  -Property ElementName `
                                                  -Value $Name `
                                                  -UseLike `
                                                  -CmdletName $cmdletName
        }

        $switchService = Get-NetworkSwitchService -Namespace $nsNamespace `
                                                  -CimSession $CimSession `
                                                  -CmdletName $cmdletName
        foreach ($vlan in $vlans) {
            if ($(CmdletShouldProcess $PSCmdlet $vlan)) {
                Invoke-NetworkSwitchMethod -Instance $switchService[0] `
                                           -CimSession $CimSession `
                                           -MethodName "DisableVLAN" `
                                           -Arguments @{VLAN = [ciminstance[]]@($vlan)} `
                                           -CmdletName $cmdletName
            }
        }
    }

    End {}
}

function Enable-NetworkSwitchVlan() {
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)]
    [Microsoft.Management.Infrastructure.CimSession] $CimSession,

    [Parameter(Mandatory=$true, ParameterSetName="InstanceIdSet")]
    [string] $InstanceId,

    [Parameter(Mandatory=$true, ParameterSetName="NameSet")]
    [string] $Name,

    [Parameter(Mandatory=$true, ParameterSetName="VlanIdSet")]
    [int] $VlanID
    )

    Begin {
        $cmdletName = "Enable-NetworkSwitchVlan"
        $nsNamespace = Get-NetworkSwitchImplementationNamespace -CimSession $CimSession
    }

    Process {
        if (-not $nsNamespace) { return }

        $vlans = Get-NetworkSwitchInstanceNoFilter -Namespace $nsNamespace `
                                                   -ClassName CIM_NetworkVLAN `
                                                   -CimSession $CimSession `
                                                   -CmdletName $cmdletName

        if ($InstanceId) {
            $vlans = Filter-NetworkSwitchInstance -Instances $vlans `
                                                  -Property InstanceId `
                                                  -Value $InstanceId `
                                                  -AssertNonEmpty `
                                                  -CmdletName $cmdletName
        }
        elseif ($VlanID) {
            $vlans = Filter-NetworkSwitchInstance -Instances $vlans `
                                                  -Property VlanId `
                                                  -Value $VlanId `
                                                  -AssertNonEmpty `
                                                  -CmdletName $cmdletName
        }
        elseif ($Name) {
            $vlans = Filter-NetworkSwitchInstance -Instances $vlans `
                                                  -Property ElementName `
                                                  -Value $Name `
                                                  -UseLike `
                                                  -CmdletName $cmdletName
        }

        $switchService = Get-NetworkSwitchService -Namespace $nsNamespace `
                                                  -CimSession $CimSession `
                                                  -CmdletName $cmdletName
        foreach ($vlan in $vlans) {
            if ($(CmdletShouldProcess $PSCmdlet $vlan)) {
                Invoke-NetworkSwitchMethod -Instance $switchService[0] `
                                           -CimSession $CimSession `
                                           -MethodName "EnableVLAN" `
                                           -Arguments @{VLAN = [ciminstance[]]@($vlan)} `
                                           -CmdletName $cmdletName
            }
        }
    }

    End {}
}

function Get-NetworkSwitchVlan() {
[CmdletBinding(DefaultParameterSetName="NameSet")]
[OutputType([Microsoft.Management.Infrastructure.CimInstance])]
[OutputType("Microsoft.Management.Infrastructure.CimInstance#CIM_NetworkVLAN")]
param(
    [Parameter(Mandatory=$true)]
    [Microsoft.Management.Infrastructure.CimSession] $CimSession,

    [Parameter(Mandatory=$false, ParameterSetName="NameSet")]
    [string] $Name,

    [Parameter(Mandatory=$true, ParameterSetName="VlanIdSet")]
    [int] $VlanId,

    [Parameter(Mandatory=$true, ParameterSetName="InstanceIdSet")]
    [string] $InstanceId,

    [Parameter(Mandatory=$true, ParameterSetName="CaptionSet")]
    [string] $Caption,

    [Parameter(Mandatory=$true, ParameterSetName="DescriptionSet")]
    [string] $Description
    )

    Begin {
        $cmdletName = "Get-NetworkSwitchVlan"
        $nsNamespace = Get-NetworkSwitchImplementationNamespace -CimSession $CimSession
    }

    Process {
        if (-not $nsNamespace) { return }

        $vlanList = Get-NetworkSwitchInstanceNoFilter -ClassName CIM_NetworkVlan `
                                                      -Namespace $nsNamespace `
                                                      -CimSession $CimSession `
                                                      -CmdletName $cmdletName

        if ($Name) {
            $vlanList = Filter-NetworkSwitchInstance -Instances $vlanList `
                                                     -Property ElementName `
                                                     -Value $Name `
                                                     -UseLike `
                                                     -CmdletName $cmdletName
        }
        elseif ($Caption) {
            $vlanList = Filter-NetworkSwitchInstance -Instances $vlanList `
                                                     -Property Caption `
                                                     -Value $Caption `
                                                     -UseLike `
                                                     -CmdletName $cmdletName
        }
        elseif ($Description) {
            $vlanList = Filter-NetworkSwitchInstance -Instances $vlanList `
                                                     -Property Description `
                                                     -Value $Description `
                                                     -UseLike `
                                                     -CmdletName $cmdletName
        }
        elseif ($VlanId) {
            $vlanList = Filter-NetworkSwitchInstance -Instances $vlanList `
                                                     -Property VlanId `
                                                     -Value $VlanId `
                                                     -AssertNonEmpty `
                                                     -CmdletName $cmdletName
        }
        elseif ($InstanceId) {
            $vlanList = Filter-NetworkSwitchInstance -Instances $vlanList `
                                                     -Property InstanceId `
                                                     -Value $InstanceId `
                                                     -AssertNonEmpty `
                                                     -CmdletName $cmdletName
        }

        $vlanList
    }

    End {}
}

function New-NetworkSwitchVlan() {
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [Microsoft.Management.Infrastructure.CimSession] $CimSession,

    [Parameter(Mandatory=$false)]
    [string] $Caption,

    [Parameter(Mandatory=$false)]
    [string] $Description,

    [Parameter(Mandatory=$true)]
    [int] $VlanID,

    [Parameter(Mandatory=$true)]
    [string] $Name
    )

    Begin {
        $cmdletName = "New-NetworkSwitchVlan"
        $nsNamespace = Get-NetworkSwitchImplementationNamespace -CimSession $CimSession
    }

    Process {
        if (-not $nsNamespace) { return }

        $cs = Get-NetworkSwitchInstanceNoFilter -CimSession $CimSession `
                                                -ClassName CIM_ComputerSystem `
                                                -Namespace $nsNamespace `
                                                -CmdletName $cmdletName

        $switchService = Get-NetworkSwitchService -Namespace $nsNamespace `
                                                  -ClassName MSFT_SwitchService `
                                                  -CimSession $CimSession `
                                                  -CmdletName $cmdletName

	$vlanCls = Get-NetworkSwitchClass -Namespace $nsNamespace `
                                          -ClassName CIM_NetworkVLAN `
                                          -CimSession $CimSession `
                                          -CmdletName $cmdletName

        $vlan = New-LocalCimInstance -CimClass $vlanCls `
                                     -Property @{VLANId = $VlanID; `
                                                 ElementName = $Name; `
                                                 Caption = [string]$Caption; `
                                                 Description = [string]$Description}

        Invoke-NetworkSwitchMethod -Instance $switchService[0] `
                                   -CimSession $CimSession `
                                   -MethodName "AddVLAN" `
                                   -Arguments @{ TargetedSwitch = $cs[0]; `
                                                 NetworkVLAN = [ciminstance[]]@($vlan) } `
                                   -CmdletName $cmdletName
    }

    End {}
}

function Remove-NetworkSwitchVlan() {
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)]
    [Microsoft.Management.Infrastructure.CimSession] $CimSession,

    [Parameter(Mandatory=$false, ParameterSetName="InstanceIdSet")]
    [string] $InstanceId,

    [Parameter(Mandatory=$false, ParameterSetName="NameSet")]
    [string] $Name,

    [Parameter(Mandatory=$false, ParameterSetName="VlanIdSet")]
    [int] $VlanId,

    [Parameter(Mandatory=$true,
        ParameterSetName="InputObjectSet",
        ValueFromPipeline=$true)]
    [Microsoft.Management.Infrastructure.CimInstance[]] $InputObject
    )

    Begin {
        $cmdletName = "Remove-NetworkSwitchVlan"
        $nsNamespace = Get-NetworkSwitchImplementationNamespace -CimSession $CimSession
    }

    Process {
        if (-not $nsNamespace) { return }

        if ($InputObject) {
            if ($input) {
                $vlans = $input[0]
            }
            else {
                $vlans = $InputObject
            }
        }
        else {
            $vlans = Get-NetworkSwitchInstanceNoFilter -NameSpace $nsNamespace `
                                                       -ClassName CIM_NetworkVlan `
                                                       -CimSession $CimSession `
                                                       -CmdletName $cmdletName
            if ($Name) {
                $vlans = Filter-NetworkSwitchInstance -Instances $vlans `
                                                      -Property ElementName `
                                                      -Value $Name `
                                                      -UseLike `
                                                      -CmdletName $cmdletName
            }
            elseif ($VlanId) {
                $vlans = Filter-NetworkSwitchInstance -Instances $vlans `
                                                      -Property VlanId `
                                                      -Value $VlanId `
                                                      -AssertNonEmpty `
                                                      -CmdletName $cmdletName
            }
            elseif ($InstanceId) {
                $vlans = Filter-NetworkSwitchInstance -Instances $vlans `
                                                      -Property InstanceId `
                                                      -Value $InstanceId `
                                                      -AssertNonEmpty `
                                                      -CmdletName $cmdletName
            }
        }

        $switchService = Get-NetworkSwitchService -Namespace $nsNamespace `
                                                  -ClassName MSFT_SwitchService `
                                                  -CimSession $CimSession `
                                                  -CmdletName $cmdletName
        foreach ($vlan in $vlans) {
            if ($(CmdletShouldProcess $PSCmdlet $vlan)) {
                Invoke-NetworkSwitchMethod -Instance $switchService[0] `
                                           -CimSession $CimSession `
                                           -MethodName "RemoveVLAN" `
                                           -Arguments @{VLAN = [ciminstance[]]@($vlan)} `
                                           -CmdletName $cmdletName
            }
        }
    }

    End {}
}

function Set-NetworkSwitchVlanProperty() {
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)]
    [Microsoft.Management.Infrastructure.CimSession] $CimSession,

    [Parameter(Mandatory=$false)]
    [System.Collections.HashTable] $Property,

    [Parameter(Mandatory=$true, ParameterSetName="VlanIdSet")]
    [int[]] $VlanId,

    [Parameter(Mandatory=$true,
        ParameterSetName="InputObjectSet",
        ValueFromPipeline=$true)]
    [Microsoft.Management.Infrastructure.CimInstance[]] $InputObject
    )

    Begin {
        $cmdletName = "Set-NetworkSwitchVlanProperty"
        $nsNamespace = Get-NetworkSwitchImplementationNamespace -CimSession $CimSession
    }

    Process {
        if (-not $nsNamespace) { return }

        if ($InputObject) {
            if ($input) {
                $vlans = $input[0]
            }
            else {
                $vlans = $InputObject
            }
        }
        else {
            $vlans = Get-NetworkSwitchInstanceNoFilter -NameSpace $nsNamespace `
                                                       -ClassName CIM_NetworkVlan `
                                                       -CimSession $CimSession `
                                                       -CmdletName $cmdletName
            if ($VlanId) {
                $vlans = Filter-NetworkSwitchInstance -Instances $vlans `
                                                      -Property VlanId `
                                                      -Value $VlanId `
                                                      -UseContains `
                                                      -AssertNonEmpty `
                                                      -CmdletName $cmdletName
            }
        }

        foreach ($vlan in $vlans) {
            if ($(CmdletShouldProcess $PSCmdlet $vlan)) {
                Set-NetworkSwitchInstance -InputObject $vlan `
                                          -Property $Property `
                                          -CimSession $CimSession `
                                          -CmdletName $cmdletName
            }
        }
    }

    End {}
}
