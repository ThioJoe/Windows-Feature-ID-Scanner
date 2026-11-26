###########################################################################
#                                                                         #
#   Module Name: NetworkSwitchGlobalSettingData.psm1                       #
#                                                                         #
#   Description: Cmdlet to access the switch global settings data         #
#                                                                         #
#   Copyright (c) Microsoft Corporation. All rights reserved.             #
#                                                                         #
###########################################################################

import-module "$PSScriptRoot\CmdletHelpers.psm1" -Force -DisableNameChecking

function Get-NetworkSwitchGlobalData() {
[CmdletBinding()]
[OutputType([Microsoft.Management.Infrastructure.CimInstance])]
[OutputType('Microsoft.Management.Infrastructure.CimInstance#MSFT_GlobalEthernetSwitchSettingData')]
param(
    [Parameter(Mandatory=$true)]
    [Microsoft.Management.Infrastructure.CimSession] $CimSession
    )

    Begin {
        $cmdletName = "Get-NetworkSwitchGlobalData"
        $nsNamespace = Get-NetworkSwitchImplementationNamespace -CimSession $CimSession
    }

    Process {
        if (-not $nsNamespace) { return }

        Get-NetworkSwitchInstanceNoFilter -Namespace $nsNamespace `
                                          -ClassName MSFT_GlobalEthernetSwitchSettingData `
                                          -CimSession $CimSession `
                                          -CmdletName $cmdletName
    }

    End {}
}
