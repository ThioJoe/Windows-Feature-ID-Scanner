###########################################################################
#                                                                         #
#   Module Name: NetworkSwitchEthernetPort.psm1                            #
#                                                                         #
#   Description: Cmdlets to manage Ethernet ports                         #
#                                                                         #
#   Copyright (c) Microsoft Corporation. All rights reserved.             #
#                                                                         #
###########################################################################

import-module "$PSScriptRoot\CmdletHelpers.psm1" -Force -DisableNameChecking

function Disable-NetworkSwitchEthernetPort() {
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)]
    [Microsoft.Management.Infrastructure.CimSession] $CimSession,

    [Parameter(Mandatory=$true, ParameterSetName="DeviceIdSet")]
    [string] $DeviceID,

    [Parameter(Mandatory=$true, ParameterSetName="PortNumberSet")]
    [int] $PortNumber,

    [Parameter(Mandatory=$true,
        ParameterSetName="InputObjectSet",
        ValueFromPipeline=$true)]
    [Microsoft.Management.Infrastructure.CimInstance[]] $InputObject
    )

    Begin {
        $cmdletName = "Disable-NetworkSwitchEthernetPort"
        $nsNamespace = Get-NetworkSwitchImplementationNamespace -CimSession $CimSession
    }

    Process {
        if (-not $nsNamespace) { return }

        if ($InputObject) {
            if ($input) {
                $ports = $input[0]
            }
            else {
                $ports = $InputObject
            }
        }
        else {

            $ports = Get-NetworkSwitchInstanceNoFilter -Namespace $nsNamespace `
                                                       -ClassName CIM_EthernetPort `
                                                       -CimSession $CimSession `
                                                       -CmdletName $cmdletName
            if ($DeviceID) {
                $ports = Filter-NetworkSwitchInstance -Instances $ports `
                                                      -Property DeviceId `
                                                      -Value $DeviceId `
                                                      -CmdletName $cmdletName `
                                                      -AssertNonEmpty
            }
            elseif ($PortNumber) {
                $ports = Filter-NetworkSwitchInstance -Instances $ports `
                                                      -Property PortNumber `
                                                      -Value $PortNumber `
                                                      -CmdletName $cmdletName `
                                                      -AssertNonEmpty
            }
        }

        foreach ($port in $ports) {
            if ($(CmdletShouldProcess $PSCmdlet $port)) {
                Invoke-NetworkSwitchMethod -Instance $port `
                                           -CimSession $CimSession `
                                           -MethodName "RequestStateChange" `
                                           -Arguments @{RequestedState = 3} `
                                           -CmdletName $cmdletName
            }
        }
    }

    End {}
}

function Enable-NetworkSwitchEthernetPort() {
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)]
    [Microsoft.Management.Infrastructure.CimSession] $CimSession,

    [Parameter(Mandatory=$true, ParameterSetName="DeviceIdSet")]
    [string] $DeviceID,

    [Parameter(Mandatory=$true, ParameterSetName="PortNumberSet")]
    [int] $PortNumber,

    [Parameter(Mandatory=$true,
        ParameterSetName="InputObjectSet",
        ValueFromPipeline=$true)]
    [Microsoft.Management.Infrastructure.CimInstance[]] $InputObject
    )

    Begin {
        $cmdletName = "Enable-NetworkSwitchEthernetPort"
        $nsNamespace = Get-NetworkSwitchImplementationNamespace -CimSession $CimSession
    }

    Process {
        if (-not $nsNamespace) { return }

        if ($InputObject) {
            if ($input) {
                $ports = $input[0]
            }
            else {
                $ports = $InputObject
            }
        }
        else {
            $ports = Get-NetworkSwitchInstanceNoFilter -Namespace $nsNamespace `
                                                       -ClassName CIM_EthernetPort `
                                                       -CimSession $CimSession `
                                                       -CmdletName $cmdletName
            if ($DeviceID) {
                $ports = Filter-NetworkSwitchInstance -Instances $ports `
                                                      -Property DeviceId `
                                                      -Value $DeviceId `
                                                      -CmdletName $cmdletName `
                                                      -AssertNonEmpty
            }
            elseif ($PortNumber) {
                $ports = Filter-NetworkSwitchInstance -Instances $ports `
                                                      -Property PortNumber `
                                                      -Value $PortNumber `
                                                      -CmdletName $cmdletName `
                                                      -AssertNonEmpty
            }
        }

        foreach ($port in $ports) {
            if ($(CmdletShouldProcess $PSCmdlet $port)) {
                Invoke-NetworkSwitchMethod -Instance $port `
                                           -CimSession $CimSession `
                                           -MethodName "RequestStateChange" `
                                           -Arguments @{RequestedState = 2} `
                                           -CmdletName $cmdletName
            }
        }
    }

    End {}
}

function Get-NetworkSwitchEthernetPort() {
[CmdletBinding(DefaultParameterSetName="DeviceIDSet")]
[OutputType([Microsoft.Management.Infrastructure.CimInstance])]
[OutputType('Microsoft.Management.Infrastructure.CimInstance#CIM_EthernetPort')]
param(
    [Parameter(Mandatory=$true)]
    [Microsoft.Management.Infrastructure.CimSession] $CimSession,

    [Parameter(Mandatory=$false, ParameterSetName="DeviceIDSet")]
    [string] $DeviceId,

    [Parameter(Mandatory=$true, ParameterSetName="FullDuplexEnabledSet")]
    [switch] $FullDuplexEnabled,

    [Parameter(Mandatory=$true, ParameterSetName="FullDuplexDisabledSet")]
    [switch] $FullDuplexDisabled,

    [Parameter(Mandatory=$true, ParameterSetName="PortNumberSet")]
    [int] $PortNumber
    )

    Begin {
        $cmdletName = "Get-NetworkSwitchEthernetPort"
        $nsNamespace = Get-NetworkSwitchImplementationNamespace -CimSession $CimSession
    }

    Process {
        if (-not $nsNamespace) { return }

        $ports = Get-NetworkSwitchInstanceNoFilter -Namespace $nsNamespace `
                                                   -ClassName CIM_EthernetPort `
                                                   -CimSession $CimSession `
                                                   -CmdletName $cmdletName
        if ($DeviceId) {
            $ports = Filter-NetworkSwitchInstance -Instances $ports `
                                                  -Property DeviceId `
                                                  -Value $DeviceId `
                                                  -CmdletName $cmdletName `
                                                  -AssertNonEmpty
        }
        elseif ($FullDuplexEnabled) {
            $ports = Filter-NetworkSwitchInstance -Instances $ports `
                                                  -Property FullDuplex `
                                                  -Value $true `
                                                  -CmdletName $cmdletName `
        }
        elseif ($FullDuplexDisabled) {
            $ports = Filter-NetworkSwitchInstance -Instances $ports `
                                                  -Property FullDuplex `
                                                  -Value $false `
                                                  -CmdletName $cmdletName `
        }
        elseif ($PortNumber) {
            $ports = Filter-NetworkSwitchInstance -Instances $ports `
                                                  -Property PortNumber `
                                                  -Value $PortNumber `
                                                  -CmdletName $cmdletName `
                                                  -AssertNonEmpty
        }

        foreach ($port in $ports) {
            $lanep = Get-NetworkSwitchAssociatedInstance -InputObject $port `
                                                         -ResultClassName Cim_LanEndpoint `
                                                         -CimSession $CimSession `
                                                         -CmdletName $cmdletName
            if ($lanep) {
                $ippe = @(Get-NetworkSwitchAssociatedInstance -InputObject $lanep `
                                                              -ResultClassName CIM_IPProtocolEndpoint `
                                                              -CimSession $CimSession `
                                                              -CmdletName $cmdletName)
            }

            if ($lanep) {
                $vlanep = Get-NetworkSwitchAssociatedInstance -InputObject $lanep `
                                                              -ResultClassName Cim_VLanEndpoint `
                                                              -CimSession $CimSession `
                                                              -CmdletName $cmdletName
            }

            if ($vlanep) {
                $vlanepsd = Get-NetworkSwitchAssociatedInstance -InputObject $vlanep `
                                                                -ResultClassName  Cim_VLanEndpointSettingData `
                                                                -CimSession $CimSession `
                                                                -CmdletName $cmdletName
            }

            $port.PSObject.Members.Remove("IPAddress")
            Add-Member -InputObject $port `
                       -MemberType NoteProperty `
                       -Name IPAddress `
                       -Value $ippe

            $port.PSObject.Members.Remove("PortMode")
            Add-Member -InputObject $port `
                       -MemberType NoteProperty `
                       -Name PortMode `
                       -Value $vlanep.DesiredEndpointMode

            $port.PSObject.Members.Remove("AccessVLAN")
            Add-Member -InputObject $port `
                       -MemberType NoteProperty `
                       -Name AccessVLAN `
                       -Value $vlanepsd.AccessVLAN

            $port.PSObject.Members.Remove("TrunkedVLANList")
            Add-Member -InputObject $port `
                       -MemberType NoteProperty `
                       -Name TrunkedVLANList `
                       -Value $vlanepsd.TrunkedVLANList

            $port
        }
    }

    End {}
}

function Remove-NetworkSwitchEthernetPortIPAddress() {
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)]
    [Microsoft.Management.Infrastructure.CimSession] $CimSession,

    [Parameter(Mandatory=$true, ParameterSetName="PortNumberSet")]
    [int] $PortNumber,

    [Parameter(Mandatory=$true,
        ParameterSetName="InputObjectSet",
        ValueFromPipeline=$true)]
    [Microsoft.Management.Infrastructure.CimInstance[]] $InputObject
    )

    Begin {
        $cmdletName = "Remove-NetworkSwitchEthernetPortIPAddress"
        $nsNamespace = Get-NetworkSwitchImplementationNamespace -CimSession $CimSession
    }

    Process {
        if (-not $nsNamespace) { return }

        if ($InputObject) {
            if ($input) {
                $ports = $input[0]
            }
            else {
                $ports = $InputObject
            }
        }
        else {
            $ports = Get-NetworkSwitchInstanceNoFilter -Namespace $nsNamespace `
                                                       -ClassName CIM_EthernetPort `
                                                       -CimSession $CimSession `
                                                       -CmdletName $cmdletName
            if ($PortNumber) {
                $ports = Filter-NetworkSwitchInstance -Instances $ports `
                                                      -Property PortNumber `
                                                      -Value $PortNumber `
                                                      -CmdletName $cmdletName `
                                                      -AssertNonEmpty
            }
        }

        $switchService = Get-NetworkSwitchService -Namespace $nsNamespace `
                                                  -CimSession $cimSession `
                                                  -CmdletName $cmdletName
        foreach ($port in $ports) {
            if ($(CmdletShouldProcess $PSCmdlet $port)) {
                $lanEndpoints = Get-NetworkSwitchAssociatedInstance -InputObject $port `
                                                                    -CimSession $CimSession `
                                                                    -ResultClassName CIM_LANEndpoint `
                                                                    -CmdletName $cmdletName
                foreach ($lep in $lanEndpoints) {
                    $protocolEndpoints = Get-NetworkSwitchAssociatedInstance -InputObject $lep `
                                                                             -CimSession $CimSession `
                                                                             -ResultClassName CIM_IPProtocolEndpoint `
                                                                             -CmdletName $cmdletName
                    foreach($pep in $protocolEndpoints) {

                        Invoke-NetworkSwitchMethod -Instance $switchService[0] `
                                                   -CimSession $CimSession `
                                                   -MethodName "RemoveProtocolEndpoint" `
                                                   -Arguments @{Endpoint = $pep} `
                                                   -CmdletName $cmdletName
                    }
                }
            }
        }
    }

    End {}
}

function Set-NetworkSwitchEthernetPortIPAddress() {
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)]
    [Microsoft.Management.Infrastructure.CimSession] $CimSession,

    [Parameter(Mandatory=$true)]
    [string] $IpAddress,

    [Parameter(Mandatory=$true)]
    [string] $SubnetAddress,

    [Parameter(Mandatory=$true, ParameterSetName="PortNumberSet")]
    [int] $PortNumber,

    [Parameter(Mandatory=$true,
        ParameterSetName="InputObjectSet",
        ValueFromPipeline=$true)]
    [Microsoft.Management.Infrastructure.CimInstance[]] $InputObject
    )

    Begin {
        $cmdletName = "Set-NetworkSwitchEthernetPortIPAddress"
        $nsNamespace = Get-NetworkSwitchImplementationNamespace -CimSession $CimSession
    }

    Process {
        if (-not $nsNamespace) { return }

        if ($InputObject) {
            if ($input) {
                $ports = $input[0]
            }
            else {
                $ports = $InputObject
            }
        }
        else {
            $ports = Get-NetworkSwitchInstanceNoFilter -Namespace $nsNamespace `
                                                       -ClassName CIM_EthernetPort `
                                                       -CimSession $CimSession `
                                                       -CmdletName $cmdletName
            if ($PortNumber) {
                $ports = Filter-NetworkSwitchInstance -Instances $ports `
                                                      -Property PortNumber `
                                                      -Value $PortNumber `
                                                      -CmdletName $cmdletName `
                                                      -AssertNonEmpty
            }
        }

        $switchService = Get-NetworkSwitchService -Namespace $nsNamespace `
                                                  -CimSession $cimSession `
                                                  -CmdletName $cmdletName

        $ippeCls = Get-NetworkSwitchClass -Namespace $nsNamespace `
                                          -ClassName CIM_IPProtocolEndpoint `
                                          -CimSession $CimSession `
                                          -CmdletName $cmdletName

        $protocolEndpoint = New-LocalCimInstance -CimClass $ippeCls `
                                                 -Property @{IPV4Address = $ipAddress; `
                                                             SubnetMask = $SubnetAddress}
        foreach ($port in $ports) {
            if ($(CmdletShouldProcess $PSCmdlet $port)) {
                Invoke-NetworkSwitchMethod -Instance $switchService[0] `
                                           -CimSession $CimSession `
                                           -MethodName "AddProtocolEndpoint" `
                                           -Arguments @{TargetInterface = $port; `
                                                        ProtocolEndpoint = [ciminstance[]]@($protocolEndpoint)} `
                                           -CmdletName $cmdletName
            }
        }
    }

    End {}
}

function Set-NetworkSwitchPortMode() {
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)]
    [Microsoft.Management.Infrastructure.CimSession] $CimSession,

    [Parameter(Mandatory=$true, ParameterSetName="AccessSet")]
    [switch] $AccessMode,

    [Parameter(Mandatory=$true, ParameterSetName="AccessSet")]
    [int] $VlanID,

    [Parameter(Mandatory=$true, ParameterSetName="RouteSet")]
    [switch] $RouteMode,

    [Parameter(Mandatory=$true, ParameterSetName="RouteSet")]
    [string] $IpAddress,

    [Parameter(Mandatory=$true, ParameterSetName="RouteSet")]
    [string] $SubnetAddress,

    [Parameter(Mandatory=$true, ParameterSetName="TrunkSet")]
    [switch] $TrunkMode,

    [Parameter(Mandatory=$true, ParameterSetName="TrunkSet")]
    [uint16[]] $VlanIDs,

    [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
    [Microsoft.Management.Infrastructure.CimInstance[]] $InputObject
    )

    Begin {
        $cmdletName = "Set-NetworkSwitchPortMode"
        $nsNamespace = Get-NetworkSwitchImplementationNamespace -CimSession $CimSession
    }

    Process {
        if (-not $nsNamespace) { return }

        if ($input) {
            $ports = $input[0]
        }
        else {
            $ports = $InputObject
        }

        if ($RouteMode) {
            $switchService = Get-NetworkSwitchService -Namespace $nsNamespace `
                                                      -CimSession $cimSession `
                                                      -CmdletName $cmdletName

            $ippeCls = Get-NetworkSwitchClass -Namespace $nsNamespace `
                                              -ClassName CIM_IPProtocolEndpoint `
                                              -CimSession $CimSession `
                                              -CmdletName $cmdletName

            $protocolEndpoint = New-LocalCimInstance -CimClass $ippeCls `
                                                     -Property @{IPV4Address = $ipAddress; `
                                                                 SubnetMask = $SubnetAddress}
        }

        foreach ($port in $ports) {
            if ($(CmdletShouldProcess $PSCmdlet $port)) {
                if ($RouteMode) {
                    Invoke-NetworkSwitchMethod -Instance $switchService[0] `
                                               -CimSession $CimSession `
                                               -MethodName "AddProtocolEndpoint" `
                                               -Arguments @{TargetInterface = $port; `
                                                            ProtocolEndpoint = [ciminstance[]]@($protocolEndpoint)} `
                                               -CmdletName $cmdletName
                }
                else {
                    $lanep = Get-NetworkSwitchAssociatedInstance -InputObject $port `
                                                                 -ResultClassName Cim_LanEndpoint `
                                                                 -CimSession $CimSession `
                                                                 -CmdletName $cmdletName

                    $vlanep = Get-NetworkSwitchAssociatedInstance -InputObject $lanep `
                                                                  -ResultClassName Cim_VLanEndpoint `
                                                                  -CimSession $CimSession `
                                                                  -CmdletName $cmdletName

                    $vlanepsd = Get-NetworkSwitchAssociatedInstance -InputObject $vlanep `
                                                                    -ResultClassName  Cim_VLanEndpointSettingData `
                                                                    -CimSession $CimSession `
                                                                    -CmdletName $cmdletName
                    if ($AccessMode) {
                        $vlanepProp = @{DesiredEndpointMode = 2}
                        $vlanepsdProp = @{AccessVlan = $VlanID}
                    }
                    elseif ($TrunkMode) {
                        $vlanepProp = @{DesiredEndpointMode = 5}
                        $vlanepsdProp = @{TrunkedVlanList = $VlanIDs}
                    }

                    Set-NetworkSwitchInstance -InputObject $vlanep `
                                              -Property $vlanepProp `
                                              -CimSession $CimSession `
                                              -CmdletName $cmdletName

                    Set-NetworkSwitchInstance -InputObject $vlanepsd `
                                              -Property $vlanepsdProp `
                                              -CimSession $CimSession `
                                              -CmdletName $cmdletName
                }
            }
        }
    }

    End {}
}

function Set-NetworkSwitchPortProperty() {
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)]
    [Microsoft.Management.Infrastructure.CimSession] $CimSession,

    [Parameter(Mandatory=$false)]
    [System.Collections.HashTable] $Property,

    [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
    [Microsoft.Management.Infrastructure.CimInstance[]] $InputObject
    )

    Begin {
        $cmdletName = "Set-NetworkSwitchPortProperty"
        $nsNamespace = Get-NetworkSwitchImplementationNamespace -CimSession $CimSession
    }

    Process {
        if (-not $nsNamespace) { return }

        if ($input) {
            $ports = $input[0]
        }
        else {
            $ports = $InputObject
        }

        foreach ($port in $ports) {
            if ($(CmdletShouldProcess $PSCmdlet $port)) {
                Set-NetworkSwitchInstance -InputObject $port `
                                          -CimSession $CimSession `
                                          -Property $Property `
                                          -CmdletName $cmdletName
            }
        }
    }

    End {}
}
