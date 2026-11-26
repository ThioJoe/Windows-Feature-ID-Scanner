## Copyright (c) Microsoft Corporation. All rights reserved.

<#
.SYNOPSIS
This cmdlet collects a performance recording of Microsoft Defender Antivirus
scans.

.DESCRIPTION
This cmdlet collects a performance recording of Microsoft Defender Antivirus
scans. These performance recordings contain Microsoft-Antimalware-Engine
and NT kernel process events and can be analyzed after collection using the
Get-MpPerformanceReport cmdlet.

This cmdlet requires elevated administrator privileges.

The performance analyzer provides insight into problematic files that could
cause performance degradation of Microsoft Defender Antivirus. This tool is
provided "AS IS", and is not intended to provide suggestions on exclusions.
Exclusions can reduce the level of protection on your endpoints. Exclusions,
if any, should be defined with caution.

.EXAMPLE
New-MpPerformanceRecording -RecordTo:.\Defender-scans.etl

#>
function New-MpPerformanceRecording {
    [CmdletBinding(DefaultParameterSetName='Interactive')]
    param(

        # Specifies the location where to save the Microsoft Defender Antivirus
        # performance recording.
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$RecordTo,

        # Specifies the duration of the performance recording in seconds.
        [Parameter(Mandatory=$true, ParameterSetName='Timed')]
        [ValidateRange(0,2147483)]
        [int]$Seconds,

        # Specifies the PSSession object in which to create and save the Microsoft
        # Defender Antivirus performance recording. When you use this parameter,
        # the RecordTo parameter refers to the local path on the remote machine.
        [Parameter(Mandatory=$false)]
        [System.Management.Automation.Runspaces.PSSession[]]$Session,

        # Optional argument to specifiy a different tool for recording traces. Default is wpr.exe
        # When $Session parameter is used this path represents a location on the remote machine.
        [Parameter(Mandatory=$false)]
        [string]$WPRPath = $null

    )

    [bool]$interactiveMode = ($PSCmdlet.ParameterSetName -eq 'Interactive')
    [bool]$timedMode = ($PSCmdlet.ParameterSetName -eq 'Timed')

    # Hosts
    [string]$powerShellHostConsole = 'ConsoleHost'
    [string]$powerShellHostISE = 'Windows PowerShell ISE Host'
    [string]$powerShellHostRemote = 'ServerRemoteHost'

    if ($interactiveMode -and ($Host.Name -notin @($powerShellHostConsole, $powerShellHostISE, $powerShellHostRemote))) {
        $ex = New-Object System.Management.Automation.ItemNotFoundException 'Cmdlet supported only on local PowerShell console, Windows PowerShell ISE and remote PowerShell console.'
        $category = [System.Management.Automation.ErrorCategory]::NotImplemented
        $errRecord = New-Object System.Management.Automation.ErrorRecord $ex,'NotImplemented',$category,$Host.Name
        $psCmdlet.WriteError($errRecord)
        return
    }

    if ($null -ne $Session) {
        [int]$RemotedSeconds = if ($timedMode) { $Seconds } else { -1 }

        Invoke-Command -Session:$session -ArgumentList:@($RecordTo, $RemotedSeconds) -ScriptBlock:{
            param(
                [Parameter(Mandatory=$true)]
                [ValidateNotNullOrEmpty()]
                [string]$RecordTo,

                [Parameter(Mandatory=$true)]
                [ValidateRange(-1,2147483)]
                [int]$RemotedSeconds
            )

            if ($RemotedSeconds -eq -1) {
                New-MpPerformanceRecording -RecordTo:$RecordTo -WPRPath:$WPRPath
            } else {
                New-MpPerformanceRecording -RecordTo:$RecordTo -Seconds:$RemotedSeconds -WPRPath:$WPRPath
            }
        }

        return
    }

    if (-not (Test-Path -LiteralPath:$RecordTo -IsValid)) {
        $ex = New-Object System.Management.Automation.ItemNotFoundException "Cannot record Microsoft Defender Antivirus performance recording to path '$RecordTo' because the location does not exist."
        $category = [System.Management.Automation.ErrorCategory]::InvalidArgument
        $errRecord = New-Object System.Management.Automation.ErrorRecord $ex,'InvalidPath',$category,$RecordTo
        $psCmdlet.WriteError($errRecord)
        return
    }

    # Resolve any relative paths
    $RecordTo = $psCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RecordTo)

    # Dependencies: WPR Profile
    [string]$wprProfile = "$PSScriptRoot\MSFT_MpPerformanceRecording.wprp"

    if (-not (Test-Path -LiteralPath:$wprProfile -PathType:Leaf)) {
        $ex = New-Object System.Management.Automation.ItemNotFoundException "Cannot find dependency file '$wprProfile' because it does not exist."
        $category = [System.Management.Automation.ErrorCategory]::ObjectNotFound
        $errRecord = New-Object System.Management.Automation.ErrorRecord $ex,'PathNotFound',$category,$wprProfile
        $psCmdlet.WriteError($errRecord)
        return
    }

    # Dependencies: WPR Version
    try 
    {
        # If user provides a valid string as $WPRPath we go with that.
        [string]$wprCommand = $WPRPath

        if (!$wprCommand) {
            $wprCommand = "wpr.exe"
            $wprs = @(Get-Command -All "wpr" 2> $null)

            if ($wprs -and ($wprs.Length -ne 0)) {
                $latestVersion = [System.Version]"0.0.0.0"

                $wprs | ForEach-Object {
                    $currentVersion = $_.Version
                    $currentFullPath = $_.Source
                    $currentVersionString = $currentVersion.ToString()
                    Write-Host "Found $currentVersionString at $currentFullPath"

                    if ($currentVersion -gt $latestVersion) {
                        $latestVersion = $currentVersion
                        $wprCommand = $currentFullPath
                    }
                }
            }
        }
    }
    catch
    {
        # Fallback to the old ways in case we encounter an error (ex: version string format change).
        [string]$wprCommand = "wpr.exe"
    }
    finally 
    {
        Write-Host "`nUsing $wprCommand version $((Get-Command $wprCommand).FileVersionInfo.FileVersion)`n"    
    }
 
    #
    # Test dependency presence
    #
    if (-not (Get-Command $wprCommand -ErrorAction:SilentlyContinue)) {
        $ex = New-Object System.Management.Automation.ItemNotFoundException "Cannot find dependency command '$wprCommand' because it does not exist."
        $category = [System.Management.Automation.ErrorCategory]::ObjectNotFound
        $errRecord = New-Object System.Management.Automation.ErrorRecord $ex,'PathNotFound',$category,$wprCommand
        $psCmdlet.WriteError($errRecord)
        return
    }

    # Exclude versions that have known bugs or are not supported any more.
    [int]$wprFileVersion = ((Get-Command $wprCommand).Version.Major) -as [int]
    if ($wprFileVersion -le 6) {
        $ex = New-Object System.Management.Automation.PSNotSupportedException "You are using an older and unsupported version of '$wprCommand'. Please download and install Windows ADK:`r`nhttps://docs.microsoft.com/en-us/windows-hardware/get-started/adk-install`r`nand try again."
        $category = [System.Management.Automation.ErrorCategory]::NotInstalled
        $errRecord = New-Object System.Management.Automation.ErrorRecord $ex,'NotSupported',$category,$wprCommand
        $psCmdlet.WriteError($errRecord)
        return
    }

    function CancelPerformanceRecording {
        Write-Host "`n`nCancelling Microsoft Defender Antivirus performance recording... " -NoNewline

        & $wprCommand -cancel -instancename MSFT_MpPerformanceRecording
        $wprCommandExitCode = $LASTEXITCODE

        switch ($wprCommandExitCode) {
            0 {}
            0xc5583000 {
                Write-Error "Cannot cancel performance recording because currently Windows Performance Recorder is not recording."
                return
            }
            default {
                Write-Error ("Cannot cancel performance recording: 0x{0:x08}." -f $wprCommandExitCode)
                return
            }
        }

        Write-Host "ok.`n`nRecording has been cancelled."
    }

    #
    # Ensure Ctrl-C doesn't abort the app without cleanup
    #

    # - local PowerShell consoles: use [Console]::TreatControlCAsInput; cleanup performed and output preserved
    # - PowerShell ISE: use try { ... } catch { throw } finally; cleanup performed and output preserved
    # - remote PowerShell: use try { ... } catch { throw } finally; cleanup performed but output truncated

    [bool]$canTreatControlCAsInput = $interactiveMode -and ($Host.Name -eq $powerShellHostConsole)
    $savedControlCAsInput = $null

    $shouldCancelRecordingOnTerminatingError = $false

    try
    {
        if ($canTreatControlCAsInput) {
            $savedControlCAsInput = [Console]::TreatControlCAsInput
            [Console]::TreatControlCAsInput = $true
        }

        #
        # Start recording
        #

        Write-Host "Starting Microsoft Defender Antivirus performance recording... " -NoNewline

        $shouldCancelRecordingOnTerminatingError = $true

        & $wprCommand -start "$wprProfile!Scans.Light" -filemode -instancename MSFT_MpPerformanceRecording
        $wprCommandExitCode = $LASTEXITCODE

        switch ($wprCommandExitCode) {
            0 {}
            0xc5583001 {
                $shouldCancelRecordingOnTerminatingError = $false
                Write-Error "Cannot start performance recording because Windows Performance Recorder is already recording."
                return
            }
            default {
                $shouldCancelRecordingOnTerminatingError = $false
                Write-Error ("Cannot start performance recording: 0x{0:x08}." -f $wprCommandExitCode)
                return
            }
        }

        Write-Host "ok.`n`nRecording has started." -NoNewline

        if ($timedMode) {
            Write-Host "`n`n   Recording for $Seconds seconds... " -NoNewline

            Start-Sleep -Seconds:$Seconds
            
            Write-Host "ok." -NoNewline
        } elseif ($interactiveMode) {
            $stopPrompt = "`n`n=> Reproduce the scenario that is impacting the performance on your device.`n`n   Press <ENTER> to stop and save recording or <Ctrl-C> to cancel recording"

            if ($canTreatControlCAsInput) {
                Write-Host "${stopPrompt}: "

                do {
                    $key = [Console]::ReadKey($true)
                    if (($key.Modifiers -eq [ConsoleModifiers]::Control) -and (($key.Key -eq [ConsoleKey]::C))) {

                        CancelPerformanceRecording

                        $shouldCancelRecordingOnTerminatingError = $false

                        #
                        # Restore Ctrl-C behavior
                        #

                        [Console]::TreatControlCAsInput = $savedControlCAsInput

                        return
                    }

                } while (($key.Modifiers -band ([ConsoleModifiers]::Alt -bor [ConsoleModifiers]::Control -bor [ConsoleModifiers]::Shift)) -or ($key.Key -ne [ConsoleKey]::Enter))

            } else {
                Read-Host -Prompt:$stopPrompt
            }
        }

        #
        # Stop recording
        #

        Write-Host "`n`nStopping Microsoft Defender Antivirus performance recording... "

        & $wprCommand -stop $RecordTo -instancename MSFT_MpPerformanceRecording
        $wprCommandExitCode = $LASTEXITCODE

        switch ($wprCommandExitCode) {
            0 {
                $shouldCancelRecordingOnTerminatingError = $false
            }
            0xc5583000 {
                $shouldCancelRecordingOnTerminatingError = $false
                Write-Error "Cannot stop performance recording because Windows Performance Recorder is not recording a trace."
                return
            }
            default {
                Write-Error ("Cannot stop performance recording: 0x{0:x08}." -f $wprCommandExitCode)
                return
            }
        }

        Write-Host "ok.`n`nRecording has been saved to '$RecordTo'."

        Write-Host `
'
The performance analyzer provides insight into problematic files that could
cause performance degradation of Microsoft Defender Antivirus. This tool is
provided "AS IS", and is not intended to provide suggestions on exclusions.
Exclusions can reduce the level of protection on your endpoints. Exclusions,
if any, should be defined with caution.
'
Write-Host `
'
The trace you have just captured may contain personally identifiable information,
including but not necessarily limited to paths to files accessed, paths to
registry accessed and process names. Exact information depends on the events that
were logged. Please be aware of this when sharing this trace with other people.
'
    } catch {
        throw
    } finally {
        if ($shouldCancelRecordingOnTerminatingError) {
            CancelPerformanceRecording
        }

        if ($null -ne $savedControlCAsInput) {
            #
            # Restore Ctrl-C behavior
            #

            [Console]::TreatControlCAsInput = $savedControlCAsInput
        }
    }
}

function PadUserDateTime
{
    [OutputType([DateTime])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [DateTime]$UserDateTime
    )

    # Padding user input to include all events up to the start of the next second.
    if (($UserDateTime.Ticks % 10000000) -eq 0)
    {
        return $UserDateTime.AddTicks(9999999)
    }
    else
    {
        return $UserDateTime
    }
}

function ValidateTimeInterval
{
    [OutputType([PSCustomObject])]
    param(
        [DateTime]$MinStartTime = [DateTime]::MinValue,
        [DateTime]$MinEndTime = [DateTime]::MinValue,
        [DateTime]$MaxStartTime = [DateTime]::MaxValue,
        [DateTime]$MaxEndTime = [DateTime]::MaxValue
    )

    $ret = [PSCustomObject]@{
        arguments = [string[]]@()
        status = $false
    }
    
    if ($MinStartTime -gt $MaxEndTime)
    {
        $ex = New-Object System.Management.Automation.ValidationMetadataException "MinStartTime '$MinStartTime' should have been lower than MaxEndTime '$MaxEndTime'"
        $category = [System.Management.Automation.ErrorCategory]::InvalidArgument
        $errRecord = New-Object System.Management.Automation.ErrorRecord $ex,'Invalid time interval',$category,"'$MinStartTime' .. '$MaxEndTime'"
        $psCmdlet.WriteError($errRecord)
        return $ret
    }

    if ($MinStartTime -gt $MaxStartTime)
    {
        $ex = New-Object System.Management.Automation.ValidationMetadataException "MinStartTime '$MinStartTime' should have been lower than MaxStartTime '$MaxStartTime'"
        $category = [System.Management.Automation.ErrorCategory]::InvalidArgument
        $errRecord = New-Object System.Management.Automation.ErrorRecord $ex,'Invalid time interval',$category,"'$MinStartTime' .. '$MaxStartTime'"
        $psCmdlet.WriteError($errRecord)
        return $ret
    }

    if ($MinEndTime -gt $MaxEndTime)
    {
        $ex = New-Object System.Management.Automation.ValidationMetadataException "MinEndTime '$MinEndTime' should have been lower than MaxEndTime '$MaxEndTime'"
        $category = [System.Management.Automation.ErrorCategory]::InvalidArgument
        $errRecord = New-Object System.Management.Automation.ErrorRecord $ex,'Invalid time interval',$category,"'$MinEndTime' .. '$MaxEndTime'"
        $psCmdlet.WriteError($errRecord)
        return $ret
    }

    if ($MinStartTime -gt [DateTime]::MinValue)
    {
        try
        {
            $MinStartFileTime = $MinStartTime.ToFileTime()
        }
        catch
        {
            $ex = New-Object System.Management.Automation.ValidationMetadataException "MinStartTime '$MinStartTime' is not a valid timestamp."
            $category = [System.Management.Automation.ErrorCategory]::InvalidArgument
            $errRecord = New-Object System.Management.Automation.ErrorRecord $ex,'Value has to be a local DateTime between "January 1, 1601 12:00:00 AM UTC" and "December 31, 9999 11:59:59 PM UTC"',$category,"'$MinStartTime'"
            $psCmdlet.WriteError($errRecord)
            return $ret
        }

        $ret.arguments += @('-MinStartTime', $MinStartFileTime)
    }

    if ($MaxEndTime -lt [DateTime]::MaxValue)
    {
        try 
        {
            $MaxEndFileTime = $MaxEndTime.ToFileTime()
        }
        catch 
        {
            $ex = New-Object System.Management.Automation.ValidationMetadataException "MaxEndTime '$MaxEndTime' is not a valid timestamp."
            $category = [System.Management.Automation.ErrorCategory]::InvalidArgument
            $errRecord = New-Object System.Management.Automation.ErrorRecord $ex,'Value has to be a local DateTime between "January 1, 1601 12:00:00 AM UTC" and "December 31, 9999 11:59:59 PM UTC"',$category,"'$MaxEndTime'"
            $psCmdlet.WriteError($errRecord)
            return $ret               
        }
    
        $ret.arguments += @('-MaxEndTime', $MaxEndFileTime)
    }

    if ($MaxStartTime -lt [DateTime]::MaxValue)
    {
        try
        {
            $MaxStartFileTime = $MaxStartTime.ToFileTime()
        }
        catch
        {
            $ex = New-Object System.Management.Automation.ValidationMetadataException "MaxStartTime '$MaxStartTime' is not a valid timestamp."
            $category = [System.Management.Automation.ErrorCategory]::InvalidArgument
            $errRecord = New-Object System.Management.Automation.ErrorRecord $ex,'Value has to be a local DateTime between "January 1, 1601 12:00:00 AM UTC" and "December 31, 9999 11:59:59 PM UTC"',$category,"'$MaxStartTime'"
            $psCmdlet.WriteError($errRecord)
            return $ret
        }

        $ret.arguments += @('-MaxStartTime', $MaxStartFileTime)
    }

    if ($MinEndTime -gt [DateTime]::MinValue)
    {
        try 
        {
            $MinEndFileTime = $MinEndTime.ToFileTime()
        }
        catch 
        {
            $ex = New-Object System.Management.Automation.ValidationMetadataException "MinEndTime '$MinEndTime' is not a valid timestamp."
            $category = [System.Management.Automation.ErrorCategory]::InvalidArgument
            $errRecord = New-Object System.Management.Automation.ErrorRecord $ex,'Value has to be a local DateTime between "January 1, 1601 12:00:00 AM UTC" and "December 31, 9999 11:59:59 PM UTC"',$category,"'$MinEndTime'"
            $psCmdlet.WriteError($errRecord)
            return $ret              
        }
        
        $ret.arguments += @('-MinEndTime', $MinEndFileTime)
    }

    $ret.status = $true
    return $ret
}

function ParseFriendlyDuration
{
    [OutputType([TimeSpan])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]
        $FriendlyDuration
    )

    if ($FriendlyDuration -match '^(\d+)(?:\.(\d+))?(sec|ms|us)$')
    {
        [string]$seconds = $Matches[1]
        [string]$decimals = $Matches[2]
        [string]$unit = $Matches[3]

        [uint32]$magnitude =
            switch ($unit)
            {
                'sec' {7}
                'ms' {4}
                'us' {1}
            }

        if ($decimals.Length -gt $magnitude)
        {
            throw [System.ArgumentException]::new("String '$FriendlyDuration' was not recognized as a valid Duration: $($decimals.Length) decimals specified for time unit '$unit'; at most $magnitude expected.")
        }

        return [timespan]::FromTicks([int64]::Parse($seconds + $decimals.PadRight($magnitude, '0')))
    }

    [timespan]$result = [timespan]::FromTicks(0)
    if ([timespan]::TryParse($FriendlyDuration, [ref]$result))
    {
        return $result
    }

    throw [System.ArgumentException]::new("String '$FriendlyDuration' was not recognized as a valid Duration; expected a value like '0.1234567sec' or '0.1234ms' or '0.1us' or a valid TimeSpan.")
}

[scriptblock]$FriendlyTimeSpanToString = { '{0:0.0000}ms' -f ($this.Ticks / 10000.0) }

function New-FriendlyTimeSpan
{
    param(
        [Parameter(Mandatory = $true)]
        [uint64]$Ticks,

        [bool]$Raw = $false
    )

    if ($Raw) {
        return $Ticks
    }

    $result = [TimeSpan]::FromTicks($Ticks)
    $result.PsTypeNames.Insert(0, 'MpPerformanceReport.TimeSpan')
    $result | Add-Member -Force -MemberType:ScriptMethod -Name:'ToString' -Value:$FriendlyTimeSpanToString
    $result
}

function New-FriendlyDateTime
{
    param(
        [Parameter(Mandatory = $true)]
        [uint64]$FileTime,

        [bool]$Raw = $false
    )

    if ($Raw) {
        return $FileTime
    }

    [DateTime]::FromFileTime($FileTime)
}

function Add-DefenderCollectionType
{
    param(
        [Parameter(Mandatory = $true)]
        [ref]$CollectionRef
    )

    if ($CollectionRef.Value.Length -and ($CollectionRef.Value | Get-Member -Name:'Processes','Files','Extensions','Scans','Folder'))
    {
        $CollectionRef.Value.PSTypeNames.Insert(0, 'MpPerformanceReport.NestedCollection')
    }
}

[scriptblock]$FriendlyScanInfoToString = { 
    [PSCustomObject]@{
        ScanType = $this.ScanType
        StartTime = $this.StartTime
        EndTime = $this.EndTime
        Duration = $this.Duration
        Reason = $this.Reason
        Path = $this.Path
        ProcessPath = $this.ProcessPath
        ProcessId = $this.ProcessId
        Image = $this.Image
    }
}

function Get-ScanComments
{
    param(
        [PSCustomObject[]]$SecondaryEvents,
        [bool]$Raw = $false
    )

    $Comments = @()

    foreach ($item in @($SecondaryEvents | Sort-Object -Property:StartTime)) {
        if (($item | Get-Member -Name:'Message' -MemberType:NoteProperty).Count -eq 1) {
            if (($item | Get-Member -Name:'Duration' -MemberType:NoteProperty).Count -eq 1) {
                $Duration  = New-FriendlyTimeSpan -Ticks:$item.Duration -Raw:$Raw
                $StartTime = New-FriendlyDateTime -FileTime:$item.StartTime -Raw:$Raw

                $Comments += "Expensive operation `"{0}`" started at {1} lasted {2}" -f ($item.Message, $StartTime, $Duration.ToString())

                if (($item | Get-Member -Name:'Debug' -MemberType:NoteProperty).Count -eq 1) {
                    $item.Debug | ForEach-Object {
                        if ($_.EndsWith("is NOT trusted") -or $_.StartsWith("Not trusted, ") -or $_.ToLower().Contains("error") -or $_.Contains("Result of ValidateTrust")) {
                            $Comments += "$_"
                        }
                    }
                }
            }
            else {
                if ($item.Message.Contains("subtype=Lowfi")) {
                    $Comments += $item.Message.Replace("subtype=Lowfi", "Low-fidelity detection")
                }
                else {
                    $Comments += $item.Message
                }
            }
        }
        elseif (($item | Get-Member -Name:'ScanType' -MemberType:NoteProperty).Count -eq 1) {
            $Duration = New-FriendlyTimeSpan -Ticks:$item.Duration -Raw:$Raw
            $OpId = "Internal opertion"
            
            if (($item | Get-Member -Name:'Path' -MemberType:NoteProperty).Count -eq 1) {
                $OpId = $item.Path
            }
            elseif (($item | Get-Member -Name:'ProcessPath' -MemberType:NoteProperty).Count -eq 1) {
                $OpId = $item.ProcessPath
            }

            $Comments += "{0} {1} lasted {2}" -f ($item.ScanType, $OpId, $Duration.ToString())
        }
    }

    $Comments 
}

filter ConvertTo-DefenderScanInfo
{
    param(
        [bool]$Raw = $false
    )

    $result = [PSCustomObject]@{
        ScanType = [string]$_.ScanType
        StartTime = New-FriendlyDateTime -FileTime:$_.StartTime -Raw:$Raw
        EndTime = New-FriendlyDateTime -FileTime:$_.EndTime -Raw:$Raw
        Duration = New-FriendlyTimeSpan -Ticks:$_.Duration -Raw:$Raw
        Reason = [string]$_.Reason
        SkipReason = [string]$_.SkipReason
    }

    if (($_ | Get-Member -Name:'Path' -MemberType:NoteProperty).Count -eq 1) {
        $result | Add-Member -NotePropertyName:'Path' -NotePropertyValue:([string]$_.Path)
    }

    if (($_ | Get-Member -Name:'ProcessPath' -MemberType:NoteProperty).Count -eq 1) {
        $result | Add-Member -NotePropertyName:'ProcessPath' -NotePropertyValue:([string]$_.ProcessPath)
    }

    if (($_ | Get-Member -Name:'Image' -MemberType:NoteProperty).Count -eq 1) {
        $result | Add-Member -NotePropertyName:'Image' -NotePropertyValue:([string]$_.Image)
    }
    elseif ($_.ProcessPath -and (-not $_.ProcessPath.StartsWith("pid"))) {
        try {
            $result | Add-Member -NotePropertyName:'Image' -NotePropertyValue:([string]([System.IO.FileInfo]$_.ProcessPath).Name)
        } catch {
            # Silently ignore.
        }
    }

    $ProcessId = if ($_.ProcessId -gt 0) { [int]$_.ProcessId } elseif ($_.ScannedProcessId -gt 0) { [int]$_.ScannedProcessId } else { $null }
    if ($ProcessId) {
        $result | Add-Member -NotePropertyName:'ProcessId' -NotePropertyValue:([int]$ProcessId)
    }

    if ($result.Image -and $result.ProcessId) {
        $ProcessName = "{0} ({1})" -f $result.Image, $result.ProcessId
        $result | Add-Member -NotePropertyName:'ProcessName' -NotePropertyValue:([string]$ProcessName)
    }

    if ((($_ | Get-Member -Name:'Extra' -MemberType:NoteProperty).Count -eq 1) -and ($_.Extra.Count -gt 0)) {
        $Comments = @(Get-ScanComments -SecondaryEvents:$_.Extra -Raw:$Raw)
        $result | Add-Member -NotePropertyName:'Comments' -NotePropertyValue:$Comments
    }

    if (-not $Raw) {
        $result.PSTypeNames.Insert(0, 'MpPerformanceReport.ScanInfo')
    }

    $result | Add-Member -Force -MemberType:ScriptMethod -Name:'ToString' -Value:$FriendlyScanInfoToString
    $result
}

filter ConvertTo-DefenderScanOverview
{
    param(
        [bool]$Raw = $false
    )

    $vals = [ordered]@{}

    foreach ($entry in $_.PSObject.Properties) {
        if ($entry.Value) {
            $Key = $entry.Name.Replace("_", " ")

            if ($Key.EndsWith("Time")) {
                $vals[$Key] = New-FriendlyDateTime -FileTime:$entry.Value -Raw:$Raw
            }
            elseif ($Key.EndsWith("Duration")) {
                $vals[$Key] = New-FriendlyTimeSpan -Ticks:$entry.Value -Raw:$Raw
            }
            else {
                $vals[$Key] = $entry.Value
            }
        }
    }

    # Remove duplicates
    if (($_ | Get-Member -Name:'PerfHints' -MemberType:NoteProperty).Count -eq 1) {
        $hints = [ordered]@{}
        foreach ($hint in $_.PerfHints) {
            $hints[$hint] = $true
        }

        $vals["PerfHints"] = @($hints.Keys)
    }

    $result = New-Object PSCustomObject -Property:$vals
    $result
}

filter ConvertTo-DefenderScanStats
{
    param(
        [bool]$Raw = $false
    )

    $result = [PSCustomObject]@{
        Count = $_.Count
        TotalDuration = New-FriendlyTimeSpan -Ticks:$_.TotalDuration -Raw:$Raw
        MinDuration = New-FriendlyTimeSpan -Ticks:$_.MinDuration -Raw:$Raw
        AverageDuration = New-FriendlyTimeSpan -Ticks:$_.AverageDuration -Raw:$Raw
        MaxDuration = New-FriendlyTimeSpan -Ticks:$_.MaxDuration -Raw:$Raw
        MedianDuration = New-FriendlyTimeSpan -Ticks:$_.MedianDuration -Raw:$Raw
    }

    if (-not $Raw) {
        $result.PSTypeNames.Insert(0, 'MpPerformanceReport.ScanStats')
    }

    $result
}

[scriptblock]$FriendlyScannedFilePathStatsToString = {
    [PSCustomObject]@{
        Count = $this.Count
        TotalDuration = $this.TotalDuration
        MinDuration = $this.MinDuration
        AverageDuration = $this.AverageDuration
        MaxDuration = $this.MaxDuration
        MedianDuration = $this.MedianDuration
        Path = $this.Path
    }
}

filter ConvertTo-DefenderScannedFilePathStats
{
    param(
        [bool]$Raw = $false
    )

    $result = $_ | ConvertTo-DefenderScanStats -Raw:$Raw

    if (-not $Raw) {
        $result.PSTypeNames.Insert(0, 'MpPerformanceReport.ScannedFilePathStats')
    }
    
    $result | Add-Member -NotePropertyName:'Path' -NotePropertyValue:($_.Path)
    $result | Add-Member -Force -MemberType:ScriptMethod -Name:'ToString' -Value:$FriendlyScannedFilePathStatsToString

    if ($null -ne $_.Scans)
    {
        $result | Add-Member -NotePropertyName:'Scans' -NotePropertyValue:@(
            $_.Scans | ConvertTo-DefenderScanInfo -Raw:$Raw
        )

        if (-not $Raw) {
            Add-DefenderCollectionType -CollectionRef:([ref]$result.Scans)
        }
    }

    if ($null -ne $_.Processes)
    {
        $result | Add-Member -NotePropertyName:'Processes' -NotePropertyValue:@(
            $_.Processes | ConvertTo-DefenderScannedProcessStats -Raw:$Raw
        )

        if (-not $Raw) {
            Add-DefenderCollectionType -CollectionRef:([ref]$result.Processes)
        }
    }

    $result
}

[scriptblock]$FriendlyScannedPathsStatsToString = { 
    [PSCustomObject]@{
        Count = $this.Count
        TotalDuration = $this.TotalDuration
        MinDuration = $this.MinDuration
        AverageDuration = $this.AverageDuration
        MaxDuration = $this.MaxDuration
        MedianDuration = $this.MedianDuration
        Path = $this.Path
        Folder = $this.Folder
    }
}

filter ConvertTo-DefenderScannedPathsStats
{
    param(
        [bool]$Raw = $false
    )

    $result = $_ | ConvertTo-DefenderScanStats -Raw:$Raw

    if (-not $Raw) {
        $result.PSTypeNames.Insert(0, 'MpPerformanceReport.ScannedPathStats')
    }

    $result | Add-Member -NotePropertyName:'Path' -NotePropertyValue:($_.Path)

    if ($null -ne $_.Folder)
    {
        $result | Add-Member -NotePropertyName:'Folder' -NotePropertyValue:@(
            $_.Folder | ConvertTo-DefenderScannedPathsStats -Raw:$Raw
        )
        $result | Add-Member -Force -MemberType:ScriptMethod -Name:'ToString' -Value:$FriendlyScannedPathsStatsToString

        if (-not $Raw) {
            Add-DefenderCollectionType -CollectionRef:([ref]$result.Folder)
        }
    }

    if ($null -ne $_.Files)
    {
        $result | Add-Member -NotePropertyName:'Files' -NotePropertyValue:@(
            $_.Files | ConvertTo-DefenderScannedFilePathStats -Raw:$Raw
        )

        if (-not $Raw) {
            Add-DefenderCollectionType -CollectionRef:([ref]$result.Files)
        }
    }

    if ($null -ne $_.Scans)
    {
        $result | Add-Member -NotePropertyName:'Scans' -NotePropertyValue:@(
            $_.Scans | ConvertTo-DefenderScanInfo -Raw:$Raw
        )

        if (-not $Raw) {
            Add-DefenderCollectionType -CollectionRef:([ref]$result.Scans)
        }
    }

    if ($null -ne $_.Processes)
    {
        $result | Add-Member -NotePropertyName:'Processes' -NotePropertyValue:@(
            $_.Processes | ConvertTo-DefenderScannedProcessStats -Raw:$Raw
        )

        if (-not $Raw) {
            Add-DefenderCollectionType -CollectionRef:([ref]$result.Processes)
        }
    }

    $result
}

[scriptblock]$FriendlyScannedFileExtensionStatsToString = {
    [PSCustomObject]@{
        Count = $this.Count
        TotalDuration = $this.TotalDuration
        MinDuration = $this.MinDuration
        AverageDuration = $this.AverageDuration
        MaxDuration = $this.MaxDuration
        MedianDuration = $this.MedianDuration
        Extension = $this.Extension
    }
}

filter ConvertTo-DefenderScannedFileExtensionStats
{
    param(
        [bool]$Raw = $false
    )

    $result = $_ | ConvertTo-DefenderScanStats -Raw:$Raw

    if (-not $Raw) {
        $result.PSTypeNames.Insert(0, 'MpPerformanceReport.ScannedFileExtensionStats')
    }

    $result | Add-Member -NotePropertyName:'Extension' -NotePropertyValue:($_.Extension)
    $result | Add-Member -Force -MemberType:ScriptMethod -Name:'ToString' -Value:$FriendlyScannedFileExtensionStatsToString

    if ($null -ne $_.Scans)
    {
        $result | Add-Member -NotePropertyName:'Scans' -NotePropertyValue:@(
            $_.Scans | ConvertTo-DefenderScanInfo -Raw:$Raw
        )

        if (-not $Raw) {
            Add-DefenderCollectionType -CollectionRef:([ref]$result.Scans)
        }
    }

    if ($null -ne $_.Files)
    {
        $result | Add-Member -NotePropertyName:'Files' -NotePropertyValue:@(
            $_.Files | ConvertTo-DefenderScannedFilePathStats -Raw:$Raw
        )

        if (-not $Raw) {
            Add-DefenderCollectionType -CollectionRef:([ref]$result.Files)
        }
    }

    if ($null -ne $_.Processes)
    {
        $result | Add-Member -NotePropertyName:'Processes' -NotePropertyValue:@(
            $_.Processes | ConvertTo-DefenderScannedProcessStats -Raw:$Raw
        )

        if (-not $Raw) {
            Add-DefenderCollectionType -CollectionRef:([ref]$result.Processes)
        }
    }


    if ($null -ne $_.Folder)
    {
        $result | Add-Member -NotePropertyName:'Folder' -NotePropertyValue:@(
            $_.Folder | ConvertTo-DefenderScannedPathsStats -Raw:$Raw
        )

        if (-not $Raw) {
            Add-DefenderCollectionType -CollectionRef:([ref]$result.Folder)
        }
    }

    $result
}

[scriptblock]$FriendlyScannedProcessStatsToString = { 
    [PSCustomObject]@{
        Count = $this.Count
        TotalDuration = $this.TotalDuration
        MinDuration = $this.MinDuration
        AverageDuration = $this.AverageDuration
        MaxDuration = $this.MaxDuration
        MedianDuration = $this.MedianDuration
        ProcessPath = $this.ProcessPath
    }
}

filter ConvertTo-DefenderScannedProcessStats
{
    param(
        [bool]$Raw
    )

    $result = $_ | ConvertTo-DefenderScanStats -Raw:$Raw

    if (-not $Raw) {
        $result.PSTypeNames.Insert(0, 'MpPerformanceReport.ScannedProcessStats')
    }

    $result | Add-Member -NotePropertyName:'ProcessPath' -NotePropertyValue:($_.Process)
    $result | Add-Member -Force -MemberType:ScriptMethod -Name:'ToString' -Value:$FriendlyScannedProcessStatsToString

    if ($null -ne $_.Scans)
    {
        $result | Add-Member -NotePropertyName:'Scans' -NotePropertyValue:@(
            $_.Scans | ConvertTo-DefenderScanInfo -Raw:$Raw
        )

        if (-not $Raw) {
            Add-DefenderCollectionType -CollectionRef:([ref]$result.Scans)
        }
    }

    if ($null -ne $_.Files)
    {
        $result | Add-Member -NotePropertyName:'Files' -NotePropertyValue:@(
            $_.Files | ConvertTo-DefenderScannedFilePathStats -Raw:$Raw
        )

        if (-not $Raw) {
            Add-DefenderCollectionType -CollectionRef:([ref]$result.Files)
        }
    }

    if ($null -ne $_.Extensions)
    {
        $result | Add-Member -NotePropertyName:'Extensions' -NotePropertyValue:@(
            $_.Extensions | ConvertTo-DefenderScannedFileExtensionStats -Raw:$Raw
        )

        if (-not $Raw) {
            Add-DefenderCollectionType -CollectionRef:([ref]$result.Extensions)
        }
    }

    if ($null -ne $_.Folder)
    {
        $result | Add-Member -NotePropertyName:'Folder' -NotePropertyValue:@(
            $_.Folder | ConvertTo-DefenderScannedPathsStats -Raw:$Raw
        )

        if (-not $Raw) {
            Add-DefenderCollectionType -CollectionRef:([ref]$result.Folder)
        }
    }

    $result
}

<#
.SYNOPSIS
This cmdlet reports the file paths, file extensions, and processes that cause
the highest impact to Microsoft Defender Antivirus scans.

.DESCRIPTION
This cmdlet analyzes a previously collected Microsoft Defender Antivirus
performance recording and reports the file paths, file extensions and processes
that cause the highest impact to Microsoft Defender Antivirus scans.

The performance analyzer provides insight into problematic files that could
cause performance degradation of Microsoft Defender Antivirus. This tool is
provided "AS IS", and is not intended to provide suggestions on exclusions.
Exclusions can reduce the level of protection on your endpoints. Exclusions,
if any, should be defined with caution.

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopFiles:10 -TopExtensions:10 -TopProcesses:10 -TopScans:10

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopFiles:10 -TopExtensions:10 -TopProcesses:10 -TopScans:10 -Raw | ConvertTo-Json

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopScans:10

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopFiles:10

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopFiles:10 -TopScansPerFile:3

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopFiles:10 -TopProcessesPerFile:3

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopFiles:10 -TopProcessesPerFile:3 -TopScansPerProcessPerFile:3

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopPaths:10

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopPaths:10 -TopPathsDepth:3

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopPaths:10 -TopPathsDepth:3 -TopScansPerPath:3

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopPaths:10 -TopScansPerPath:3

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopPaths:10 -TopPathsDepth:3 -TopFilesPerPath:3

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopPaths:10 -TopFilesPerPath:3

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopPaths:10 -TopPathsDepth:3 -TopFilesPerPath:3 -TopScansPerFilePerPath:3

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopPaths:10 -TopFilesPerPath:3 -TopScansPerFilePerPath:3

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopPaths:10 -TopPathsDepth:3 -TopExtensionsPerPath:3

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopPaths:10 -TopExtensionsPerPath:3

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopPaths:10 -TopPathsDepth:3 -TopExtensionsPerPath:3 -TopScansPerExtensionPerPath:3

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopPaths:10 -TopExtensionsPerPath:3 -TopScansPerExtensionPerPath:3

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopPaths:10 -TopPathsDepth:3 -TopProcessesPerPath:3

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopPaths:10 -TopProcessesPerPath:3

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopPaths:10 -TopPathsDepth:3 -TopProcessesPerPath:3 -TopScansPerProcessPerPath:3

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopPaths:10 -TopProcessesPerPath:3 -TopScansPerProcessPerPath:3

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopExtensions:10

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopExtensions:10 -TopScansPerExtension:3

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopExtensions:10 -TopPathsPerExtension:3

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopExtensions:10 -TopPathsPerExtension:3 -TopPathsDepth:3

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopExtensions:10 -TopPathsPerExtension:3 -TopPathsDepth:3 -TopScansPerPathPerExtension:3

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopExtensions:10 -TopPathsPerExtension:3 -TopScansPerPathPerExtension:3

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopExtensions:10 -TopFilesPerExtension:3

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopExtensions:10 -TopFilesPerExtension:3 -TopScansPerFilePerExtension:3

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopExtensions:10 -TopProcessesPerExtension:3

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopExtensions:10 -TopProcessesPerExtension:3 -TopScansPerProcessPerExtension:3

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopProcesses:10

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopProcesses:10 -TopScansPerProcess:3

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopProcesses:10 -TopExtensionsPerProcess:3

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopProcesses:10 -TopExtensionsPerProcess:3 -TopScansPerExtensionPerProcess:3

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopProcesses:10 -TopFilesPerProcess:3

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopProcesses:10 -TopFilesPerProcess:3 -TopScansPerFilePerProcess:3

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopProcesses:10 -TopPathsPerProcess:3

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopProcesses:10 -TopPathsPerProcess:3 -TopPathsDepth:3

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopProcesses:10 -TopPathsPerProcess:3 -TopPathsDepth:3 -TopScansPerPathPerProcess:3

.EXAMPLE
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopProcesses:10 -TopPathsPerProcess:3 -TopScansPerPathPerProcess:3

.EXAMPLE
# Find top 10 scans with longest durations that both start and end between MinStartTime and MaxEndTime:
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopScans:10 -MinStartTime:"5/14/2022 7:01:11 AM" -MaxEndTime:"5/14/2022 7:01:41 AM"

.EXAMPLE
# Find top 10 scans with longest durations between MinEndTime and MaxStartTime, possibly partially overlapping this period
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopScans:10 -MinEndTime:"5/14/2022 7:01:11 AM" -MaxStartTime:"5/14/2022 7:01:41 AM"

.EXAMPLE
# Find top 10 scans with longest durations between MinStartTime and MaxStartTime, possibly partially overlapping this period
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopScans:10 -MinStartTime:"5/14/2022 7:01:11 AM" -MaxStartTime:"5/14/2022 7:01:41 AM"

.EXAMPLE
# Find top 10 scans with longest durations that start at MinStartTime or later:
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopScans:10 -MinStartTime:"5/14/2022 7:01:11 AM"

.EXAMPLE
# Find top 10 scans with longest durations that start before or at MaxStartTime:
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopScans:10 -MaxStartTime:"5/14/2022 7:01:11 AM"

.EXAMPLE
# Find top 10 scans with longest durations that end at MinEndTime or later:
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopScans:10 -MinEndTime:"5/14/2022 7:01:11 AM"

.EXAMPLE
# Find top 10 scans with longest durations that end before or at MaxEndTime:
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopScans:10 -MaxEndTime:"5/14/2022 7:01:11 AM"

.EXAMPLE
# Find top 10 scans with longest durations, impacting the current interval, that did not start or end between MaxStartTime and MinEndTime.
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopScans:10 -MaxStartTime:"5/14/2022 7:01:11 AM" -MinEndTime:"5/14/2022 7:01:41 AM"

.EXAMPLE
# Find top 10 scans with longest durations, impacting the current interval, that started between MinStartTime and MaxStartTime, and ended later than MinEndTime.
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopScans:10 -MinStartTime:"5/14/2022 7:00:00 AM" -MaxStartTime:"5/14/2022 7:01:11 AM" -MinEndTime:"5/14/2022 7:01:41 AM"

.EXAMPLE
# Find top 10 scans with longest durations, impacting the current interval, that started before MaxStartTime, and ended between MinEndTime and MaxEndTime.
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopScans:10 -MaxStartTime:"5/14/2022 7:01:11 AM" -MinEndTime:"5/14/2022 7:01:41 AM" -MaxEndTime:"5/14/2022 7:02:00 AM"

.EXAMPLE
# Find top 10 scans with longest durations, impacting the current interval, that started between MinStartTime and MaxStartTime, and ended between MinEndTime and MaxEndTime.
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopScans:10 -MinStartTime:"5/14/2022 7:00:00 AM" -MaxStartTime:"5/14/2022 7:01:11 AM" -MinEndTime:"5/14/2022 7:01:41 AM" -MaxEndTime:"5/14/2022 7:02:00 AM"

.EXAMPLE
# Find top 10 scans with longest durations that both start and end between MinStartTime and MaxEndTime, using DateTime as raw numbers in FILETIME format, e.g. from -Raw report format:
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopScans:10 -MinStartTime:([DateTime]::FromFileTime(132969744714304340)) -MaxEndTime:([DateTime]::FromFileTime(132969745000971033))

.EXAMPLE
# Find top 10 scans with longest durations between MinEndTime and MaxStartTime, possibly partially overlapping this period, using DateTime as raw numbers in FILETIME format, e.g. from -Raw report format:
Get-MpPerformanceReport -Path:.\Defender-scans.etl -TopScans:10 -MinEndTime:([DateTime]::FromFileTime(132969744714304340)) -MaxStartTime:([DateTime]::FromFileTime(132969745000971033))

.EXAMPLE
# Display a summary or overview of the scans captured in the trace, in addition to the information displayed regularly through other arguments. Output is influenced by time interval arguments MinStartTime and MaxEndTime.
Get-MpPerformanceReport -Path:.\Defender-scans.etl [other arguments] -Overview

#>

function Get-MpPerformanceReport {
    [CmdletBinding()]
    param(
        # Specifies the location of Microsoft Defender Antivirus performance recording to analyze.
        [Parameter(Mandatory=$true,
                Position=0,
                ValueFromPipeline=$true,
                ValueFromPipelineByPropertyName=$true,
                HelpMessage="Location of Microsoft Defender Antivirus performance recording.")]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        # Requests a top files report and specifies how many top files to output, sorted by "Duration".
        [ValidateRange(0,([int]::MaxValue))]
        [int]$TopFiles = 0,

        # Specifies how many top scans to output for each top file, sorted by "Duration".
        [ValidateRange(0,([int]::MaxValue))]
        [int]$TopScansPerFile = 0,

        # Specifies how many top processes to output for each top file, sorted by "Duration".
        [ValidateRange(0,([int]::MaxValue))]
        [int]$TopProcessesPerFile = 0,

        # Specifies how many top scans to output for each top process for each top file, sorted by "Duration".
        [ValidateRange(0,([int]::MaxValue))]
        [int]$TopScansPerProcessPerFile = 0,

        # Requests a top paths report and specifies how many top entries to output, sorted by "Duration". This is called recursively for each directory entry. Scans are grouped hierarchically per folder and sorted by "Duration".
        [ValidateRange(0,([int]::MaxValue))]
        [int]$TopPaths = 0,

        # Specifies the maxmimum depth (path-wise) that will be used to grop scans when $TopPaths is used.
        [ValidateRange(1,1024)]
        [int]$TopPathsDepth = 0,

        # Specifies how many top scans to output for each top path, sorted by "Duration".
        [ValidateRange(0,([int]::MaxValue))]
        [int]$TopScansPerPath = 0,

        # Specifies how many top files to output for each top path, sorted by "Duration".
        [ValidateRange(0,([int]::MaxValue))]
        [int]$TopFilesPerPath = 0,

        # Specifies how many top scans to output for each top file for each top path, sorted by "Duration".
        [ValidateRange(0,([int]::MaxValue))]
        [int]$TopScansPerFilePerPath = 0,

        # Specifies how many top extensions to output for each top path, sorted by "Duration".
        [ValidateRange(0,([int]::MaxValue))]
        [int]$TopExtensionsPerPath = 0,
    
        # Specifies how many top scans to output for each top extension for each top path, sorted by "Duration".
        [ValidateRange(0,([int]::MaxValue))]
        [int]$TopScansPerExtensionPerPath = 0,

        # Specifies how many top processes to output for each top path, sorted by "Duration".
        [ValidateRange(0,([int]::MaxValue))]
        [int]$TopProcessesPerPath = 0,

        # Specifies how many top scans to output for each top process for each top path, sorted by "Duration".
        [ValidateRange(0,([int]::MaxValue))]
        [int]$TopScansPerProcessPerPath = 0,

        # Requests a top extensions report and specifies how many top extensions to output, sorted by "Duration".
        [ValidateRange(0,([int]::MaxValue))]
        [int]$TopExtensions = 0,

        # Specifies how many top scans to output for each top extension, sorted by "Duration".
        [ValidateRange(0,([int]::MaxValue))]
        [int]$TopScansPerExtension = 0,

        # Specifies how many top paths to output for each top extension, sorted by "Duration".
        [ValidateRange(0,([int]::MaxValue))]
        [int]$TopPathsPerExtension = 0,

        # Specifies how many top scans to output for each top path for each top extension, sorted by "Duration".
        [ValidateRange(0,([int]::MaxValue))]
        [int]$TopScansPerPathPerExtension = 0,

        # Specifies how many top files to output for each top extension, sorted by "Duration".
        [ValidateRange(0,([int]::MaxValue))]
        [int]$TopFilesPerExtension = 0,

        # Specifies how many top scans to output for each top file for each top extension, sorted by "Duration".
        [ValidateRange(0,([int]::MaxValue))]
        [int]$TopScansPerFilePerExtension = 0,

        # Specifies how many top processes to output for each top extension, sorted by "Duration".
        [ValidateRange(0,([int]::MaxValue))]
        [int]$TopProcessesPerExtension = 0,

        # Specifies how many top scans to output for each top process for each top extension, sorted by "Duration".
        [ValidateRange(0,([int]::MaxValue))]
        [int]$TopScansPerProcessPerExtension = 0,

        # Requests a top processes report and specifies how many top processes to output, sorted by "Duration".
        [ValidateRange(0,([int]::MaxValue))]
        [int]$TopProcesses = 0,

        # Specifies how many top scans to output for each top process in the Top Processes report, sorted by "Duration".
        [ValidateRange(0,([int]::MaxValue))]
        [int]$TopScansPerProcess = 0,

        # Specifies how many top files to output for each top process, sorted by "Duration".
        [ValidateRange(0,([int]::MaxValue))]
        [int]$TopFilesPerProcess = 0,

        # Specifies how many top scans to output for each top file for each top process, sorted by "Duration".
        [ValidateRange(0,([int]::MaxValue))]
        [int]$TopScansPerFilePerProcess = 0,

        # Specifies how many top extensions to output for each top process, sorted by "Duration".
        [ValidateRange(0,([int]::MaxValue))]
        [int]$TopExtensionsPerProcess = 0,

        # Specifies how many top scans to output for each top extension for each top process, sorted by "Duration".
        [ValidateRange(0,([int]::MaxValue))]
        [int]$TopScansPerExtensionPerProcess = 0,

        # Specifies how many top paths to output for each top process, sorted by "Duration".
        [ValidateRange(0,([int]::MaxValue))]
        [int]$TopPathsPerProcess = 0,

        # Specifies how many top scans to output for each top path for each top process, sorted by "Duration".
        [ValidateRange(0,([int]::MaxValue))]
        [int]$TopScansPerPathPerProcess = 0,

        # Requests a top scans report and specifies how many top scans to output, sorted by "Duration".
        [ValidateRange(0,([int]::MaxValue))]
        [int]$TopScans = 0,

        ## TimeSpan format: d | h:m | h:m:s | d.h:m | h:m:.f | h:m:s.f | d.h:m:s | d.h:m:.f | d.h:m:s.f => d | (d.)?h:m(:s(.f)?)? | ((d.)?h:m:.f)

        # Specifies the minimum duration of any scans or total scan durations of files, extensions and processes included in the report.
        # Accepts values like  '0.1234567sec' or '0.1234ms' or '0.1us' or a valid TimeSpan.
        [ValidatePattern('^(?:(?:(\d+)(?:\.(\d+))?(sec|ms|us))|(?:\d+)|(?:(\d+\.)?\d+:\d+(?::\d+(?:\.\d+)?)?)|(?:(\d+\.)?\d+:\d+:\.\d+))$')]
        [string]$MinDuration = '0us',

        # Specifies the minimum start time of scans included in the report. Accepts a valid DateTime.
        [DateTime]$MinStartTime = [DateTime]::MinValue,

        # Specifies the minimum end time of scans included in the report. Accepts a valid DateTime.
        [DateTime]$MinEndTime = [DateTime]::MinValue,

        # Specifies the maximum start time of scans included in the report. Accepts a valid DateTime.
        [DateTime]$MaxStartTime = [DateTime]::MaxValue,

        # Specifies the maximum end time of scans included in the report. Accepts a valid DateTime.
        [DateTime]$MaxEndTime = [DateTime]::MaxValue,

        # Adds an overview or summary of the scans captured in the trace to the regular output.
        [switch]$Overview,

        # Specifies that the output should be machine readable and readily convertible to serialization formats like JSON.
        # - Collections and elements are not be formatted.
        # - TimeSpan values are represented as number of 100-nanosecond intervals.
        # - DateTime values are represented as number of 100-nanosecond intervals since January 1, 1601 (UTC).
        [switch]$Raw
    )

    #
    # Validate performance recording presence
    #

    if (-not (Test-Path -Path:$Path -PathType:Leaf)) {
        $ex = New-Object System.Management.Automation.ItemNotFoundException "Cannot find path '$Path'."
        $category = [System.Management.Automation.ErrorCategory]::ObjectNotFound
        $errRecord = New-Object System.Management.Automation.ErrorRecord $ex,'PathNotFound',$category,$Path
        $psCmdlet.WriteError($errRecord)
        return
    }

    function ParameterValidationError {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory)]
            [string]
            $ParameterName,

            [Parameter(Mandatory)]
            [string]
            $ParentParameterName
        )

        $ex = New-Object System.Management.Automation.ValidationMetadataException "Parameter '$ParameterName' requires parameter '$ParentParameterName'."
        $category = [System.Management.Automation.ErrorCategory]::MetadataError
        $errRecord = New-Object System.Management.Automation.ErrorRecord $ex,'InvalidParameter',$category,$ParameterName
        $psCmdlet.WriteError($errRecord)
    }

    #
    # Additional parameter validation
    #

    if ($TopFiles -eq 0)
    {
        if ($TopScansPerFile -gt 0)
        {
            ParameterValidationError -ErrorAction:Stop -ParameterName:'TopScansPerFile' -ParentParameterName:'TopFiles'
        }

        if ($TopProcessesPerFile -gt 0)
        {
            ParameterValidationError -ErrorAction:Stop -ParameterName:'TopProcessesPerFile' -ParentParameterName:'TopFiles'
        }
    }

    if ($TopProcessesPerFile -eq 0)
    {
        if ($TopScansPerProcessPerFile -gt 0)
        {
            ParameterValidationError -ErrorAction:Stop -ParameterName:'TopScansPerProcessPerFile' -ParentParameterName:'TopProcessesPerFile'
        }
    }

    if ($TopPathsDepth -gt 0)
    {
        if (($TopPaths -eq 0) -and ($TopPathsPerProcess -eq 0) -and ($TopPathsPerExtension -eq 0))
        {
            ParameterValidationError -ErrorAction:Stop -ParameterName:'TopPathsDepth' -ParentParameterName:'TopPaths or TopPathsPerProcess or TopPathsPerExtension'
        }
    }

    if ($TopPaths -eq 0) 
    {
        if ($TopScansPerPath -gt 0)
        {
            ParameterValidationError -ErrorAction:Stop -ParameterName:'TopScansPerPath' -ParentParameterName:'TopPaths'
        }

        if ($TopFilesPerPath -gt 0)
        {
            ParameterValidationError -ErrorAction:Stop -ParameterName:'TopFilesPerPath' -ParentParameterName:'TopPaths'
        }

        if ($TopExtensionsPerPath -gt 0)
        {
            ParameterValidationError -ErrorAction:Stop -ParameterName:'TopExtensionsPerPath' -ParentParameterName:'TopPaths'
        }

        if ($TopProcessesPerPath -gt 0)
        {
            ParameterValidationError -ErrorAction:Stop -ParameterName:'TopProcessesPerPath' -ParentParameterName:'TopPaths'
        }
    }

    if ($TopFilesPerPath -eq 0) 
    {
        if ($TopScansPerFilePerPath -gt 0)
        {
            ParameterValidationError -ErrorAction:Stop -ParameterName:'TopScansPerFilePerPath' -ParentParameterName:'TopFilesPerPath'
        }
    }

    if ($TopExtensionsPerPath -eq 0) 
    {
        if ($TopScansPerExtensionPerPath -gt 0)
        {
            ParameterValidationError -ErrorAction:Stop -ParameterName:'TopScansPerExtensionPerPath' -ParentParameterName:'TopExtensionsPerPath'
        }
    }

    if ($TopProcessesPerPath -eq 0) 
    {
        if ($TopScansPerProcessPerPath -gt 0)
        {
            ParameterValidationError -ErrorAction:Stop -ParameterName:'TopScansPerProcessPerPath' -ParentParameterName:'TopProcessesPerPath'
        }
    }

    if ($TopExtensions -eq 0)
    {
        if ($TopScansPerExtension -gt 0)
        {
            ParameterValidationError -ErrorAction:Stop -ParameterName:'TopScansPerExtension' -ParentParameterName:'TopExtensions'
        }

        if ($TopFilesPerExtension -gt 0)
        {
            ParameterValidationError -ErrorAction:Stop -ParameterName:'TopFilesPerExtension' -ParentParameterName:'TopExtensions'
        }

        if ($TopProcessesPerExtension -gt 0)
        {
            ParameterValidationError -ErrorAction:Stop -ParameterName:'TopProcessesPerExtension' -ParentParameterName:'TopExtensions'
        }

        if ($TopPathsPerExtension -gt 0)
        {
            ParameterValidationError -ErrorAction:Stop -ParameterName:'TopPathsPerExtension' -ParentParameterName:'TopExtensions'
        } 
    }

    if ($TopFilesPerExtension -eq 0)
    {
        if ($TopScansPerFilePerExtension -gt 0)
        {
            ParameterValidationError -ErrorAction:Stop -ParameterName:'TopScansPerFilePerExtension' -ParentParameterName:'TopFilesPerExtension'
        }
    }

    if ($TopProcessesPerExtension -eq 0)
    {
        if ($TopScansPerProcessPerExtension -gt 0)
        {
            ParameterValidationError -ErrorAction:Stop -ParameterName:'TopScansPerProcessPerExtension' -ParentParameterName:'TopProcessesPerExtension'
        }
    }

    if ($TopPathsPerExtension -eq 0)
    {
        if ($TopScansPerPathPerExtension -gt 0)
        {
            ParameterValidationError -ErrorAction:Stop -ParameterName:'TopScansPerPathPerExtension' -ParentParameterName:'TopPathsPerExtension'
        }
    }

    if ($TopProcesses -eq 0)
    {
        if ($TopScansPerProcess -gt 0)
        {
            ParameterValidationError -ErrorAction:Stop -ParameterName:'TopScansPerProcess' -ParentParameterName:'TopProcesses'
        }

        if ($TopFilesPerProcess -gt 0)
        {
            ParameterValidationError -ErrorAction:Stop -ParameterName:'TopFilesPerProcess' -ParentParameterName:'TopProcesses'
        }

        if ($TopExtensionsPerProcess -gt 0)
        {
            ParameterValidationError -ErrorAction:Stop -ParameterName:'TopExtensionsPerProcess' -ParentParameterName:'TopProcesses'
        }

        if ($TopPathsPerProcess -gt 0)
        {
            ParameterValidationError -ErrorAction:Stop -ParameterName:'TopPathsPerProcess' -ParentParameterName:'TopProcesses'
        }
    }

    if ($TopFilesPerProcess -eq 0)
    {
        if ($TopScansPerFilePerProcess -gt 0)
        {
            ParameterValidationError -ErrorAction:Stop -ParameterName:'TopScansPerFilePerProcess' -ParentParameterName:'TopFilesPerProcess'
        }
    }

    if ($TopExtensionsPerProcess -eq 0)
    {
        if ($TopScansPerExtensionPerProcess -gt 0)
        {
            ParameterValidationError -ErrorAction:Stop -ParameterName:'TopScansPerExtensionPerProcess' -ParentParameterName:'TopExtensionsPerProcess'
        }
    }

    if ($TopPathsPerProcess -eq 0)
    {
        if ($TopScansPerPathPerProcess -gt 0)
        {
            ParameterValidationError -ErrorAction:Stop -ParameterName:'TopScansPerPathPerProcess' -ParentParameterName:'TopPathsPerProcess'
        }
    }

    if (($TopFiles -eq 0) -and ($TopExtensions -eq 0) -and ($TopProcesses -eq 0) -and ($TopScans -eq 0) -and ($TopPaths -eq 0) -and (-not $Overview)) {
        $ex = New-Object System.Management.Automation.ItemNotFoundException "At least one of the parameters 'TopFiles', 'TopPaths', 'TopExtensions', 'TopProcesses', 'TopScans' or 'Overview' must be present."
        $category = [System.Management.Automation.ErrorCategory]::InvalidArgument
        $errRecord = New-Object System.Management.Automation.ErrorRecord $ex,'InvalidArgument',$category,$wprProfile
        $psCmdlet.WriteError($errRecord)
        return
    }

    # Dependencies
    [string]$PlatformPath = (Get-ItemProperty -Path:'HKLM:\Software\Microsoft\Windows Defender' -Name:'InstallLocation' -ErrorAction:Stop).InstallLocation

    #
    # Test dependency presence
    #
    [string]$mpCmdRunCommand = "${PlatformPath}MpCmdRun.exe"

    if (-not (Get-Command $mpCmdRunCommand -ErrorAction:SilentlyContinue)) {
        $ex = New-Object System.Management.Automation.ItemNotFoundException "Cannot find '$mpCmdRunCommand'."
        $category = [System.Management.Automation.ErrorCategory]::ObjectNotFound
        $errRecord = New-Object System.Management.Automation.ErrorRecord $ex,'PathNotFound',$category,$mpCmdRunCommand
        $psCmdlet.WriteError($errRecord)
        return
    } 

    # assemble report arguments

    [string[]]$reportArguments = @(
        $PSBoundParameters.GetEnumerator() |
            Where-Object { $_.Key.ToString().StartsWith("Top") -and ($_.Value -gt 0) } |
            ForEach-Object { "-$($_.Key)"; "$($_.Value)"; }
        )

    [timespan]$MinDurationTimeSpan = ParseFriendlyDuration -FriendlyDuration:$MinDuration

    if ($MinDurationTimeSpan -gt [TimeSpan]::FromTicks(0))
    {
        $reportArguments += @('-MinDuration', ($MinDurationTimeSpan.Ticks))
    }

    $MaxEndTime   = PadUserDateTime -UserDateTime:$MaxEndTime
    $MaxStartTime = PadUserDateTime -UserDateTime:$MaxStartTime

    $ret = ValidateTimeInterval -MinStartTime:$MinStartTime -MaxEndTime:$MaxEndTime -MaxStartTime:$MaxStartTime -MinEndTime:$MinEndTime
    if ($false -eq $ret.status)
    {
        return
    }

    [string[]]$intervalArguments = $ret.arguments
    if (($null -ne $intervalArguments) -and ($intervalArguments.Length -gt 0))
    {
        $reportArguments += $intervalArguments
    }

    if ($Overview)
    {
        $reportArguments += "-Overview"
    }

    $report = (& $mpCmdRunCommand -PerformanceReport -RecordingPath $Path @reportArguments) | Where-Object { -not [string]::IsNullOrEmpty($_) } | ConvertFrom-Json

    $result = [PSCustomObject]@{}

    if (-not $Raw) {
        $result.PSTypeNames.Insert(0, 'MpPerformanceReport.Result')
    }

    if ($TopFiles -gt 0)
    {
        $reportTopFiles = @(if ($null -ne $report.TopFiles) { @($report.TopFiles | ConvertTo-DefenderScannedFilePathStats -Raw:$Raw) } else { @() })
        $result | Add-Member -NotePropertyName:'TopFiles' -NotePropertyValue:$reportTopFiles

        if (-not $Raw) {
            Add-DefenderCollectionType -CollectionRef:([ref]$result.TopFiles)
        }
    }

    if ($TopPaths -gt 0)
    {
        $reportTopPaths = @(if ($null -ne $report.TopPaths) { @($report.TopPaths | ConvertTo-DefenderScannedPathsStats -Raw:$Raw) } else { @() })
        $result | Add-Member -NotePropertyName:'TopPaths' -NotePropertyValue:$reportTopPaths
    
        if (-not $Raw) {
            Add-DefenderCollectionType -CollectionRef:([ref]$result.TopPaths)
        }
    }

    if ($TopExtensions -gt 0)
    {
        $reportTopExtensions = @(if ($null -ne $report.TopExtensions) { @($report.TopExtensions | ConvertTo-DefenderScannedFileExtensionStats -Raw:$Raw) } else { @() })
        $result | Add-Member -NotePropertyName:'TopExtensions' -NotePropertyValue:$reportTopExtensions

        if (-not $Raw) {
            Add-DefenderCollectionType -CollectionRef:([ref]$result.TopExtensions)
        }
    }

    if ($TopProcesses -gt 0)
    {
        $reportTopProcesses = @(if ($null -ne $report.TopProcesses) { @($report.TopProcesses | ConvertTo-DefenderScannedProcessStats -Raw:$Raw) } else { @() })
        $result | Add-Member -NotePropertyName:'TopProcesses' -NotePropertyValue:$reportTopProcesses

        if (-not $Raw) {
            Add-DefenderCollectionType -CollectionRef:([ref]$result.TopProcesses)
        }
    }

    if ($TopScans -gt 0)
    {
        $reportTopScans = @(if ($null -ne $report.TopScans) { @($report.TopScans | ConvertTo-DefenderScanInfo -Raw:$Raw) } else { @() })
        $result | Add-Member -NotePropertyName:'TopScans' -NotePropertyValue:$reportTopScans

        if (-not $Raw) {
            Add-DefenderCollectionType -CollectionRef:([ref]$result.TopScans)
        }
    }

    if ($Overview)
    {
        if ($null -ne $report.Overview) {
            $reportOverview = $report.Overview | ConvertTo-DefenderScanOverview -Raw:$Raw
            $result | Add-Member -NotePropertyName:'Overview' -NotePropertyValue:$reportOverview

            if (-not $Raw) {
                $result.Overview.PSTypeNames.Insert(0, 'MpPerformanceReport.Overview')
            }
        }
    }

    $result
}

$exportModuleMemberParam = @{
    Function = @(
        'New-MpPerformanceRecording'
        'Get-MpPerformanceReport'
        )
}

Export-ModuleMember @exportModuleMemberParam

# SIG # Begin signature block
# MIIlsAYJKoZIhvcNAQcCoIIloTCCJZ0CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCABOtUhuRLDSJsH
# 5LjfiBWymKYbjYNumRKF78V/LI3Gd6CCCtkwggT6MIID4qADAgECAhMzAAAFGdrd
# qovcRLKSAAAAAAUZMA0GCSqGSIb3DQEBCwUAMIGEMQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMS4wLAYDVQQDEyVNaWNyb3NvZnQgV2luZG93cyBQ
# cm9kdWN0aW9uIFBDQSAyMDExMB4XDTI1MDYxOTE4MTE0NFoXDTI2MDYxNzE4MTE0
# NFowcDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEaMBgGA1UE
# AxMRTWljcm9zb2Z0IFdpbmRvd3MwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEK
# AoIBAQCZDMq7dDmGKUNA27gASKX04wCVoYWGXif+YkSjXbDCGjDYwgMNz8tke7Sa
# EFHAw+RsHFLu0kuXJPlCUi+NrU6FC1mzGr0CwtDCanbiuS0YRSh0jk46E0yifLgl
# UOM8wlO7u46aBHateelW3IeGVotvGYd0kC61ThrUmkNo5spbbdf2gFPHocVhLmyP
# TbknaEcWdlDg6GiTTLh9atBO4AgAMwYn2C7gnSvjqbFD3o5jxMqt2FzoT98fEW76
# H7b2r2j1p3xnb1YfF2MdT4Y6JJ2WsypuyzFIOjJKb1Sy2/oTYIhZOCHL96Sn2j1r
# wsjJOTiIYjULVNT348tItL5I2IQFAgMBAAGjggF2MIIBcjAfBgNVHSUEGDAWBgor
# BgEEAYI3CgMGBggrBgEFBQcDAzAdBgNVHQ4EFgQUFeA5BFr8G6fQq5LRBOaHXjkh
# u80wRQYDVR0RBD4wPKQ6MDgxHjAcBgNVBAsTFU1pY3Jvc29mdCBDb3Jwb3JhdGlv
# bjEWMBQGA1UEBRMNMjI5ODc5KzUwNTMyNjAfBgNVHSMEGDAWgBSpKQI5jhbEl3jN
# kPmeT5rhfFWvUzBXBgNVHR8EUDBOMEygSqBIhkZodHRwOi8vd3d3Lm1pY3Jvc29m
# dC5jb20vcGtpb3BzL2NybC9NaWNXaW5Qcm9QQ0EyMDExXzIwMTEtMTAtMTkuY3Js
# JTIwMGEGCCsGAQUFBwEBBFUwUzBRBggrBgEFBQcwAoZFaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNXaW5Qcm9QQ0EyMDExXzIwMTEtMTAt
# MTkuY3J0MAwGA1UdEwEB/wQCMAAwDQYJKoZIhvcNAQELBQADggEBAJdoeu54uGlY
# x7NxqBMJABhMXaVJWeLoHLOzWHGm0lD+5w+SSQGlCmdWfnEUX+JSNQfp2bN/zik7
# sgmh4yOCIG8uSp1A0ySh1xobM2+JOAMPTm5NZZZiyo0J3cQgQMDMBPbLQlYARkx0
# m4Ax9gbd2E0zyTRFr3CkYiqqpnEJsrddEOGQE0Zlxw6dXfF9xuNuswFzYrvqmRdI
# BCwLesitK+Rp+JQDnitRIpFWlHR9oLXbPxATwqWH/oLJcmwV6J7gE17V8r5OqAxN
# EJwEJnNj68kdHG6pYKLUk81siK31OULzVfxLxsHpH97xF8QX7gKNcz+PfqiD5vL1
# FAFzznp3K2EwggXXMIIDv6ADAgECAgphB3ZWAAAAAAAIMA0GCSqGSIb3DQEBCwUA
# MIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQD
# EylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAxMDAeFw0x
# MTEwMTkxODQxNDJaFw0yNjEwMTkxODUxNDJaMIGEMQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMS4wLAYDVQQDEyVNaWNyb3NvZnQgV2luZG93cyBQ
# cm9kdWN0aW9uIFBDQSAyMDExMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKC
# AQEA3Qy7ouQuCePnxfeWabwAIb1pMzPvrQTLVIDuBoO7xSCE2ffSi/M4sKukrS18
# YnkF/+NKPwQ1IHDjxOdr4JzANnXpijHdjXDl3De1dEaWKFuHYCMsv9xHpWf3USee
# cusHpsm5HjtTNXzl0+wnuYcc/rnJIwlvqEaRwW6WPEHTy6M/XQJqTexpHyUoXDb/
# /UMVCpTgGbTP38IS4sJbJ+4neDCLWyoJayKJU2AWLMBoHVO67EnznWGMhWgJc0Rd
# faJUK9159xXPNV1sHCtczrycI4tvbrUm2TYTw0/WJ665MjtBkizhx8136KpUTvdc
# CwSHZbRDGKiy4G0Zd+xaJPpIAwIDAQABo4IBQzCCAT8wEAYJKwYBBAGCNxUBBAMC
# AQAwHQYDVR0OBBYEFKkpAjmOFsSXeM2Q+Z5PmuF8Va9TMBkGCSsGAQQBgjcUAgQM
# HgoAUwB1AGIAQwBBMAsGA1UdDwQEAwIBhjAPBgNVHRMBAf8EBTADAQH/MB8GA1Ud
# IwQYMBaAFNX2VsuP6KJcYmjRPZSQW9fOmhjEMFYGA1UdHwRPME0wS6BJoEeGRWh0
# dHA6Ly9jcmwubWljcm9zb2Z0LmNvbS9wa2kvY3JsL3Byb2R1Y3RzL01pY1Jvb0Nl
# ckF1dF8yMDEwLTA2LTIzLmNybDBaBggrBgEFBQcBAQROMEwwSgYIKwYBBQUHMAKG
# Pmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljUm9vQ2VyQXV0
# XzIwMTAtMDYtMjMuY3J0MA0GCSqGSIb3DQEBCwUAA4ICAQAU/HxxUaV5wm6y7zk+
# vDxSD24rPxATc/6oaNBIpjRNipYFJu4xRpBhedb/OC5Fa/TA5Si42h2PitsJ1xrH
# TAo2ZmqM7BvXBJCoGBekm7niQDI2dsTBWsa/5ATA6hbTrMNo72Ks3VRsUDBYput8
# /pSnTo707HyGc1fCUiFzNFrzo4pWyATaBwnt+IvjzvR+jq7w9guKCPs/yR1yf1O4
# 675j4OM9MWWwgeXyrM0WpJ89qLGbwkLQkIRfVB3/ieq6HUeQb7BzTkGfQJ9f5aEq
# shGRc4ohKPDO3nM5Xz6rXGDs3wMQqNMJ6fT2loW2f1GIZkcZjaKwEj2BKmgFd7uR
# TGJ7tsEHx7p6hzQDDktiepnpyvzOSjfJLaRXfBz+Pdy4D1r61sSzAoUCOuqz2W7k
# aSE33oHR9nUZBWfTk1deKRs5yO4t4c3kRXNb0NLOeqsWGYJGWNBenYGzZ69sNfK8
# 5T8k4jWiCnUG9hhWmdR4LNEFG+vQiAGdqhDxBd+6fixjtwabIyHE+Xhs4lgXBjYr
# kRIDzKTZ8i26+ZSdQO0YRfHOilxrPqsD03AYKgpq4F9H0dVjCjLyr9c2HypwWuVC
# WQhxS1e6foOB8CE89BzBxbmQkw6IRZOG6bEgmb6Yy8WVpF1i1qBjCCC9dRB3fT3z
# Rbmfl5/LV4BvM6kEz3ekYhxZfjGCGi0wghopAgEBMIGcMIGEMQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMS4wLAYDVQQDEyVNaWNyb3NvZnQgV2lu
# ZG93cyBQcm9kdWN0aW9uIFBDQSAyMDExAhMzAAAFGdrdqovcRLKSAAAAAAUZMA0G
# CWCGSAFlAwQCAQUAoIGuMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisG
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCD9Z0cnXmiP
# tYiRDB4I4P5b8xKpMUzPtFYM9X1PsGF6OjBCBgorBgEEAYI3AgEMMTQwMqAUgBIA
# TQBpAGMAcgBvAHMAbwBmAHShGoAYaHR0cDovL3d3dy5taWNyb3NvZnQuY29tMA0G
# CSqGSIb3DQEBAQUABIIBACMc87Nw774HblGRwVV5b7taQK40TtrbknC95wuCaMMs
# NI4y/UyHMxSztJ9cQ+Xrf2QI+wMutQ9pboCDGWWxHb3P51XtCGq9cBp0MlLKbjlc
# YbJ8Kxjvm84JE92oMIOoJEYTRxIdcj/vFkR3jny3uuVB/iYyrMCdCUrHZR1fnW61
# QKJWxlpqO4HjIjLfFNLNZ35frNkvDf4dGqAAsG9CamG5upcw12/GjvJSM7TcLcgx
# BQWDhEp7DYN0VPyiiIfPkfUtbg+IwJm9y5FC7mdhjHQQAX1n0f+YUynkgNoeKSmY
# iYh3Zi4CIcWWW0AJnMqlQztAKrArjfUXSK2SxD2FLAahghewMIIXrAYKKwYBBAGC
# NwMDATGCF5wwgheYBgkqhkiG9w0BBwKggheJMIIXhQIBAzEPMA0GCWCGSAFlAwQC
# AQUAMIIBWgYLKoZIhvcNAQkQAQSgggFJBIIBRTCCAUECAQEGCisGAQQBhFkKAwEw
# MTANBglghkgBZQMEAgEFAAQgpLWy/XS4f/FU7wi87zOl3U9zYsJ/SG1QYexJSrzS
# PB8CBmiki3K7YBgTMjAyNTA4MjMwOTI4MTEuMzk4WjAEgAIB9KCB2aSB1jCB0zEL
# MAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1v
# bmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEtMCsGA1UECxMkTWlj
# cm9zb2Z0IElyZWxhbmQgT3BlcmF0aW9ucyBMaW1pdGVkMScwJQYDVQQLEx5uU2hp
# ZWxkIFRTUyBFU046NTcxQS0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBU
# aW1lLVN0YW1wIFNlcnZpY2WgghH+MIIHKDCCBRCgAwIBAgITMwAAAfvLy2w3Z+Uw
# lQABAAAB+zANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0Eg
# MjAxMDAeFw0yNDA3MjUxODMxMTNaFw0yNTEwMjIxODMxMTNaMIHTMQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQg
# SXJlbGFuZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNT
# IEVTTjo1NzFBLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3Rh
# bXAgU2VydmljZTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAKjCVkHl
# gKuC8L0o2LIz9FL4b5tI9GgDiYjC4NLC38SqE1wHSg+qDLquaxeaBIjsVfvaMdB/
# eUPH4aGat8fZcYLmckziuJdsbXILSQrY10ZZTNm06YzoN+UVKwctHAJaAVPRiQbO
# ywTa3Gx+qwYjr6g0DYnD0WcKtescozInVNSdQCbmrfci5+7Won6A+fG5WBHAb5I+
# XR9ZWvc1POOkA3jqETujXKhy7A8fP81SmcT99JlumO0TLKrQfHBgoBsFVbqzp2jS
# 17N9ak0U8lR1/KaTnaEooQl3qnm4CQkcxvMxv3v5NKGgYxRRpfvLhRC8AsoeMCvW
# efms0832thg+KeoobbJF7N5Z1tOVCnwyYQAA7er4jnNEZP3PMzoqs4dJSqX/3llG
# NqP4b3Az2TYC2h78nw6m/AFmirzt+okWUl6oUsPEsSaNEwqbGwo5rcdC6R56m29V
# Be3KtPZAnH1kwz3DddqW2C6nJNGyCHzym3Ox565DUJLP5km1WU5w8k9zvMxfauAw
# n1nrEq9WpMnA3bhsQnSgb4LSYdWMQ6tbJE8HmMeYgFl5weyjMpbN1kGW07m0wiy7
# fF5/LfrJXCpuQ5L6G7m5h0q4rkwN8E8iMuBcWpkyptFQ7vZlnbPDLY1EiVcDVVZQ
# V2kN2THFY4o8laFDVbgWPTHMGHCECutsENtBAgMBAAGjggFJMIIBRTAdBgNVHQ4E
# FgQUR1UhmFDUN0cDpe9cyALlIyCoNSowHwYDVR0jBBgwFoAUn6cVXQBeYl2D9OXS
# ZacbUzUZ6XIwXwYDVR0fBFgwVjBUoFKgUIZOaHR0cDovL3d3dy5taWNyb3NvZnQu
# Y29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIw
# MTAoMSkuY3JsMGwGCCsGAQUFBwEBBGAwXjBcBggrBgEFBQcwAoZQaHR0cDovL3d3
# dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBUaW1lLVN0
# YW1wJTIwUENBJTIwMjAxMCgxKS5jcnQwDAYDVR0TAQH/BAIwADAWBgNVHSUBAf8E
# DDAKBggrBgEFBQcDCDAOBgNVHQ8BAf8EBAMCB4AwDQYJKoZIhvcNAQELBQADggIB
# AMM6CCjmNnZ1I31rjIhqM/6L6HNXvOlcFmmTRXYEZjqELkXuJy3bWTjbUxzZN0o9
# 55MgbM88Um2RENA3bsihxyOT/FfO4xbbRp5UdMDz9thQHm27wG7rZDDFUDBc4VQV
# olg9FQJ7vcdH44nyygwFVy8KLp+awhasG2rFxXOx/9Az4gvgwZ97VMXn73MVAsrO
# Pgwt7PAmKe1ll6WfFm/73QYQ5Yh5ge6VnJrAfN7nOPz9hpgCNxzJDhLu3wmkmKEI
# aLljq9O5fyjOE53cpSIq5vH9lsF0HBRM5lLyEjOpbnVMBpVTX00yVKtm0wxHd7ZQ
# yrVfQFGN665xcB08Ca8i7U+CBYb4AXzQ95i9XnkmpCn+8UyCOCcrdeUl4R3eaCP1
# xo0oMpICa1gOe6xpwAu67t/2WxTQjCvyY+l/F+C+pgTmGtjRisB+AN+2Bg63nCf6
# l11lGL3y2Khxn/E4WJddmINa8EiqVi6JQPwdXqgcOE0XL1WNCLzTYubJvv/xyfQM
# OjSbkf7g0e1+7w14nKVzJUTYBTMgA2/ABSL0D3R6nEaUaK2PmFBpb83icf9oDWMn
# swKJG6xYQArCdgX8ni8ghKOgLsBB5+ddTyhPHSuCb5Zi0qB4+1RUdzRw5N80ZMdB
# MZJhfGjnab6CobsAQsaGfyYW80s672e+BlYyiiMreRQNMIIHcTCCBVmgAwIBAgIT
# MwAAABXF52ueAptJmQAAAAAAFTANBgkqhkiG9w0BAQsFADCBiDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFJv
# b3QgQ2VydGlmaWNhdGUgQXV0aG9yaXR5IDIwMTAwHhcNMjEwOTMwMTgyMjI1WhcN
# MzAwOTMwMTgzMjI1WjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDCCAiIw
# DQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAOThpkzntHIhC3miy9ckeb0O1YLT
# /e6cBwfSqWxOdcjKNVf2AX9sSuDivbk+F2Az/1xPx2b3lVNxWuJ+Slr+uDZnhUYj
# DLWNE893MsAQGOhgfWpSg0S3po5GawcU88V29YZQ3MFEyHFcUTE3oAo4bo3t1w/Y
# JlN8OWECesSq/XJprx2rrPY2vjUmZNqYO7oaezOtgFt+jBAcnVL+tuhiJdxqD89d
# 9P6OU8/W7IVWTe/dvI2k45GPsjksUZzpcGkNyjYtcI4xyDUoveO0hyTD4MmPfrVU
# j9z6BVWYbWg7mka97aSueik3rMvrg0XnRm7KMtXAhjBcTyziYrLNueKNiOSWrAFK
# u75xqRdbZ2De+JKRHh09/SDPc31BmkZ1zcRfNN0Sidb9pSB9fvzZnkXftnIv231f
# gLrbqn427DZM9ituqBJR6L8FA6PRc6ZNN3SUHDSCD/AQ8rdHGO2n6Jl8P0zbr17C
# 89XYcz1DTsEzOUyOArxCaC4Q6oRRRuLRvWoYWmEBc8pnol7XKHYC4jMYctenIPDC
# +hIK12NvDMk2ZItboKaDIV1fMHSRlJTYuVD5C4lh8zYGNRiER9vcG9H9stQcxWv2
# XFJRXRLbJbqvUAV6bMURHXLvjflSxIUXk8A8FdsaN8cIFRg/eKtFtvUeh17aj54W
# cmnGrnu3tz5q4i6tAgMBAAGjggHdMIIB2TASBgkrBgEEAYI3FQEEBQIDAQABMCMG
# CSsGAQQBgjcVAgQWBBQqp1L+ZMSavoKRPEY1Kc8Q/y8E7jAdBgNVHQ4EFgQUn6cV
# XQBeYl2D9OXSZacbUzUZ6XIwXAYDVR0gBFUwUzBRBgwrBgEEAYI3TIN9AQEwQTA/
# BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2Nz
# L1JlcG9zaXRvcnkuaHRtMBMGA1UdJQQMMAoGCCsGAQUFBwMIMBkGCSsGAQQBgjcU
# AgQMHgoAUwB1AGIAQwBBMAsGA1UdDwQEAwIBhjAPBgNVHRMBAf8EBTADAQH/MB8G
# A1UdIwQYMBaAFNX2VsuP6KJcYmjRPZSQW9fOmhjEMFYGA1UdHwRPME0wS6BJoEeG
# RWh0dHA6Ly9jcmwubWljcm9zb2Z0LmNvbS9wa2kvY3JsL3Byb2R1Y3RzL01pY1Jv
# b0NlckF1dF8yMDEwLTA2LTIzLmNybDBaBggrBgEFBQcBAQROMEwwSgYIKwYBBQUH
# MAKGPmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljUm9vQ2Vy
# QXV0XzIwMTAtMDYtMjMuY3J0MA0GCSqGSIb3DQEBCwUAA4ICAQCdVX38Kq3hLB9n
# ATEkW+Geckv8qW/qXBS2Pk5HZHixBpOXPTEztTnXwnE2P9pkbHzQdTltuw8x5MKP
# +2zRoZQYIu7pZmc6U03dmLq2HnjYNi6cqYJWAAOwBb6J6Gngugnue99qb74py27Y
# P0h1AdkY3m2CDPVtI1TkeFN1JFe53Z/zjj3G82jfZfakVqr3lbYoVSfQJL1AoL8Z
# thISEV09J+BAljis9/kpicO8F7BUhUKz/AyeixmJ5/ALaoHCgRlCGVJ1ijbCHcNh
# cy4sa3tuPywJeBTpkbKpW99Jo3QMvOyRgNI95ko+ZjtPu4b6MhrZlvSP9pEB9s7G
# dP32THJvEKt1MMU0sHrYUP4KWN1APMdUbZ1jdEgssU5HLcEUBHG/ZPkkvnNtyo4J
# vbMBV0lUZNlz138eW0QBjloZkWsNn6Qo3GcZKCS6OEuabvshVGtqRRFHqfG3rsjo
# iV5PndLQTHa1V1QJsWkBRH58oWFsc/4Ku+xBZj1p/cvBQUl+fpO+y/g75LcVv7TO
# PqUxUYS8vwLBgqJ7Fx0ViY1w/ue10CgaiQuPNtq6TPmb/wrpNPgkNWcr4A245oyZ
# 1uEi6vAnQj0llOZ0dFtq0Z4+7X6gMTN9vMvpe784cETRkPHIqzqKOghif9lwY1NN
# je6CbaUFEMFxBmoQtB1VM1izoXBm8qGCA1kwggJBAgEBMIIBAaGB2aSB1jCB0zEL
# MAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1v
# bmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEtMCsGA1UECxMkTWlj
# cm9zb2Z0IElyZWxhbmQgT3BlcmF0aW9ucyBMaW1pdGVkMScwJQYDVQQLEx5uU2hp
# ZWxkIFRTUyBFU046NTcxQS0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBU
# aW1lLVN0YW1wIFNlcnZpY2WiIwoBATAHBgUrDgMCGgMVAARx5+zQhrrGc9kX1W8r
# sGMD8pAVoIGDMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0
# b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwDQYJ
# KoZIhvcNAQELBQACBQDsU6bRMCIYDzIwMjUwODIzMDIzMjQ5WhgPMjAyNTA4MjQw
# MjMyNDlaMHcwPQYKKwYBBAGEWQoEATEvMC0wCgIFAOxTptECAQAwCgIBAAICMFYC
# Af8wBwIBAAICEnEwCgIFAOxU+FECAQAwNgYKKwYBBAGEWQoEAjEoMCYwDAYKKwYB
# BAGEWQoDAqAKMAgCAQACAwehIKEKMAgCAQACAwGGoDANBgkqhkiG9w0BAQsFAAOC
# AQEAT2Dn+UWqZ+suodvMx3XTx9/iG/12/BVNNwsGa3q65ENr9+1h9w+o961dRN6q
# ZwF9A7JCzlpIngw7DwC9+XmHmwKUgXgTCaRXWKbuCF1RKWCbRljqLpneXBbFuqw3
# JQBe2Hq7lgNU3fFRLVBgjTyEpEN3JAA+ytfT6CAg1nIWVXKkV7hOOTVZXqkJSR3h
# tL6ebv/AtxiiFMsbay2ah7W0BoNuqCHGfs4XVBcROrsnQ/qrm14kGaKU2KUlrPVO
# ajAKChHD/4jjgcT+Ddz8C9aYnoNghoWa4HiA86nt7wril95vMHz0SJ7uVjLT9wYv
# M7fBFQr0rXxqksUUdFcUpOQsnzGCBA0wggQJAgEBMIGTMHwxCzAJBgNVBAYTAlVT
# MRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFBDQSAyMDEwAhMzAAAB+8vLbDdn5TCVAAEAAAH7MA0GCWCGSAFlAwQC
# AQUAoIIBSjAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQwLwYJKoZIhvcNAQkE
# MSIEICWG0v68MjCZUh0LAFCen1VhrOYyC02NHC9Xd601i2BsMIH6BgsqhkiG9w0B
# CRACLzGB6jCB5zCB5DCBvQQgOdsCq/yghZVTWIlrAi7AeKoYxGBD98R6mKg7tUkk
# 5RgwgZgwgYCkfjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAfvL
# y2w3Z+UwlQABAAAB+zAiBCCsk3NhmSCNiXWyKP55+JUpguvhRuQVRwm8Ysz7+kvh
# 7DANBgkqhkiG9w0BAQsFAASCAgAgqh2RRa6UJf8h/YbzDSVRC13PKyjlcrn8eyeZ
# OdAToOW+LGrk+3Sl3YwGL51yBGSRx2tmSvjdw+iQjL2DW56xPR4z3z1jCWLV81oF
# hg6iCyC3o1YuqJCa+C+JMfte93WiYfrd6SDVHNaaZow/T73k6KVmbO9DcpyuG+9R
# hpS8exHMplNWUrWmPuqu83qYRY0zv1XPPVX8tkfyKsdiiDDNt5cLjbG4m7d1LfmP
# Lcc/SiU6Gu9ZGeQSshFU7r2JwkxVSjFmjgr8rcJBEtp15VvcHgA8EoW3U7OSAwQY
# 7rpgmkZRdfDyYZd1oA2BooHDSNRJPUHqmHD0dblPwNlJToPX+A0pN8bqNfaDxSy1
# 9APH66Y+QNJoVNwVhvKHP27dM/IZOHXGz47sn6Kyko9RysiGSkN8ys48XQYv/je1
# 1L5mqirtOFCDlUxWLJh7f/+mCLIShyIOGsgPe8mhAIOm5f6/9496K+1dINdteE6q
# kLSzUpNiRQExB6MJWkgmJholAQUGjHFV1VNlJE6lRL8kE/afhxqc2rtLZZpWS+v3
# QT0vuFjeatv++9PCS8mibvqwiC7L+D1UbuWQHg7rZZB1KZbobK01wqjxBtaVDgRG
# YpFAS86Ec82E7nDsNEs39qSd2IYI8XWWnpyQk+GtMraq/DwR9J9edDQII5ogGA5c
# pvfb3w==
# SIG # End signature block
