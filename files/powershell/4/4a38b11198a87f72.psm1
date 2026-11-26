###########################################################################
#                                                                         #
#   Module Name: NetworkSwitchFeature.psm1                                 #
#                                                                         #
#   Description: Cmdlets to manage features                               #
#                                                                         #
#   Copyright (c) Microsoft Corporation. All rights reserved.             #
#                                                                         #
###########################################################################

import-module "$PSScriptRoot\CmdletHelpers.psm1" -Force -DisableNameChecking

function Disable-NetworkSwitchFeature() {
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)]
    [Microsoft.Management.Infrastructure.CimSession] $CimSession,

    [Parameter(Mandatory=$true, ParameterSetName="FeatureNameSet")]
    [int] $FeatureName,

    [Parameter(Mandatory=$true, ParameterSetName="NameSet")]
    [string] $Name,

    [Parameter(Mandatory=$true,ParameterSetName="InstanceIdSet")]
    [string] $InstanceId,

    [Parameter(Mandatory=$true,
        ParameterSetName="InputObjectSet",
        ValueFromPipeline=$true)]
    [Microsoft.Management.Infrastructure.CimInstance[]] $InputObject
    )

    Begin {
        $cmdletName = "Disable-NetworkSwitchFeature"
        $nsNamespace = Get-NetworkSwitchImplementationNamespace -CimSession $CimSession
    }

    Process {
        if (-not $nsNamespace) { return }

        if ($InputObject) {
            if ($input) {
                $features = $input[0]
            }
            else {
                $features = $InputObject
            }
        }
        else {
            $features = Get-NetworkSwitchInstanceNoFilter -Namespace $nsNamespace `
                                                          -ClassName MSFT_Feature `
                                                          -CimSession $CimSession `
                                                          -CmdletName $cmdletName
            if ($FeatureName) {
                $features = Filter-NetworkSwitchInstance -Instances $features `
                                                         -Property FeatureName `
                                                         -Value $FeatureName `
                                                         -CmdletName $cmdletName
            }
            elseif ($Name) {
                $features = Filter-NetworkSwitchInstance -Instances $features `
                                                         -Property Name `
                                                         -Value $Name `
                                                         -CmdletName $cmdletName `
                                                         -UseLike
            }
            elseif ($InstanceId) {
                $features = Filter-NetworkSwitchInstance -Instances $features `
                                                         -Property InstanceId `
                                                         -Value $InstanceId `
                                                         -CmdletName $cmdletName `
                                                         -AssertNonEmpty
            }
        }

        foreach ($feature in $features) {
            if ($(CmdletShouldProcess $PSCmdlet $feature)) {
                Set-NetworkSwitchInstance -InputObject $feature `
                                          -Property @{IsEnabled = $false} `
                                          -CimSession $CimSession `
                                          -CmdletName $cmdletName
            }
        }
    }

    End {}
}

function Enable-NetworkSwitchFeature() {
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)]
    [Microsoft.Management.Infrastructure.CimSession] $CimSession,

    [Parameter(Mandatory=$true,ParameterSetName="FeatureNameSet")]
    [int] $FeatureName,

    [Parameter(Mandatory=$true,ParameterSetName="NameSet")]
    [string] $Name,

    [Parameter(Mandatory=$true,ParameterSetName="InstanceIdSet")]
    [string] $InstanceId,

    [Parameter(Mandatory=$true,
        ParameterSetName="InputObjectSet",
        ValueFromPipeline=$true)]
    [Microsoft.Management.Infrastructure.CimInstance[]] $InputObject
    )

    Begin {
        $cmdletName = "Enable-NetworkSwitchFeature"
        $nsNamespace = Get-NetworkSwitchImplementationNamespace -CimSession $CimSession
    }

    Process {
        if (-not $nsNamespace) { return }

        if ($InputObject) {
            if ($input) {
                $features = $input[0]
            }
            else {
                $features = $InputObject
            }
        }
        else {
            $features = Get-NetworkSwitchInstanceNoFilter -Namespace $nsNamespace `
                                                          -ClassName MSFT_Feature `
                                                          -CimSession $CimSession `
                                                          -CmdletName $cmdletName
            if ($FeatureName) {
                $features = Filter-NetworkSwitchInstance -Instances $features `
                                                         -Property FeatureName `
                                                         -Value $FeatureName `
                                                         -CmdletName $cmdletName
            }
            elseif ($Name) {
                $features = Filter-NetworkSwitchInstance -Instances $features `
                                                         -Property Name `
                                                         -Value $Name `
                                                         -CmdletName $cmdletName `
                                                         -UseLike
            }
            elseif ($InstanceId) {
                $features = Filter-NetworkSwitchInstance -Instances $features `
                                                         -Property InstanceId `
                                                         -Value $InstanceId `
                                                         -CmdletName $cmdletName `
                                                         -AssertNonEmpty
            }
        }

        foreach ($feature in $features) {
            if ($(CmdletShouldProcess $PSCmdlet $feature)) {
                Set-NetworkSwitchInstance -InputObject $feature `
                                          -Property @{IsEnabled = $true} `
                                          -CimSession $CimSession `
                                          -CmdletName $cmdletName
            }
        }
    }

    End {}
}

function Get-NetworkSwitchFeature() {
[CmdletBinding(DefaultParameterSetName="NameSet")]
[OutputType([Microsoft.Management.Infrastructure.CimInstance])]
[OutputType('Microsoft.Management.Infrastructure.CimInstance#MSFT_Feature')]
param(
    [Parameter(Mandatory=$true)]
    [Microsoft.Management.Infrastructure.CimSession] $CimSession,

    [Parameter(Mandatory=$false, ParameterSetName="NameSet")]
    [string] $Name,

    [Parameter(Mandatory=$true, ParameterSetName="EnabledSet")]
    [switch] $Enabled,

    [Parameter(Mandatory=$true, ParameterSetName="DisabledSet")]
    [switch] $Disabled
    )

    Begin {
        $cmdletName = "Get-NetworkSwitchFeature"
        $nsNamespace = Get-NetworkSwitchImplementationNamespace -CimSession $CimSession
    }

    Process {
        if (-not $nsNamespace) { return }

        $featureList = Get-NetworkSwitchInstanceNoFilter -Namespace $nsNamespace `
                                                         -ClassName MSFT_Feature `
                                                         -CimSession $CimSession `
                                                         -CmdletName $cmdletName
        if ($Name) {
            $featureList = Filter-NetworkSwitchInstance -Instances $featureList `
                                                        -Property Name `
                                                        -Value $Name `
                                                        -CmdletName $cmdletName `
                                                        -UseLike
        }
        elseif ($Enabled) {
            $featureList = Filter-NetworkSwitchInstance -Instances $featureList `
                                                        -Property IsEnabled `
                                                        -Value $true `
                                                        -CmdletName $cmdletName
        }
        elseif ($Disabled) {
            $featureList = Filter-NetworkSwitchInstance -Instances $featureList `
                                                        -Property IsEnabled `
                                                        -Value $false `
                                                        -CmdletName $cmdletName
        }

        $featureList
    }

    End {}
}
