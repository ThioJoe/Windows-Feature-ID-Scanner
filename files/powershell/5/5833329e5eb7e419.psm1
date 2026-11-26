#
# Copyright (c) Microsoft Corporation.  All rights reserved.
#
# Version: 1.0.0.0
# Revision 2015.05.26
#

# --------------------------------------------------------------------------------------------------------------------------
# CONSTANTS
# --------------------------------------------------------------------------------------------------------------------------
$TIMESTAMP_FORMAT = "yyyy/MM/dd HH:mm:ss.fffffff"

$WORKDIR = "$env:TEMP\WindowsUpdateLog"

# TraceRpt.exe fails with "data area passed in too small" error which is really just insufficient buffer error. It happens
# when the total size of ETLs we're passing in is too huge. We're going to batch it every 10 ETLs to workaround the issue.
$MAX_ETL_PER_BATCH = 10

# Column headers in CSV produced by tracerpt.exe
$CSV_HEADER= "EventName, Type, Event ID, Version, Channel, Level, Opcode, Task, Keyword, PID, TID, ProcessorNumber, InstanceID, ParentInstanceID, ActivityID, RelatedActivityID,  ClockTime, KernelTime, UserTime, UserData, Function, LogMessage, Ignore1, Ignore2, IgnoreGuid1, SourceLine, IgnoreTime, Ignore3, Category, LogLevel, TimeStamp, IgnoreGuid2"

# --------------------------------------------------------------------------------------------------------------------------
# FUNCTIONS
# --------------------------------------------------------------------------------------------------------------------------

#
# WU logs get written sequentially in chronological order and has one provider "WUTraceLogging" for the purpose of this cmdlet.
# Thus, the logs don't have to be sorted as a whole as in the case of multiple providers writing to files in an interleaved manner.
#
function CheckSingleWUProvider
{
    Param(
        [string[]] $ProviderFilter = $(throw "'ProviderFilter' parameter is required.")
    )

    if ($ProviderFilter.count -eq 1 -And $ProviderFilter[0] -eq "WUTraceLogging")
    {
        return $true
    }
    return $false
}

#
# Given a path to single ETL file or a directory containing multiple ETL files, return a list containing the fullpaths of the ETLs.
#
function GetListOfETLs
{
    Param(
        [string[]] $Paths = $(throw "'Paths' parameter is required."),
        [string[]] $ETLFileNameFilter = $(throw "'ETLFileNameFilter' parameter is required."),
        [string[]] $ProviderFilter = $(throw "'ProviderFilter' parameter is required.")
    )

    Write-Verbose "Gathering ETL files from $Paths..."

    $etlList = New-Object Collections.Generic.List[string]

    foreach ($path in $Paths)
    {
        # If user passes in a directory as $ETLPath, grabs all the ETLs in that folder.
        if (Test-Path $path -PathType Container)
        {
            $etls = Get-ChildItem $path -Recurse -Include $ETLFileNameFilter

            if ($etls.Length -eq 0)
            {
                Write-Warning "No ETL file in $path with name starting with any of the following filters: $ETLFileNameFilter"
            }

            foreach ($etl in $etls)
            {
                $etlList.Add($etl.FullName.Trim())
            }
        }
        else
        {
            if (!(Test-Path $path) -Or ($ETLFileNameFilter | %{$path -match $_}) -notcontains $true)
            {
                throw "ETL File not found: $path"
            }

            $etlList.Add($path.Trim())
        }
    }

    #
    # WU ETLs need to be sorted numerically as they are named with datetime format and can be assumed to be chronological
    # as they have just a single provider
    #
    if ((CheckSingleWUProvider -ProviderFilter $ProviderFilter) -And $etlList.Count -gt 1)
    {
        Write-Verbose "Sorting WU ETLs numerically ..."

        # Pad the last decimal before .etl in WindowsUpdate.20150609.225042.704.1.etl so ETLs can be sorted numerically.
        $etlList = $etlList | Sort-Object { [regex]::Replace($_, '\d+(?=.etl)', { $args[0].Value.PadLeft(10) }) }
    }

    if ($etlList.count -eq 0)
    {
        throw "File not found: No ETL file found in $Paths with name starting with any of the following filters: $ETLFileNameFilter"
    }

    Write-Verbose "Found $($etlList.Count) ETLs."

    return $etlList
}

#
# The ScriptBlock for decoding ETL files to XML or CSV files and then converting those XML or CSV files To Log files.
#
$ScriptBlock_DecodeETL =
{
    param(
        [Collections.Generic.List[string]] $ETLList = $(throw "'ETLList' parameter is required."),
        [int] $StartIndex = $(throw "'StartIndex' parameter is required."),
        [int] $Length = $(throw "'Length' parameter is required."),
        [string] $OutPath = $(throw "'OutPath' parameter is required."),
        [string] $LogPath = $(throw "'LogPath' parameter is required."),
        [string] $DebugPath = $(throw "'DebugPath' parameter is required."),
        [ValidateSet('XML', 'CSV')] $Type = $(throw "'Type' parameter is required."),
        [string[]] $ProviderFilter = $(throw "'ProviderFilter' parameter is required."),
        [boolean] $IsProviderWUTraceLogging = $(throw "'IsProviderWUTraceLogging' parameter is required.")
    )

    # Access variables defined in the outer scope while running this script block via Start-Job
    $VerbosePreference = $using:VerbosePreference

    $TIMESTAMP_FORMAT = $using:TIMESTAMP_FORMAT
    $CSV_HEADER= $using:CSV_HEADER

    #
    # Given a list of ETLs, decode them into XML or CSV file using TraceRpt.exe
    #
    function DecodeETL
    {
        Param(
            [Collections.Generic.List[string]] $ETLList = $(throw "'ETLList' parameter is required."),
            [string] $OutPath = $(throw "'OutPath' parameter is required."),
            [ValidateSet('XML', 'CSV')] $Type = $(throw "'Type' parameter is required.")
        )

        Write-Verbose "Decoding $($ETLList.Count) ETLs to $OutPath using $Type processing ..."

        if (Test-Path $OutPath)
        {
            Remove-Item $OutPath -Force -ErrorAction Stop
        }

        #
        # Build tracerpt arguments.
        #
        $arguments = New-Object Collections.Generic.List[string]

        # ETL files
        $arguments.AddRange($ETLList)

        # output format
        $arguments.Add("-of")
        $arguments.Add($Type)

        # output file
        $arguments.Add("-o")
        $arguments.Add($OutPath)

        # no prompt
        $arguments.Add("-y")

        #
        # Decode ETLs to XML
        #
        $start = Get-Date

        & "tracerpt.exe" $arguments

        Write-Verbose "Done. Elapsed: $((Get-Date).Subtract($start).TotalMilliseconds) ms."

        if ($LastExitCode -ne 0)
        {
            throw "Failed to decode ETLs. TraceRpt.exe returned error= $LastExitCode"
        }

        if (!(Test-Path $OutPath))
        {
            throw "Failed to decode ETLs. TraceRpt.exe failed to produce $OutPath"
        }
    }

    #
    # Given an XML file produced by tracerpt.exe, convert it to user friendly text log.
    #
    function ConvertXmlToLog
    {
        Param(
            [string] $XmlPath = $(throw "'XmlPath' parameter is required."),
            [string] $LogPath = $(throw "'LogPath' parameter is required.")
        )

        Write-Verbose "Converting $XmlPath to $LogPath ..."

        if (Test-Path $LogPath)
        {
            Remove-Item $LogPath -Force -ErrorAction Stop
        }

        [xml] $xml = Get-Content $XmlPath

        $writer = New-Object IO.StreamWriter $LogPath
        $start = Get-Date

        try
        {
            $nodeNum = 0

            $xml.Events.Event | ForEach-Object {

                $row = $_

                try
                {
                    $systemNode = $_.System
                    $providerNode = $systemNode.Provider
                    $providerName = $systemNode.Provider.Name

                    if ($providerNode -ne $null -And $providerName -eq "WUTraceLogging")
                    {
                        $eventDataNode = $_.EventData
                        $executionNode = $systemNode.Execution
                        [DateTime] $datetime = $systemNode.TimeCreated.SystemTime

                        $keywordNode = $_.RenderingInfo


                        # Log columns:
                        # Time ProcessID ThreadID Component Message
                        $writer.WriteLine("$($datetime.ToString($TIMESTAMP_FORMAT)) $($executionNode.ProcessID.ToString().PadRight(5)) $($executionNode.ThreadID.ToString().PadRight(5)) $($keywordNode.Task.ToString().PadRight(15)) $($eventDataNode.Data.'#text')")
                    }
                }
                catch
                {
                    # Log exception, eat it, and process the rest of the log.
                    Write-Warning "Unable to process node $nodeNum."

                    "Failed to process line:$nodeNum of $XmlPath`n$row`n$_`n---" | Out-File $DebugPath -Encoding UTF8 -Append
                }

                $nodeNum++
            } # foreach
        }
        finally
        {
            $writer.Close()
        }

        Write-Verbose "Done. Elapsed: $((Get-Date).Subtract($start).TotalMilliseconds) ms."
    }

    #
    # Given a CSV file produced by tracerpt.exe, convert it to user friendly text log.
    #
    function ConvertCsvToLog
    {
        Param(
            $CsvPath = $(throw "'CsvPath' parameter is required."),
            $LogPath = $(throw "'LogPath' parameter is required.")
        )

        Write-Verbose "Converting $CsvPath to $LogPath ..."

        if (Test-Path $LogPath)
        {
            Remove-Item $LogPath -Force -ErrorAction Stop
        }

        $csvText = Get-Content $CsvPath
        $csvText[0] = $CSV_HEADER

        $csv = ConvertFrom-Csv $csvText

        $writer = New-Object IO.StreamWriter $LogPath
        $start = Get-Date

        try
        {
            $lineNum = 0

            $csv | ForEach-Object {

                $row = $_

                try
                {
                    if ($_.EventName -ne "EventTrace" -And !($_.EventName.StartsWith("{")))
                    {
                        [DateTime] $datetime = [DateTime]::FromFileTimeUTC($_.ClockTime).ToLocalTime()

                        # convert hex string to decimals
                        $processId = $_.PID -as [int]
                        $threadId = $_.TID -as [int]

                        # Log columns:
                        # Time ProcessID ThreadID Component Message
                        $writer.WriteLine("$($datetime.ToString($TIMESTAMP_FORMAT)) $($processId.ToString().PadRight(5)) $($threadId.ToString().PadRight(5)) $($_.EventName.PadRight(15)) $($_.UserData)")
                    }
                }
                catch
                {
                    # Log exception, eat it, and process the rest of the log.
                    Write-Warning "Unable to process line $lineNum."

                    "Unable to process line:$lineNum of $CsvPath`n$row`n$_`n---" | Out-File $DebugPath -Encoding UTF8 -Append
                }

                $lineNum++
            } # foreach
        }
        finally
        {
            $writer.Close()
        }

        Write-Verbose "Done. Elapsed: $((Get-Date).Subtract($start).TotalMilliseconds) ms."
    }

    #
    # Given an XML file produced by tracerpt.exe, convert it to user friendly text log and store it in an object that will be sorted and written to the LogPath.
    #
    function StoreXMLToLogObjects
    {
        Param(
            [string] $XmlPath = $(throw "'XmlPath' parameter is required."),
            [string[]] $ProviderFilter = $(throw "'ProviderFilter' parameter is required.")
        )

        Write-Verbose "Converting $XmlPath to Log lines that will be written."

        [xml] $xml = Get-Content $XmlPath

        $start = Get-Date
        $UnsortedBatchLogArray = New-Object Collections.ArrayList

        $nodeNum = 0

        $xml.Events.Event | ForEach-Object {

            $row = $_

            try
            {
                $systemNode = $_.System
                $providerNode = $systemNode.Provider
                $providerName = $systemNode.Provider.Name

                if ($providerNode -ne $null -And ($ProviderFilter | %{$providerName -match $_}) -contains $true)
                {
                    $eventDataNode = $_.EventData
                    $executionNode = $systemNode.Execution
                    [DateTime] $datetime = $systemNode.TimeCreated.SystemTime

                    $keywordNode = $_.RenderingInfo

                    # Log columns:
                    # Time ProcessID ThreadID Component Message
                    $eventDataString = ""
                    foreach ($pair in $eventDataNode.Data)
                    {
                        $eventDataString += "[$($pair.Name)] : $($pair.'#text'); "
                    }
                    $UnsortedBatchLogArray.Add([System.Collections.ArrayList]($($datetime.ToString($TIMESTAMP_FORMAT)), $($executionNode.ProcessID.ToString()), $($executionNode.ThreadID.ToString()), $($keywordNode.Task.ToString()), $($eventDataString))) | Out-Null
                }
            }
            catch
            {
                # Log exception, eat it, and process the rest of the log.
                Write-Warning "Unable to process node $nodeNum."

                "Failed to process line:$nodeNum of $XmlPath`n$row`n$_`n---" | Out-File $DebugPath -Encoding UTF8 -Append
            }

            $nodeNum++
        } # foreach

        Write-Verbose "Done. Elapsed: $((Get-Date).Subtract($start).TotalMilliseconds) ms."
        return $UnsortedBatchLogArray
    }

    #
    # Call function DecodeETL here.
    #
    DecodeETL -ETLList $ETLList.GetRange($StartIndex, $Length) -OutPath $OutPath -Type $Type

    #
    # For WU, call function ConvertXmlToLog or ConvertCsvToLog and for non-WU (which could have more than 1 provider
    # and with logs needing to be sorted) call StoreXMLToLogObjects. Currently, ConvertCsvToLog is used only for WU logs
    # as CSV is kept for legacy purposes and all the other logs will be decoded using XML as processing type.
    #
    $UnsortedBatchLogArray = New-Object Collections.ArrayList
    if ($IsProviderWUTraceLogging)
    {
        if ($Type -eq 'XML')
        {
            ConvertXmlToLog -XmlPath $OutPath -LogPath $LogPath
        }
        else
        {
            ConvertCsvToLog -CsvPath $OutPath -LogPath $LogPath
        }
    }
    else
    {
        $UnsortedBatchLogArray = StoreXMLToLogObjects -XmlPath $OutPath -ProviderFilter $ProviderFilter
    }

    # Powershell returns all non-captured stream output, so even if UnsortedBatchLogArray is empty, returning it
    # would return null and not an empty ArrayList. So it's not necessary to check if UnsortedBatchLogArray has 0 elements.
    return $UnsortedBatchLogArray
}

function FlushWindowsUpdateETLs
{
    Write-Verbose "Flushing Windows Update ETLs ..."

    Stop-Service usosvc -ErrorAction Stop
    Stop-Service wuauserv -ErrorAction Stop

    Write-Verbose "Done."
}

#
# Print the DecodeETL results.
# The result from the script "tracerpt.exe" may has some unuseful messages. Please see BUG 33709951 for more details
# Remove all unnecessary empty lines and keep the latest progress value (100%)
#
function PrintDecodeETLResults
{
    Param(
        [System.Object[]] $result = $(throw "'result' parameter is required.")
    )

    foreach ($row in $result)
    {
        # Find the line in the output showing something like 0.00%0.50%0.90%...
        if ($row -And $row.ToString().StartsWith('0.00%'))
        {
            # Only print the last percentage value, e.g. "100%"
            $percentages = $row.ToString().Split(
                '%',
                [StringSplitOptions]::RemoveEmptyEntries
            )

            Write-Host "`n$($percentages[-1])%`n"
        }
        elseif ($row -And !($row.GetType().Name -eq "ArrayList"))
        {
            # Just print the whole line
            Write-Host "$row"
        }
    }
}

#
# Pad log line components, sort and write decoded logs to LogPath
#
function PadAndWriteSortedLogs
{
    Param(
        [System.Collections.ArrayList] $LogLinesArrayList = $(throw "'LogLinesArrayList' parameter is required."),
        [string] $LogPath = $(throw "'LogPath' parameter is required.")
    )

    $start = Get-Date

    # To determine the appropriate padding for ProcessID, ThreadID and EventName
    $maxPIDPadding = 0
    $maxTIDPadding = 0
    $maxEventNamePadding = 0

    #
    # LogLinesArrayList has [Math]::Ceiling(Total ETLs/MAX_ETL_PER_BATCH) System Objects of job output which includes tracerpt
    # output results and ArrayLists of unsorted log lines to be written as output. Determine exact padding, sort the logs and
    # write to disk.
    #
    foreach ($LogLinesObject in $LogLinesArrayList)
    {
        foreach ($row in $LogLinesObject)
        {
            if ($row -And $row.GetType().Name -eq "ArrayList")
            {
                if ($row[1].ToString().length -gt $maxPIDPadding)
                {
                    $maxPIDPadding = $row[1].ToString().length
                }
                if ($row[2].ToString().length -gt $maxTIDPad)
                {
                    $maxTIDPad = $row[2].ToString().length
                }
                if ($row[3].ToString().length -gt $maxEventNamePadding)
                {
                    $maxEventNamePadding = $row[3].ToString().length
                }
            }
        }
    }

    # Construct object of log lines that will be sorted alphabetically (which is chronological in this case) and written
    $LogLines = New-Object Collections.ArrayList
    foreach ($LogLinesObject in $LogLinesArrayList)
    {
        foreach ($row in $LogLinesObject)
        {
            if ($row -And $row.GetType().Name -eq "ArrayList")
            {
                # Time ProcessID ThreadID Component Message
                $LogLines.Add("$($row[0].ToString() + " " + $row[1].PadRight($maxPIDPadding) + " " + $row[2].PadRight($maxTIDPad) + " " + $row[3].PadRight($maxEventNamePadding) + " " + $row[4] + [Environment]::NewLine)") | Out-Null
            }
        }
    }

    if ($LogLines.Count -eq 0)
    {
        throw "No logs are found for the given set of providers in the ETL path(s) provided."
    }

    $writer = New-Object IO.StreamWriter $LogPath
    try
    {
        #
        # Logs that can come from multiple providers need to be sorted as files can be written to in an interleaved manner
        #
        $LogLines = $LogLines | Sort-Object
        if ($LogLines.Count -eq 0)
        {
            throw "Error in sorting logs."
        }

        Write-Verbose "Sorted all log lines in chronological order."

        $LogLines | ForEach-Object {
            try
            {
                $writer.Write("$_")
            }
            catch
            {
                Write-Warning "Unable to write line $_. Trying to write the rest of the file."
            }
        }
    }
    finally
    {
        $writer.Close()
    }

    Write-Verbose "Logs padded, sorted and written in: $((Get-Date).Subtract($start).TotalMilliseconds) ms."
}

#
# Given an ETL path, convert the ETL file(s) into text log.
#
function ConvertETLsToLog
{
    Param(
        [string[]] $ETLPaths = $(throw "'etlPaths' parameter is required."),
        [string] $LogPath = $(throw "'LogPath' parameter is required."),
        [string[]] $ETLFileNameFilter = $(throw "'ETLFileNameFilter' parameter is required."),
        [string[]] $ProviderFilter = $(throw "'ProviderFilter' parameter is required."),
        [ValidateSet('XML', 'CSV')] $Type = $(throw "'type' parameter is required.")
    )

    if ($ETLPaths.Count -gt 1)
    {
        $progressDisplayStr = "`nMerging and converting $($ETLPaths.Count) ETLs into $LogPath ..."
    }
    elseif ($ETLPaths.Count -eq 1)
    {
        $progressDisplayStr = "`nConverting $($ETLPaths[0]) into $LogPath ..."
    }
    else
    {
        throw "No ETL file found."
    }

    Write-Host "`nGetting the list of all ETL files..."

    $start = Get-Date

    [Collections.Generic.List[string]] $etlList = GetListOfETLs -paths $ETLPaths -ETLFileNameFilter $ETLFileNameFilter -ProviderFilter $ProviderFilter
    # Create Working Directory
    New-Item -Path $WORKDIR -ItemType Directory -ErrorAction SilentlyContinue | Out-Null

    # Make the file name be unique, so when multiple WindowsUpdateLog.psm1 run in parallel,
    # these temp files won't stomp on each other.
    $guid = New-Guid
    $tempFilePath = "$WORKDIR\wuetl.$Type.tmp.$guid"
    $tempLogPath = "$WORKDIR\wuetl.log.tmp.$guid"
    $NEW_DEBUG_LOG_PATH = "$WORKDIR\debug.$guid.log"

    Remove-Item "$tempFilePath.*" -Force -ErrorAction SilentlyContinue | Out-Null
    Remove-Item "$tempLogPath.*" -Force -ErrorAction SilentlyContinue | Out-Null
    Remove-Item $NEW_DEBUG_LOG_PATH -Force -ErrorAction SilentlyContinue | Out-Null

    $processed = 0;
    $tempFileCount = 0

    # Pad tempFileCount so files can be sorted numerically.
    $NumFormat = "{0:00000}"

    $decodeETLJobs = @()
    $IsProviderWUTraceLogging = CheckSingleWUProvider -ProviderFilter $ProviderFilter

    while ($processed -lt $etlList.Count)
    {
        $remaining = $etlList.Count - $processed

        $numberedTempFile = "$tempFilePath.$NumFormat" -f $tempFileCount
        $numberedLogFile = "$tempLogPath.$NumFormat" -f $tempFileCount

        if ($remaining -ge $MAX_ETL_PER_BATCH)
        {
            # Parameters for executing $ScriptBlock_DecodeETL
            [Object[]] $scriptBlockParams = @(
                $etlList, #ETLList
                $processed, #StartIndex
                $MAX_ETL_PER_BATCH, #Length
                $numberedTempFile, #OutPath
                $numberedLogFile, #LogPath
                $NEW_DEBUG_LOG_PATH, #DebugPath
                $Type, #Type
                $ProviderFilter, #ProviderNameFilter
                $IsProviderWUTraceLogging #IsProviderWUTraceLogging
            )

            $decodeETLJobs += Start-Job -Name "WULog_${tempFileCount}" -ScriptBlock $ScriptBlock_DecodeETL -ArgumentList $scriptBlockParams

            $processed += $MAX_ETL_PER_BATCH
        }
        else
        {
            # Parameters for executing $ScriptBlock_DecodeETL
            [Object[]] $scriptBlockParams = @(
                $etlList, #ETLList
                $processed, #StartIndex
                $remaining, #Length
                $numberedTempFile, #OutPath
                $numberedLogFile, #LogPath
                $NEW_DEBUG_LOG_PATH, #DebugPath
                $Type, #Type
                $ProviderFilter, #ProviderNameFilter
                $IsProviderWUTraceLogging #IsProviderWUTraceLogging
            )

            $decodeETLJobs += Start-Job -Name "WULog_${tempFileCount}" -ScriptBlock $ScriptBlock_DecodeETL -ArgumentList $scriptBlockParams

            $processed += $remaining
        }

        $tempFileCount++
    }

    Write-Verbose "Background Job Information:"
    if ($VerbosePreference -ne "SilentlyContinue")
    {
        Get-Job
    }

    Write-Host "`nPlease wait for all of conversions to complete...`n"

    # Display the progress bar and wait for all jobs in $decodeETLJobs to complete
    $total = $decodeETLJobs.count
    do
    {
        $completed = @($decodeETLJobs | Where State -eq Completed).Count

        $per = $completed / $total * 100
        Write-Progress -Activity $progressDisplayStr -Status "$completed/$total Complete:" -PercentComplete $per
        Start-Sleep -Milliseconds 1000
    } Until (($decodeETLJobs | Where State -eq Running).Count -eq 0)

    # When all background jobs completed, display 100% in the progress bar for 1 sec,
    # and then close the progress bar
    Write-Progress -Activity $progressDisplayStr -Status "$total/$total Complete:" -PercentComplete 100
    Start-Sleep -Milliseconds 1000
    Write-Progress -Activity $progressDisplayStr -Status "$total/$total Complete:" -Completed

    $failed = $false;
    $UnsortedLogsArrayList = New-Object Collections.ArrayList
    $foundLogArrayListInOutput = $false

    # Go through jobs in $decodeETLJobs to check their States. Print the result of each job on demand.
    # Remove all jobs at the end.
    foreach ($job in $decodeETLJobs)
    {
        Write-Host "`n================ Results from $($job.Name) ================`n"

        $result = Receive-Job $job
        if ($job.State -eq 'Failed')
        {
            Write-Warning $result
            $failed = $true
        }
        else
        {
            $output = $job.ChildJobs.output
            PrintDecodeETLResults -result $output

            # Don't add to list unless loglines are present in the output which is only possible for non WU logs
            if (!($IsProviderWUTraceLogging))
            {
                $UnsortedLogsArrayList.Add($output) | Out-Null
            }
        }

        Write-Host "`n==================================================`n"

        Remove-Job $job
    }

    if ($failed)
    {
        throw "Failed to Complete Get-WindowsUpdateLog Cmdlet!";
    }

    # Writing WU logs after checking for a single (WUTraceLogging) provider
    if ($IsProviderWUTraceLogging)
    {
        if ($tempFileCount -gt 1)
        {
            $actualFileCount = (Get-ChildItem "$tempLogPath.*" | Measure-Object).Count

            Write-Verbose "Merging all $actualFileCount temporary logs into one ..."

            # If the actual file count is not equal to the expected, print warning.
            if ($actualFileCount -ne $tempFileCount)
            {
                Write-Warning "Expected has $tempFileCount temporary logs, but actually has $actualFileCount. So this will affect the WindowsUpdate.log file."
            }
            Get-Content "$tempLogPath.*" | Out-File $LogPath -Encoding UTF8
        }
        else
        {
            $src = "$tempLogPath.$NumFormat" -f 0
            Copy-Item -Path $src -Destination $LogPath -ErrorAction Stop
        }
    }
    else
    {
        # Writing non-WU logs after checking for strongly typed ArrayList in output and calling PadAndWriteSortedLogs
        if ($UnsortedLogsArrayList.Count -gt 0)
        {
            Write-Verbose "Calling function to write logs to $LogPath"
            PadAndWriteSortedLogs -LogLinesArrayList $UnsortedLogsArrayList -LogPath $LogPath
        }
        else
        {
            throw "Unable to write decoded $($LogPath.split('\')[-1]) to $LogPath"
        }
    }
    # Removing $tempLogPath.* and $tempFilePath.*
    Remove-Item "$tempLogPath.*" -ErrorAction SilentlyContinue | Out-Null
    Remove-Item "$tempFilePath.*" -ErrorAction SilentlyContinue | Out-Null

    Write-Verbose "Total elapsed: $((Get-Date).Subtract($start).TotalMilliseconds) ms."

    Write-Host "`n$($LogPath.split('\')[-1]) written to $LogPath`n"
}

# Function to check if ETL path exists
function CheckETLPaths
{
    Param(
        [string[]] $ETLPaths = $(throw "'ETLPaths' parameter is required.")
    )

    foreach ($path in $ETLPaths)
    {
        if (!(Test-Path $path))
        {
            throw "File not found: $path"
        }
    }
}

# Function to check if log file has write access
function CheckLogPathWriteAccess
{
    Param(
        [string] $LogPath = $(throw "'LogPath' parameter is required.")
    )

    $logDir = Split-Path -Parent $LogPath

    if (!(Test-Path $logDir))
    {
        New-Item -Path $logDir -ErrorAction Stop
    }

    try
    {
        "Checking write access" | Out-File -FilePath $LogPath -Encoding ascii
    }
    catch [UnauthorizedAccessException]
    {
        throw "No permission to write to $LogPath"
    }
}

#.ExternalHelp WindowsUpdateLog.psm1-help.xml
function Get-WindowsUpdateLog
{
    [CmdLetBinding(
        SupportsShouldProcess = $true,
        ConfirmImpact = 'High',
        DefaultParameterSetName = 'OnlyWindowsUpdateLog')]
    Param(
        [parameter(
            ValueFromPipeline = $true,
            ValueFromPipelineByPropertyName = $true,
            Position = 0,
            ParameterSetName = 'OnlyWindowsUpdateLog')]
        [Alias('PsPath')]
        [string[]] $ETLPath = @("$env:windir\logs\WindowsUpdate"),

        [parameter(
            Position = 1,
            ParameterSetName = 'OnlyWindowsUpdateLog')]
        [string] $LogPath = "$([Environment]::GetFolderPath("Desktop"))\WindowsUpdate.log",

        [parameter(
            ParameterSetName = 'OnlyWindowsUpdateLog')]
        [ValidateSet('CSV', 'XML')]
        [string] $ProcessingType = 'XML',

        [parameter(
            ParameterSetName = 'OnlyWindowsUpdateLog')]
        [switch] $ForceFlush,

        [parameter(
            ParameterSetName = 'AllLogs')]
        [switch] $IncludeAllLogs
    )

    begin
    {
        $etls = New-Object Collections.ArrayList
    }

    process
    {
        #
        # Handles pipeline input. For e.g. get-childitem C:\temp | get-windowsupdatelog
        #
        if ($_ -ne $null)
        {
            if ($_.PsPath -eq $null -or !(Test-Path $_.PsPath))
            {
                throw "ETL file cannot be found or is invalid: $_"
            }

            $etls.Add($_.FullName) | Out-Null
        }
        #
        # Handles regular input. For e.g. get-windowsupdate.log C:\temp\WindowsUpdate1.etl, C:\temp\WindowsUpdate2.etl
        #
        else
        {
            foreach ($p in $ETLPath)
            {
                if (!(Test-Path $p))
                {
                    throw "File not found: $p"
                }
                $etls.Add($p) | Out-Null
            }
        }
    }

    end
    {
        if ($ForceFlush)
        {
            if ($PSCmdlet.ShouldProcess("$env:COMPUTERNAME", "Stopping Update Orchestrator and Windows Update services"))
            {
                FlushWindowsUpdateETLs
            }
            else
            {
                return
            }
        }

        # The rest of the function doesn't support -WhatIf, so just bail out if -WhatIf is specified
        if ($WhatIfPreference)
        {
            return
        }

        #
        # Make sure we have permission to write log file to requested path.
        #
        CheckLogPathWriteAccess -LogPath $LogPath

        #
        # Do work now.
        #
        $OnlyWULog = !($IncludeAllLogs)
        if ($OnlyWULog)
        {
            ConvertETLsToLog -ETLPaths $etls -LogPath $LogPath -ETLFileNameFilter @("WindowsUpdate*.etl") -ProviderFilter @("WUTraceLogging") -Type $ProcessingType
        }

        else
        {
            # LogParameterMapping is a HashTable created to extend the cmdlet further with key as the type of update and value as the tuple with 5 default values:
            # 1. list of ETL paths from which files are chosen to be decoded
            # 2. log path to which the decoded log is to be written
            # 3. ETLFileNameFilter to filter the ETLs from ETL paths
            # 4. ProviderFilter to filter the provider(s)
            # 5. Processing Type to be used by tracerpt, which is XML
            $LogParameterMapping = @{}

            # Create folder for writing other logs
            $PathSuffixTimestampFormat = "yyyyMMdd.HHmmss"
            $PathSuffixTimestamp = Get-Date -Format $PathSuffixTimestampFormat
            $AllLogsPath = "$([Environment]::GetFolderPath("Desktop"))\UpdateLogs.$($PathSuffixTimestamp)"
            New-Item -Path $AllLogsPath -ItemType Directory -ErrorAction SilentlyContinue | Out-Null

            # When -IncludeAllLogs is specified, user specified parameters are ignored and default values are used
            $LogParameterMapping["WU"] = [System.Tuple]::Create(@("$env:windir\logs\WindowsUpdate"),
                                                        "$($AllLogsPath)\WindowsUpdate.log",
                                                        @("WindowsUpdate*.etl"),
                                                        @("WUTraceLogging"),
                                                        "XML")

            # Exclude only Microsoft.Windows.Update.Orchestrator.UX from the typical USO providers as is to be decoded with the other UX providers.
            $LogParameterMapping["USO"] = [System.Tuple]::Create(@("$env:programdata\USOShared\logs\System"),
                                                        "$($AllLogsPath)\USO.log",
                                                        @("MoUsoCoreWorker*.etl", "UpdateSessionOrchestration*.etl"),
                                                        @("Microsoft.Windows.Update.Orchestrator*((?!UX).)*$"),
                                                        "XML")

            # UX Providers considered so far are: Microsoft.Windows.Update.Orchestrator.UX, Microsoft.Windows.Update.Ux.MusUpdateSettings,
            # Microsoft.Windows.Update.Ux.NotifyIcon, Microsoft.Windows.Update.MoNotificationUx, Microsoft.Windows.Update.NotificationUx,
            # Microsoft.Windows.Update.Ux.MusNotification, Microsoft.Windows.Update.Ux.NotificationHandler
            $LogParameterMapping["UX"] = [System.Tuple]::Create(@("$env:programdata\USOShared\logs\System", "$env:programdata\USOShared\logs\User"),
                                                        "$($AllLogsPath)\UX.log",
                                                        @("MoUxCoreWorker*.etl", "MoNotificationUx*.etl", "TrayIcon*.etl", "UpdateUx*.etl"),
                                                        @("Microsoft.Windows.Update.Orchestrator.UX", "Microsoft.Windows.Update.*Notification*", "Microsoft.Windows.Update.Ux.MusUpdateSettings", "Microsoft.Windows.Update.Ux.NotifyIcon"),
                                                        "XML")

            $Summary = "`nUpdate logs available in $AllLogsPath"
            foreach ($logType in $LogParameterMapping.Keys)
            {
                CheckETLPaths -ETLPaths $LogParameterMapping[$logType].Item1
                CheckLogPathWriteAccess -LogPath $LogParameterMapping[$logType].Item2
                ConvertETLsToLog -ETLPaths $LogParameterMapping[$logType].Item1 -LogPath $LogParameterMapping[$logType].Item2 -ETLFileNameFilter $LogParameterMapping[$logType].Item3 -ProviderFilter $LogParameterMapping[$logType].Item4 -Type $LogParameterMapping[$logType].Item5
                $Summary += "`n`t$logType logs written to " + $LogParameterMapping[$logType].Item2
            }
            Write-Host $Summary
        }
    }
}

Export-ModuleMember -Function Get-WindowsUpdateLog
