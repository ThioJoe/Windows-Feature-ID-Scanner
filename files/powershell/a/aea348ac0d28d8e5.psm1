# Copyright (C) Microsoft Corporation. All rights reserved.
#
# File:   LAPS.psm1
# Author: jsimmons@microsoft.com
# Date:   April 13, 2023
#
# This file implements the Get-LapsDiagnostics and Get-LapsAADPasswordPowerShell cmdlets.

function RunProcess()
{
    Param (
        [Parameter(Mandatory=$true)]
        [string]$fileName,

        [Parameter(Mandatory=$true)]
        [string]$args
        )

    Write-Verbose "Running process: $fileName $args"

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo.Filename = $fileName
    $process.StartInfo.Arguments = $args
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.UseShellExecute = $false
    $process.Start() | Out-Null
    $process.WaitForExit() | Out-Null

    if ($process.ExitCode -ne 0)
    {
        Write-Error "$fileName returned an error code: $process.ExitCode"
    }
}

function StartLapsWPPTracing()
{
    Param (
        [Parameter(Mandatory=$true)]
        [string]$DataFolder
        )

    $etlFile = "$DataFolder\" + "LAPSTrace.etl"

    $logman = $Env:windir + "\system32\logman.exe"

    $logmanArgs = "start LAPSTrace"
    $logmanArgs += " -o $etlFile"
    $logmanArgs += " -p {177720b0-e8fe-47ed-bf71-d6dbc8bd2ee7} 0x7FFFFFFF 0xFF"
    $logmanArgs += " -ets"

    Write-Verbose "Starting log trace"

    RunProcess $logman $logmanArgs
}

function StopLapsWPPTracing()
{
    Param (
        [Parameter(Mandatory=$true)]
        [string]$DataFolder
        )

    $logman = $Env:windir + "\system32\logman.exe"

    $logmanArgs = "stop LAPSTrace -ets"

    Write-Verbose "Stopping log trace"

    RunProcess $logman $logmanArgs
}

function StartLdapTracing()
{
    Param (
        [Parameter(Mandatory=$true)]
        [string]$DataFolder
        )

    New-Item -Path HKLM:\SYSTEM\CurrentControlSet\Services\ldap\tracing -Name lsass.exe -Force | Out-Null
    $etlFile = "$DataFolder\" + "LdapTrace.etl"

    $logmanLdap = $Env:windir + "\system32\logman.exe"

    $logmanLdapArgs = "start LdapTrace"
    $logmanLdapArgs += " -o $etlFile"
    $logmanLdapArgs += " -p Microsoft-Windows-LDAP-Client 0x1a59afa3 0xff -nb 16 16 -bs 1024 -mode Circular -f bincirc -max 4096"
    $logmanLdapArgs += " -ets"

    Write-Verbose "Starting Ldap trace"

    RunProcess $logmanLdap $logmanLdapArgs
}

function StopLdapTracing()
{
    Param (
        [Parameter(Mandatory=$true)]
        [string]$DataFolder
        )

    $logmanLdap = $Env:windir + "\system32\logman.exe"

    $logmanLdapArgs = "stop LdapTrace -ets"

    Write-Verbose "Stopping Ldap trace"

    RunProcess $logmanLdap $logmanLdapArgs

    Remove-Item -Path HKLM:\SYSTEM\CurrentControlSet\Services\ldap\tracing\lsass.exe -Force
}

function StartNetworkTrace()
{
    Param (
        [Parameter(Mandatory=$true)]
        [string]$DataFolder
        )

    $netsh = $Env:windir + "\system32\netsh.exe"

    $traceFile = "$DataFolder\" + "netsh.etl"

    $netshArgs = "trace start"
    $netshArgs += " capture=yes"
    $netshArgs += " persistent=no"
    $netshArgs += " maxSize=250"
    $netshArgs += " perfMerge=no"
    $netshArgs += " sessionname=$DataFolder"
    $netshArgs += " tracefile=$traceFile"

    Write-Verbose "Starting network trace"

    RunProcess $netsh $netshArgs
}

function StopNetworkTrace()
{
    Param (
        [Parameter(Mandatory=$true)]
        [string]$DataFolder
        )

    $netsh = $Env:windir + "\system32\netsh.exe"

    $netshArgs = "trace stop"
    $netshArgs += " sessionname=$DataFolder"

    Write-Verbose "Stopping network trace - may take a moment..."

    RunProcess $netsh $netshArgs
}

function CopyOSBinaries()
{
    Param (
        [Parameter(Mandatory=$true)]
        [string]$DataFolder
        )

    Copy-Item "$env:SystemRoot\system32\samsrv.dll" -Destination $DataFolder
    Copy-Item "$env:SystemRoot\system32\wldap32.dll" -Destination $DataFolder
    Copy-Item "$env:SystemRoot\system32\laps.dll" -Destination $DataFolder
    Copy-Item "$env:SystemRoot\system32\lapscsp.dll" -Destination $DataFolder
    Copy-Item "$env:SystemRoot\system32\windowspowershell\v1.0\modules\laps\lapspsh.dll" -Destination $DataFolder
    Copy-Item "$env:SystemRoot\system32\windowspowershell\v1.0\modules\laps\lapsutil.dll" -Destination $DataFolder
}

function ExportLAPSEventLog()
{
    Param (
        [Parameter(Mandatory=$true)]
        [string]$DataFolder
        )

    # Export individual LAPS log entries to csv file for easy viewing
    $exportedCsvLogEntries = $DataFolder + "\laps_events.csv"
    Write-Verbose "Exporting Microsoft-Windows-LAPS/Operational event log entries to $exportedCsvLogEntries"
    Get-WinEvent -LogName "Microsoft-Windows-LAPS/Operational" | Select RecordId,TimeCreated,Id,LevelDisplayName, @{n='Message';e={$_.Message -replace '\s+', " "}} ,Version,ProviderName,ProviderId,LogName,ProcessId,ThreadId,MachineName,UserId,ActivityId | Export-CSV $exportedCsvLogEntries -NoTypeInformation

    # Export the entire LAPS event log to an evtx file as well
    $exportedLog = $DataFolder + "\laps_events.evtx"
    $wevtutil = $Env:windir + "\system32\wevtutil.exe"
    $wevtutilArgs = "epl Microsoft-Windows-LAPS/Operational $exportedLog"
    Write-Verbose "Exporting Microsoft-Windows-LAPS/Operational event log to $exportedLog"
    RunProcess $wevtutil $wevtutilArgs
}

function PostProcessRegistryValue()
{
    Param (
        [Parameter(Mandatory=$true)]
        [string]$Name,

        [Parameter(Mandatory=$true)]
        [string]$Value
        )

    switch ($Name)
    {
        'BackupDirectory'
        {
            switch ($Value)
            {
                '0' { $notes = "Disabled" }
                '1' { $notes = "AAD" }
                '2' { $notes = "AD" }
                default { $notes = "<unrecognized>" }
            }
        }
        'PolicySource'
        {
            switch ($Value)
            {
                '1' { $notes = "CSP" }
                '2' { $notes = "GPO" }
                '3' { $notes = "Local" }
                '4' { $notes = "LegacyLAPS" }
                default { $notes = "<unrecognized>" }
            }
        }
        # Convert 64-bit UTC timestamp values into human-readable string
        'LastPasswordUpdateTime'
        {
            $dateTime = [DateTime]::FromFileTimeUtc($Value)
            $notes = $dateTime.ToString("O")
        }
        'AzurePasswordExpiryTime'
        {
            $dateTime = [DateTime]::FromFileTimeUtc($Value)
            $notes = $dateTime.ToString("O")
        }
        'PostAuthResetDeadline'
        {
            $dateTime = [DateTime]::FromFileTimeUtc($Value)
            $notes = $dateTime.ToString("O")
        }
        'PostAuthResetAuthenticationTime'
        {
            $dateTime = [DateTime]::FromFileTimeUtc($Value)
            $notes = $dateTime.ToString("O")
        }
        default
        {
            $notes = ""
        }
    }
    return $notes
}

function ExportRegistryKey()
{
    Param (
        [Parameter(Mandatory=$true)]
        [object]$RegistrySettingsTable,

        [Parameter(Mandatory=$true)]
        [string]$Source,

        [Parameter(Mandatory=$true)]
        [string]$RegistryKey
        )

    $keyPath = "HKLM:\$RegistryKey"
    $keyExists = Test-Path -Path $keyPath
    if ($keyExists)
    {
        $rowToAdd = $RegistrySettingsTable.NewRow()
        $rowToAdd.Source = $Source
        $rowToAdd.KeyName = $RegistryKey
        $RegistrySettingsTable.Rows.Add($rowToAdd)

        $key = Get-Item $keyPath
        $valueNames = $key | Select-Object -ExpandProperty Property
        foreach ($valueName in $valueNames)
        {
            $valueData = Get-ItemProperty -LiteralPath $keyPath -Name $valueName | Select-Object -ExpandProperty $valueName
            if ($valueName -eq "(default)")
            {
                $valueType = $key.GetValueKind("")
            }
            else
            {
                $valueType = $key.GetValueKind($valueName)
            }

            $rowToAdd = $RegistrySettingsTable.NewRow()
            $rowToAdd.Source = ""
            $rowToAdd.ValueName = $valueName
            $rowToAdd.ValueData = $valueData
            $rowToAdd.ValueType = $valueType
            $rowToAdd.Notes = PostProcessRegistryValue -Name $valueName -Value $valueData
            $rowToAdd.KeyName = $RegistryKey

            $RegistrySettingsTable.Rows.Add($rowToAdd)
        }
    }
    else
    {
         $rowToAdd = $RegistrySettingsTable.NewRow()
         $rowToAdd.Source = $Source + " - key not found"
         $rowToAdd.KeyName = $RegistryKey
         $RegistrySettingsTable.Rows.Add($rowToAdd)
    }

    $rowToAdd = $RegistrySettingsTable.NewRow()
    $rowToAdd.Source = ""
    $RegistrySettingsTable.Rows.Add($rowToAdd)
}

function ExportRegistryKeys()
{
    Param (
        [Parameter(Mandatory=$true)]
        [string]$DataFolder
        )

    Write-Verbose "Collecting registry key data of interest"

    $registrySettingsTable = New-Object System.Data.DataTable

    $registrySettingsTable.Columns.Add("Source", "string") | Out-Null
    $registrySettingsTable.Columns.Add("ValueName", "string") | Out-Null
    $registrySettingsTable.Columns.Add("ValueData", "string") | Out-Null
    $registrySettingsTable.Columns.Add("ValueType", "string") | Out-Null
    $registrySettingsTable.Columns.Add("Notes", "string") | Out-Null
    $registrySettingsTable.Columns.Add("KeyName", "string") | Out-Null

    $source = "CSP"
    $regKey = "Software\Microsoft\Policies\LAPS"
    ExportRegistryKey -RegistrySettingsTable $registrySettingsTable -Source $source -RegistryKey $regKey

    $source = "GPO"
    $regKey = "Software\Microsoft\Windows\CurrentVersion\Policies\LAPS"
    ExportRegistryKey -RegistrySettingsTable $registrySettingsTable -Source $source -RegistryKey $regKey

    $source = "LegacyLaps"
    $regKey = "Software\Policies\Microsoft Services\AdmPwd"
    ExportRegistryKey -RegistrySettingsTable $registrySettingsTable -Source $source -RegistryKey $regKey

    $source = "LocalConfig"
    $regKey = "Software\Microsoft\Windows\CurrentVersion\LAPS\Config"
    ExportRegistryKey -RegistrySettingsTable $registrySettingsTable -Source $source -RegistryKey $regKey

    $source = "LocalState"
    $regKey = "Software\Microsoft\Windows\CurrentVersion\LAPS\State"
    ExportRegistryKey -RegistrySettingsTable $registrySettingsTable -Source $source -RegistryKey $regKey

    $source = "LegacyLAPSGPExtension"
    $regKey = "Software\Microsoft\Windows NT\CurrentVersion\Winlogon\GPExtensions\{D76B9641-3288-4f75-942D-087DE603E3EA}"
    ExportRegistryKey -RegistrySettingsTable $registrySettingsTable -Source $source -RegistryKey $regKey

    $exportedKeys = $DataFolder + "\laps_registry.csv"

    Write-Verbose "Exporting registry key data to $exportedKeys"

    $registrySettingsTable | Export-Csv $exportedKeys -NoTypeInformation

    Write-Verbose "Done exporting registry keys"
}

function LapsDiagnosticsPrologue()
{
    Param (
        [Parameter(Mandatory=$true)]
        [string]$DataFolder,

        [Parameter(Mandatory=$true)]
        [bool]$CollectNetworkTrace
        )

    Write-Verbose "Get-LapsDiagnostics: LapsDiagnosticsPrologue starting"

    StartLapsWPPTracing $DataFolder

    StartLdapTracing $DataFolder

    if ($CollectNetworkTrace)
    {
        StartNetworkTrace $DataFolder
    }
}

function LapsDiagnosticsEpilogue()
{
    Param (
        [Parameter(Mandatory=$true)]
        [string]$DataFolder,

        [Parameter(Mandatory=$true)]
        [bool]$CollectNetworkTrace
        )

    Write-Verbose "Get-LapsDiagnostics: LapsDiagnosticsEpilogue starting"

    if ($CollectNetworkTrace)
    {
        StopNetworkTrace $DataFolder
    }

    StopLapsWPPTracing $DataFolder

    StopLdapTracing $DataFolder

    CopyOSBinaries $DataFolder

    ExportLAPSEventLog $DataFolder

    ExportRegistryKeys $DataFolder

    Write-Verbose "Get-LapsDiagnostics: LapsDiagnosticsEpilogue ending"
}

# The Get-LapsDiagnostics cmdlet gathers configuration state, health info, and other
# info useful to have when diagnosing issues. Trace logs are also captured, either
# across a process-policy directive (the default) or across a forced reset-password
# operation (if specified).
function Get-LapsDiagnostics
{
    [CmdletBinding(HelpUri="https://go.microsoft.com/fwlink/?linkid=2234013")]
    Param (
        [string]$OutputFolder,

        [Parameter()]
        [Switch]$CollectNetworkTrace,

        [Parameter()]
        [Switch]$ResetPassword
        )

    Write-Verbose "Get-LapsDiagnostics: starting OutputFolder:$OutputFolder CollectNetworkTrace:$CollectNetworkTrace ResetPassword:$ResetPassword"

    # Must run in a native bitness host to ensure proper exporting of registry keys
    if ([Environment]::Is64BitOperatingSystem -and ![Environment]::Is64BitProcess)
    {
        Write-Error "You must run this cmdlet in a 64-bit PowerShell window"
        Exit
    }

    if (!($OutputFolder))
    {
        $OutputFolder = "$env:TEMP\LapsDiagnostics"
        Write-Verbose "Get-LapsDiagnostics: OutputFolder not specified - defaulting to $OutputFolder"
    }

    # Verify or create root output folder
    $exists = Test-Path $OutputFolder
    if ($exists)
    {
        Write-Verbose "Get-LapsDiagnostics: '$OutputFolder' already exists - using it"
    }
    else
    {
        Write-Verbose "Get-LapsDiagnostics: folder '$OutputFolder' does not exist - creating it"
        New-Item $OutputFolder -Type Directory | Out-Null
        Write-Verbose "Get-LapsDiagnostics: created output folder '$OutputFolder'"
    }

    # Create a temporary destination folder
    $currentTime = Get-Date -Format yyyyMMddMM_HHmmss
    $baseName = "LapsDiagnostics_" + $env:ComputerName + "_" + $currentTime
    $dataFolder = $OutputFolder + "\" + $baseName
    New-Item $dataFolder -Type Directory | Out-Null
    Write-Verbose "Get-LapsDiagnostics: all data for this run will be collected in $dataFolder"

    # Create a zip file name
    $dataZipFile = $OutputFolder + "\" + $baseName + ".zip"
    Write-Verbose "Get-LapsDiagnostics: final data for this run will be written to $dataZipFile"

    try
    {
        LapsDiagnosticsPrologue $dataFolder $CollectNetworkTrace

        if ($ResetPassword)
        {
            Write-Verbose "Get-LapsDiagnostics: calling Reset-LapsPassword cmdlet"
            Reset-LapsPassword -ErrorAction Ignore
            if ($? -eq $true)
            {
                Write-Verbose "Get-LapsDiagnostics: Reset-LapsPassword cmdlet succeeded"
            }
            else
            {
                Write-Verbose "Get-LapsDiagnostics: Reset-LapsPassword cmdlet failed - see logs"
            }
        }
        else
        {
            Write-Verbose "Get-LapsDiagnostics: calling Invoke-LapsPolicyProcessing cmdlet"
            Invoke-LapsPolicyProcessing -ErrorAction Ignore
            if ($? -eq $true)
            {
                Write-Verbose "Get-LapsDiagnostics: Invoke-LapsPolicyProcessing succeeded"
            }
            else
            {
                Write-Verbose "Get-LapsDiagnostics: Invoke-LapsPolicyProcessing failed - - see logs"
            }
        }
    }
    catch
    {
        Write-Error "Caught exception:"
        Write-Error $($_.Exception)
    }
    finally
    {
        LapsDiagnosticsEpilogue $dataFolder $CollectNetworkTrace

        # Zip up the folder
        Compress-Archive -DestinationPath $dataZipFile -LiteralPath $dataFolder -Force

        # Delete the folder
        Remove-Item -Recurse -Force $dataFolder -ErrorAction Ignore
    }

    Write-Verbose "Get-LapsDiagnostics: finishing"

    Write-Host "Get-LapsDiagnostics: all data for this run was written to the following zip file:"
    Write-Host
    $dataZipFile
    Write-Host
}

# ConvertBase64ToSecureString (internal helper function - not exported)
function ConvertBase64ToSecureString()
{
    Param (
        [string]$Base64
    )

    if ([string]::IsNullOrEmpty($Base64))
    {
        throw
    }

    $bytes = [System.Convert]::FromBase64String($Base64)

    $plainText = [System.Text.Encoding]::UTF8.GetString($bytes)

    $secureString = ConvertTo-SecureString $plainText -AsPlainText -Force

    $secureString
}

# ConvertBase64ToPlainText (internal helper function - not exported)
function ConvertBase64ToPlainText()
{
    Param (
        [string]$Base64
    )

    if ([string]::IsNullOrEmpty($Base64))
    {
        throw
    }

    $bytes = [System.Convert]::FromBase64String($Base64)

    $plainText = [System.Text.Encoding]::UTF8.GetString($bytes)

    $plainText
}

# ProcessOneDevice (internal helper function - not exported)
function ProcessOneDevice()
{
    Param (
        [string]$DeviceId,
        [boolean]$IncludePasswords,
        [boolean]$IncludeHistory,
        [boolean]$AsPlainText
    )

    Write-Verbose "ProcessOneDevice starting for DeviceId:'$DeviceId' IncludePasswords:$IncludePasswords IncludeHistory:$IncludeHistory AsPlainText:$AsPlainText"

    # Check if a guid was passed in. If it looks like a guid we assume it's the device id.
    $guid = New-Object([System.Guid])
    $isGuid = [System.Guid]::TryParse($DeviceId, [ref]$guid)
    if (!$isGuid)
    {
        # $DeviceId is not a guid. Assume it's a DisplayName and look it up:
        Write-Verbose "Querying device '$DeviceId' to get its device id"
        $filter = "DisplayName eq '$DeviceId'"
        try
        {
            $mgDevice = Get-MgDevice -Filter $filter
        }
        catch
        {
            $mgDevice = $null
        }
        if ($mgDevice -eq $null)
        {
            Write-Error "Failed to lookup '$DeviceId' by DisplayName"
            return
        }

        $deviceName = $mgDevice.DisplayName
        $DeviceId = $mgDevice.DeviceId
        Write-Verbose "Device DisplayName: '$deviceName'"
        Write-Verbose "Device DeviceId: '$DeviceId'"

        # Use guid device id
        $DeviceId = $mgDevice.DeviceId
    }

    # Build URI - beta graph endpoint for now
    $uri = 'v1.0/directory/deviceLocalCredentials/' + $DeviceId

    # Get actual passwords if requested; note that $select=credentials will cause the server
    # to return all credentials, ie latest plus history. If -IncludeHistory was not actually
    # specified then we will drop the older passwords down below when displaying the results.
    if ($IncludePasswords)
    {
        $uri = $uri + '?$select=credentials'
    }

    # Create a new correlationID every time
    $correlationID = [System.Guid]::NewGuid()
    Write-Verbose "Created new GUID for cloud request correlation ID (client-request-id) '$correlationID'"

    $httpMethod = 'GET';

    $headers = @{}
    $headers.Add('ocp-client-name', 'Get-LapsAADPassword Windows LAPS Cmdlet')
    $headers.Add('ocp-client-version', '1.0')
    $headers.Add('client-request-id', $correlationID)

    try
    {
        Write-Verbose "Retrieving LAPS credentials for device id: '$DeviceId' with client-request-id:'$correlationID'"
        $queryResults = Invoke-MgGraphRequest -Method $httpMethod -Uri $URI -Headers $headers -OutputType Json
        Write-Verbose "Got LAPS credentials for device id: '$DeviceId':"
        Write-Verbose ""
        Write-Verbose $queryResults
        Write-Verbose ""
    }
    catch [Exception]
    {
        Write-Verbose "Failed trying to query LAPS credential for $DeviceId"
        Write-Verbose ""
        Write-Error $_
        Write-Verbose ""
        return
    }

    if ([string]::IsNullOrEmpty($queryResults))
    {
        Write-Verbose "Response was empty - device object does not have any persisted LAPS credentials"
        return
    }

    # Build custom PS output object
    Write-Verbose "Converting http response to json"
    $resultsJson = ConvertFrom-Json $queryResults
    Write-Verbose "Successfully converted http response to json:"
    Write-Verbose ""
    Write-Verbose $resultsJson
    Write-Verbose ""

    # Grab device name
    $lapsDeviceId = $resultsJson.deviceName

    # Grab device id
    $lapsDeviceId = New-Object([System.Guid])
    $lapsDeviceId = [System.Guid]::Parse($resultsJson.id)

    # Grab password expiration time (only applies to the latest password)
    $lapsPasswordExpirationTime = Get-Date $resultsJson.refreshDateTime

    if ($IncludePasswords)
    {
        # Copy the credentials array
        $credentials = $resultsJson.credentials

        # Sort the credentials array by backupDateTime.
        $credentials = $credentials | Sort-Object -Property backupDateTime -Descending

        # Note: current password (ie, the one most recently set) is now in the zero position of the array

        # If history was not requested, truncate the credential array down to just the latest one
        if (!$IncludeHistory)
        {
            $credentials = @($credentials[0])
        }

        foreach ($credential in $credentials)
        {
            $lapsDeviceCredential = New-Object PSObject

            Add-Member -InputObject $lapsDeviceCredential -MemberType NoteProperty -Name "DeviceName" -Value $resultsJson.deviceName

            Add-Member -InputObject $lapsDeviceCredential -MemberType NoteProperty -Name "DeviceId" -Value $lapsDeviceId

            Add-Member -InputObject $lapsDeviceCredential -MemberType NoteProperty -Name "Account" -Value $credential.accountName

            # Cloud returns passwords in base64, convert:

            if ($AsPlainText)
            {
                $password = ConvertBase64ToPlainText -base64 $credential.passwordBase64
            }
            else
            {
                $password = ConvertBase64ToSecureString -base64 $credential.passwordBase64
            }

            Add-Member -InputObject $lapsDeviceCredential -MemberType NoteProperty -Name "Password" -Value $password

            Add-Member -InputObject $lapsDeviceCredential -MemberType NoteProperty -Name "PasswordExpirationTime" -Value $lapsPasswordExpirationTime
            $lapsPasswordExpirationTime = $null

            $credentialUpdateTime = Get-Date $credential.backupDateTime
            Add-Member -InputObject $lapsDeviceCredential -MemberType NoteProperty -Name "PasswordUpdateTime" -Value $credentialUpdateTime

            # Note: cloud also returns an accountSid property - omitting it for now

            Write-Output $lapsDeviceCredential
        }
    }
    else
    {
        # Output a single object that just displays latest password expiration time
        # Note, $IncludeHistory is ignored even if specified in this case
        $lapsDeviceCredential = New-Object PSObject

        Add-Member -InputObject $lapsDeviceCredential -MemberType NoteProperty -Name "DeviceName" -Value $resultsJson.deviceName

        Add-Member -InputObject $lapsDeviceCredential -MemberType NoteProperty -Name "DeviceId" -Value $lapsDeviceId

        Add-Member -InputObject $lapsDeviceCredential -MemberType NoteProperty -Name "PasswordExpirationTime" -Value $lapsPasswordExpirationTime

        Write-Output $lapsDeviceCredential
    }
}

# DumpMSGraphContext (internal helper function - not exported)
function DumpMSGraphContext
{
    Param (
        [object]$MsGraphContext
    )

    # Dump some of the MSGraph context details for diagnostics purposes
    Write-Verbose "Dumping MSGraph context details:"

    if ($mgContext.ClientId)
    {
        $verbOutput = [string]::Format('  ClientId: {0}', $mgContext.ClientId)
        Write-Verbose $verbOutput
    }
    if ($mgContext.TenantId)
    {
        $verbOutput = [string]::Format('  TenantId: {0}', $mgContext.TenantId)
        Write-Verbose $verbOutput
    }
    if ($mgContext.AuthType)
    {
       $verbOutput = [string]::Format('  AuthType: {0}', $mgContext.AuthType)
       Write-Verbose $verbOutput
    }
    if ($mgContext.AuthProviderType)
    {
        $verbOutput = [string]::Format('  AuthProviderType: {0}', $mgContext.AuthProviderType)
        Write-Verbose $verbOutput
    }
    if ($mgContext.Account)
    {
        $verbOutput = [string]::Format('  Account: {0}', $mgContext.Account)
        Write-Verbose $verbOutput
    }
    if ($mgContext.AppName)
    {
        $verbOutput = [string]::Format('  AppName: {0}', $mgContext.AppName)
        Write-Verbose $verbOutput
    }
    if ($mgContext.ContextScope)
    {
        $verbOutput = [string]::Format('  ContextScope: {0}', $mgContext.ContextScope)
        Write-Verbose $verbOutput
    }
    if ($mgContext.PSHostVersion)
    {
        $verbOutput = [string]::Format('  PSHostVersion: {0}', $mgContext.PSHostVersion)
        Write-Verbose $verbOutput
    }
    if ($mgContext.Scopes)
    {
        Write-Verbose "  Scopes:"
        foreach ($scope in $mgContext.Scopes)
        {
            $verbOutput = [string]::Format('    {0}', $scope)
            Write-Verbose $verbOutput
        }
    }
}

# The Get-LapsAADPassword cmdlet is used to query LAPS passwords from Azure AD. At
# its core, it just submits MS graph queries and morphs the returned results into
# PowerShell objects.
#
# This cmdlet has a dependency on the MSGraph PowerShell library which may be
# installed like so:
#
#    Set-PSRepository PSGallery -InstallationPolicy Trusted
#    Install-Module Microsoft.Graph -Scope AllUsers
#
# Functional prerequisites:
#
#   You must be logged into into MSGraph before running this cmdlet - see the docs
#     on the Connect-MgGraph cmdlet.
#
#  An app needs to be created in your tenant that that configures the appropriate
#    scopes for querying DeviceLocalCredentials.
#
function Get-LapsAADPassword
{
    [CmdletBinding(DefaultParameterSetName = "DeviceSpecificQuery",
        HelpUri="https://go.microsoft.com/fwlink/?linkid=2234012")]
    Param (
        [Parameter(
            ParameterSetName="DeviceSpecificQuery",
            Mandatory=$true)
        ]
        [string[]]$DeviceIds,

        [Parameter()]
        [Switch]$IncludePasswords,

        [Parameter()]
        [Switch]$IncludeHistory,

        [Parameter()]
        [Switch]$AsPlainText
    )

    Write-Verbose "Get-LapsAADPassword starting IncludePasswords:$IncludePasswords AsPlainText:$AsPlainText"

    $now = Get-Date
    $utcNow = $now.ToUniversalTime()
    Write-Verbose "Local now: '$now' (UTC now: '$utcNow')"

    $activityId = [System.Diagnostics.Trace]::CorrelationManager.ActivityId
    Write-Verbose "Current activityId: $activityId"

    if ($AsPlainText -and !$IncludePasswords)
    {
        Write-Warning "Note: specifying -AsPlainText has no effect unless -IncludePasswords is also specified"
        $AsPlainText = $false
    }

    # Validate that admin has logged into MSGraph already
    $msGraphAuthModule = Get-Module "Microsoft.Graph.Authentication"
    if (!$msGraphAuthModule)
    {
        throw "You must install the MSGraph PowerShell module before running this cmdlet, for example by running 'Install-Module Microsoft.Graph -Scope AllUsers'."
    }

    # Validate that admin has logged into MSGraph already
    $mgContext = Get-MgContext
    if (!$mgContext)
    {
        throw "You must first authenticate to MSGraph first running this cmdlet; see Connect-MgGraph cmdlet."
    }

    # Dump MS graph context details when Verbose is enabled
    if ($VerbosePreference -ne [System.Management.Automation.ActionPreference]::SilentlyContinue)
    {
       DumpMSGraphContext -MsGraphContext $mgContext
    }

    foreach ($DeviceId in $DeviceIds)
    {
        # Ignore empty strings
        if ([string]::IsNullOrEmpty($DeviceId))
        {
            continue
        }

        ProcessOneDevice -DeviceId $DeviceId -IncludePasswords $IncludePasswords -IncludeHistory $IncludeHistory -AsPlainText $AsPlainText
    }
}
