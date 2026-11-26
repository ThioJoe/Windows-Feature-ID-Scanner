#
# Script Module file for provcmdlets module.
#
# Copyright (c) Microsoft Corporation
#

#
# Cmdlet aliases
#

Set-Alias Add-ProvisioningPackage Install-ProvisioningPackage
Set-Alias Remove-ProvisioningPackage Uninstall-ProvisioningPackage
Set-Alias Add-TrustedProvisioningCertificate Install-TrustedProvisioningCertificate
Set-Alias Remove-TrustedProvisioningCertificate Uninstall-TrustedProvisioningCertificate

Export-ModuleMember -Alias * -Function * -Cmdlet *

function IsCurrentProcessArm64 {
    Add-Type -TypeDefinition @"
    using System;
    using System.Runtime.InteropServices;

    public static class Process
    {
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern Int32 IsWow64Process2(
            IntPtr process,
            out ushort processMachine,
            out ushort nativeMachine);

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetCurrentProcess();

        [StructLayout(LayoutKind.Sequential, Pack = 8)]
        private struct SYSTEM_INFO
        {
            public UInt16 wProcessorArchitecture;
            UInt16 reserved;
            Int32  dwPageSize;
            IntPtr lpMinimumApplicationAddress;
            IntPtr lpMaximumApplicationAddress;
            IntPtr dwActiveProcessorMask;
            Int32  dwNumberOfProcessors;
            Int32  dwProcessorType;
            Int32  dwAllocationGranularity;
            UInt16 wProcessorLevel;
            UInt16 wProcessorRevision;
        };

        [DllImport("kernel32.dll")]
        private static extern void GetNativeSystemInfo(out SYSTEM_INFO systeminfo);

        public static bool IsArm64()
        {
            const UInt16 PROCESSOR_ARCHITECTURE_ARM64 = 12;
            SYSTEM_INFO systeminfo;
            GetNativeSystemInfo(out systeminfo);

            if (systeminfo.wProcessorArchitecture == PROCESSOR_ARCHITECTURE_ARM64)
            {
                const UInt16 IMAGE_FILE_MACHINE_UNKNOWN = 0;
                UInt16 processMachine = 0, nativeMachine = 0;
                Int32 retval = IsWow64Process2(GetCurrentProcess(), out processMachine, out nativeMachine);
                if (retval != 0 && processMachine == IMAGE_FILE_MACHINE_UNKNOWN)
                {
                    return true;
                }
            }

            return false;
        }
    }
"@

    Return [Process]::IsArm64()
}

$provpackageapidll = $(
    If (IsCurrentProcessArm64)
    {
        Join-Path $psScriptRoot "arm64\provpackageapi.dll"
    }
    else
    {
        Join-Path $psScriptRoot "provpackageapi.dll"
    }
)

Import-Module -Name $provpackageapidll
