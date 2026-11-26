###########################################################################
#                                                                         #
#   Module Name: NetworkSwitchConfiguration.psm1                           #
#                                                                         #
#   Description: Cmdlets for saving and restoring the switch state        #
#                                                                         #
#   Copyright (c) Microsoft Corporation. All rights reserved.             #
#                                                                         #
###########################################################################

import-module "$PSScriptRoot\CmdletHelpers.psm1" -Force -DisableNameChecking

function Restore-NetworkSwitchConfiguration() {
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)]
    [Microsoft.Management.Infrastructure.CimSession] $CimSession
    )

    Begin {
        $cmdletName = "Restore-NetworkSwitchConfiguration"
        $nsNamespace = Get-NetworkSwitchImplementationNamespace -CimSession $CimSession
    }

    Process {
        if (-not $nsNamespace) { return }

        $ss = Get-NetworkSwitchService -Namespace $nsNamespace `
                                       -CimSession $cimSession `
                                       -CmdletName $cmdletName

        if ($(CmdletShouldProcess $PSCmdlet $ss)) {
            Invoke-NetworkSwitchMethod -Instance $ss[0] `
                                       -CimSession $CimSession `
                                       -MethodName "CopyStartupToCurrent" `
                                       -CmdletName $cmdletName
        }
    }

    End {}
}

function Save-NetworkSwitchConfiguration() {
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)]
    [Microsoft.Management.Infrastructure.CimSession] $CimSession
    )

    Begin {
        $cmdletName = "Save-NetworkSwitchConfiguration"
        $nsNamespace = Get-NetworkSwitchImplementationNamespace -CimSession $CimSession
    }

    Process {
        if (-not $nsNamespace) { return }

        $ss = Get-NetworkSwitchService -Namespace $nsNamespace `
                                       -CimSession $cimSession `
                                       -CmdletName $cmdletName

        if ($(CmdletShouldProcess $PSCmdlet $ss)) {
            Invoke-NetworkSwitchMethod -Instance $ss[0] `
                                       -CimSession $CimSession `
                                       -MethodName "CopyCurrentToStartup" `
                                       -CmdletName $cmdletName
        }
    }

    End {}
}
