# Copyright (c) Microsoft Corporation. All rights reserved.
# Collects supported native UOP provider diagnostics; never uploads or changes policy.
Set-StrictMode -Version 3.0

$script:AauProviderId = 'Microsoft.Windows.Update.AutomaticAppUpdater'
# Mirrors ProviderPaths.h; Validate-PackageStaging.ps1 guards the native/manifest/PowerShell contract.
$script:UopLogRootRelativePath = 'Logs\UOPProviders'
$script:UopStateRootRelativePath = 'Microsoft\UOPProviders'
$script:UopPayloadRootRelativePath = 'UOPProviders'

# Keep private functions in this module's scope so callers and test hooks retain one owner.
. (Join-Path $PSScriptRoot 'UopPathGuards.ps1')
. (Join-Path $PSScriptRoot 'UopLogSources.ps1')
. (Join-Path $PSScriptRoot 'UopEventCodec.ps1')
. (Join-Path $PSScriptRoot 'UopEventFormatting.ps1')
. (Join-Path $PSScriptRoot 'UopEtlDecoder.ps1')
function Get-UOPProviderLogs {
    <#
    .SYNOPSIS
    Snapshots and decodes registered native UOP provider diagnostics.
    .DESCRIPTION
    Enumerates ProviderId values beneath the 64-bit HKLM registry key
    SOFTWARE\Microsoft\WindowsUpdate\UOPProviders\System. Only built-in adapters
    select files: registry paths, commands and executables are never used.
    Unrecognized registered providers have explicit Unsupported status.
    The Microsoft.Windows.Update.AutomaticAppUpdater adapter reads
    AutomaticAppUpdater.*.etl and AppUpdateCSP.*.etl from the diagnostics
    directory, plus AAUReportingEvents.log and its numbered archives from
    the state directory, without recursion. Writes UTC-ordered readable event lines
    to UOPProviders\<yyyyMMdd-HHmmss-fff>\<ProviderId>.log in the current directory.
    Collection requires -IncludeAllLogs or -ProviderId; without either, no discovery
    or output occurs. Successful
    collection removes its temporary diagnostic workspace unless -KeepDiagnostics
    or -RawOnly is specified. Retained bundles contain raw snapshots, decoder XML,
    schemas, interpreted metadata and summaries in a unique directory under
    the caller's system temporary directory, safe to delete when no longer needed.
    AAUReportingEvents logs and archives are copied separately,
    byte-for-byte; they are not treated as ETW records.
    WU-style local timestamp/sequence ETLs are collected.
    Filename dates do not determine event chronology.
    Discovery uses filenames, not the live session name/GUID. Only the selected
    InputPath and StatePath are scanned; supply explicit paths for offline history.

    The built-in Windows tracerpt.exe decodes self-describing TraceLogging
    payloads. Message formatting is not used. Named field values, XML attributes,
    nested field XML, emitting PID/TID, complete System metadata and all payload
    correlation fields are retained in DecodedEvents.jsonl. Values are XML representations, not
    guessed CLR types; exported decoder schemas retain available type metadata.
    Historical stack/address fields remain only in the raw/structured bundle, not
    the readable log. No stacks are reconstructed or symbolized.
    SimpleTrace includes local code-flow messages, compiler call-site file/line,
    numeric facts and explicit availability/truncation flags. WorkflowEvent and
    CspOperationResult remain separate structured Reporting records, not trace
    messages. All decoded fields are preserved, including unknown schema versions,
    full-width counts and native results; collection never routes them to telemetry.

    Access is limited by the caller's existing ACL permissions. Collection does
    not elevate, stop/flush traces, delete history, install metadata, change
    policy, or upload data. Only local non-reparse filesystem paths are accepted.
    Live snapshots are best-effort: unflushed buffers cannot be recovered, and a
    circular ETL may change during copy. Changing files are explicitly reported;
    collect closed ETLs with -InputPath for a consistent historical capture.

    Missing source categories produce explicit warnings. Copy/decode failures
    preserve the bundle, write an Incomplete manifest/report, and then raise a
    terminating error. Text-only collections have Status TextOnly; a collection
    of ETLs with no decoded events has Status NoEvents and explicit warnings,
    not proof that an operation had no events. -RawOnly skips all decoding.
    .PARAMETER IncludeAllLogs
    Selects all registered native System providers. Cannot be combined with ProviderId.
    Only supported adapters collect files; other providers receive Unsupported reports.
    .PARAMETER ProviderId
    Registered native provider identities to collect. Cannot be combined with IncludeAllLogs.
    An explicit InputPath requires exactly one supported ProviderId and
    bypasses registry discovery, allowing offline collection without registration.
    .PARAMETER InputPath
    Directory containing ETLs. Defaults to
    %SystemRoot%\Logs\UOPProviders\Microsoft.Windows.Update.AutomaticAppUpdater.
    ETLPath is an alias; it also denotes a directory, not an ETL filename.
    For an explicit InputPath, reporting text defaults to that directory for offline use.
    .PARAMETER StatePath
    Optional separate directory containing AAUReportingEvents logs and
    reporting archives for offline collections. Normally defaults to
    %ProgramData%\Microsoft\UOPProviders\Microsoft.Windows.Update.AutomaticAppUpdater.
    Only the current provider directories are used by default; no state is migrated.
    State.json is not collected.
    .PARAMETER LogPath
    Optional combined destination file for all selected providers. Its parent
    must already exist. When omitted, creates a timestamped directory under UOPProviders
    in the current filesystem directory with one <ProviderId>.log per selected provider.
    A unique suffix distinguishes timestamp collisions.
    Unsupported providers receive a status-only report, not guessed source paths.
    Output cannot reside
    in the protected diagnostics directory, even when InputPath is overridden,
    or in or above the input directory. Source files are never overwritten.
    .PARAMETER Force
    Intentionally replaces an existing output file, subject to ShouldProcess.
    Previously retained raw diagnostic bundles are never replaced or deleted.
    .PARAMETER KeepDiagnostics
    Retains the new raw diagnostic bundle after successful collection. Without it,
    only the readable log remains. Collection failures retain their evidence bundle.
    Each GUID-named UOPProviderLogs.*.diagnostics bundle contains only collector-owned copies and
    can be deleted in its entirety when that evidence is no longer needed.
    .PARAMETER RawOnly
    Collects and retains raw ETL/text snapshots and a manifest without claiming to decode.
    .PARAMETER MaxInputBytes
    Total raw snapshot budget, default 1 GiB. Files exceeding the remaining budget are not copied.
    Budget exhaustion publishes Incomplete with the evidence already collected; sources are unchanged.
    .PARAMETER MaxEvents
    Maximum events retained for the ordered report, default 100000. Raw snapshots are still collected.
    Reaching the limit before another event produces Incomplete, never silent truncation.
    .PARAMETER MaxDecodedXmlBytes
    Maximum XML file size accepted by the parser, default 512 MiB per ETL. Decoder output remains raw
    evidence when this budget is exceeded. This is a parsing budget, not a decoder disk quota.
    .PARAMETER DecoderTimeoutSeconds
    Maximum runtime per tracerpt invocation, default 120 seconds. A timed-out decoder is terminated;
    its raw ETL and partial output remain in the bundle. Increase explicit limits for larger captures.
    .OUTPUTS
    One collection result per provider by default, or one combined result with -LogPath.
    Each result has LogPath, BundlePath, Status, Providers, EventCount and Warnings.
    BundlePath is null when the temporary diagnostic workspace was removed.
    .EXAMPLE
    Get-UOPProviderLogs -IncludeAllLogs
    Writes UOPProviders\<timestamp>\<ProviderId>.log for every registered provider
    and removes each successful collection's temporary workspace.
    .EXAMPLE
    Get-UOPProviderLogs -ProviderId Microsoft.Windows.Update.AutomaticAppUpdater -KeepDiagnostics
    Retains full decoded fields and raw evidence for troubleshooting.
    .EXAMPLE
    Get-UOPProviderLogs -IncludeAllLogs -LogPath C:\Diagnostics\UOPProviders.log
    Collects using existing permissions, normally from an elevated shell.
    .EXAMPLE
    Get-UOPProviderLogs -ProviderId Microsoft.Windows.Update.AutomaticAppUpdater -InputPath C:\SavedAAU -LogPath C:\Diagnostics\aau.log -RawOnly
    Preserves raw files for offline decoding on a compatible Windows host.
    .EXAMPLE
    Get-UOPProviderLogs -IncludeAllLogs -LogPath C:\Diagnostics\UOPProviders.log -Force -WhatIf
    Shows the write operation without creating files or running a decoder.
    .NOTES
    This script module is installed under the inbox Windows PowerShell module
    path. PowerShell module auto-loading makes the exported command available
    without requiring callers to locate or import a private payload path.
    Diagnostic payloads can contain app identifiers and native addresses.
    Protect the chosen output directory and share collected files deliberately.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Default', SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'All')][switch]$IncludeAllLogs,
        [Parameter(Mandatory = $true, ParameterSetName = 'Selected')]
        [ValidateNotNullOrEmpty()][string[]]$ProviderId,
        [Parameter()][Alias('ETLPath')][ValidateNotNullOrEmpty()]
        [string]$InputPath,
        [Parameter()][ValidateNotNullOrEmpty()][string]$StatePath,
        [Parameter()][ValidateNotNullOrEmpty()][string]$LogPath,
        [switch]$Force,
        [switch]$KeepDiagnostics,
        [switch]$RawOnly,
        [ValidateRange(1, [long]::MaxValue)][long]$MaxInputBytes = 1073741824,
        [ValidateRange(1, [int]::MaxValue)][int]$MaxEvents = 100000,
        [ValidateRange(1, [long]::MaxValue)][long]$MaxDecodedXmlBytes = 536870912,
        [ValidateRange(1, 3600)][int]$DecoderTimeoutSeconds = 120
    )

    $ErrorActionPreference = 'Stop'
    if (-not $IncludeAllLogs -and -not $PSBoundParameters.ContainsKey('ProviderId')) {
        Write-Warning 'No logs collected. Specify -IncludeAllLogs or -ProviderId to select providers.'
        return
    }
    $offline = $PSBoundParameters.ContainsKey('InputPath')
    if ($offline) {
        if ($null -eq $ProviderId -or @($ProviderId).Count -ne 1 -or $ProviderId[0] -ine $script:AauProviderId) {
            throw 'InputPath requires exactly one supported ProviderId: Microsoft.Windows.Update.AutomaticAppUpdater.'
        }
        $selected = @($script:AauProviderId)
    }
    else {
        $registered = @(Get-UopRegisteredProviderId | Sort-Object -Unique)
        if ($ProviderId) {
            foreach ($id in $ProviderId) {
                if ($id -notin $registered) {
                    throw "ProviderId is not registered: $(ConvertTo-AauLogText $id). Use InputPath for a supported offline provider."
                }
            }
            $selected = @($registered | Where-Object { $_ -in $ProviderId })
        }
        else { $selected = $registered }
    }
    $collectAau = $script:AauProviderId -in $selected
    if ($PSBoundParameters.ContainsKey('StatePath') -and -not $collectAau) {
        throw 'StatePath requires the AutomaticAppUpdater provider to be selected.'
    }
    $inputDirectory = $null
    $stateDirectory = $null
    $sourceSets = @()
    if ($collectAau) {
        $defaults = Get-AauDefaultDirectories
        if (-not $InputPath) { $InputPath = $defaults.InputPath }
        if (-not $StatePath) {
            $StatePath = if ($offline) { $InputPath } else { $defaults.StatePath }
        }
        $inputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InputPath)
        $stateDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($StatePath)
        Assert-AauLocalPath -Path $inputDirectory
        Assert-AauLocalPath -Path $stateDirectory
        $inputDirectory = [IO.Path]::GetFullPath($inputDirectory)
        if ($inputDirectory.Length -gt 3) { $inputDirectory = $inputDirectory.TrimEnd('\') }
        $stateDirectory = [IO.Path]::GetFullPath($stateDirectory)
        if ($stateDirectory.Length -gt 3) { $stateDirectory = $stateDirectory.TrimEnd('\') }
        Assert-AauLocalPath -Path $inputDirectory
        Assert-AauLocalPath -Path $stateDirectory
        if ($offline -and -not [IO.Directory]::Exists($inputDirectory)) {
            throw "Input directory does not exist or is inaccessible: $inputDirectory"
        }
        if ($PSBoundParameters.ContainsKey('StatePath') -and -not [IO.Directory]::Exists($stateDirectory)) {
            throw "State directory does not exist or is inaccessible: $stateDirectory"
        }
        $reportingPattern = '^AAUReportingEvents(\.\d+)?\.log$'
        $sourceSets = @(
            @{ Directory = $inputDirectory; Pattern = '^(AutomaticAppUpdater|AppUpdateCSP)\..+\.etl$' },
            @{ Directory = $stateDirectory; Pattern = $reportingPattern })
        foreach ($sourceSet in $sourceSets) { Assert-AauLocalPath -Path $sourceSet.Directory }
    }
    if (-not $PSBoundParameters.ContainsKey('LogPath')) {
        if ($selected.Count -eq 0) {
            Write-Warning 'No native UOP providers are registered in the 64-bit System registry key.'
            return
        }
        $outputRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath('UOPProviders')
        Assert-AauLocalPath -Path $outputRoot
        $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff', [Globalization.CultureInfo]::InvariantCulture)
        $outputDirectory = Join-Path $outputRoot $timestamp
        while ($true) {
            if ([IO.Directory]::Exists($outputDirectory) -or [IO.File]::Exists($outputDirectory)) {
                $outputDirectory = Join-Path $outputRoot "$timestamp.$([Guid]::NewGuid().ToString('N'))"
            }
            Assert-AauLocalPath -Path $outputDirectory
            $requests = @(
                foreach ($id in $selected) {
                    $path = Join-Path $outputDirectory (Get-UopProviderLogName -ProviderId $id)
                    Assert-UopOutputPath -OutputPath $path -SourceSets $sourceSets -Force:$Force -AllowMissingParent
                    [pscustomobject]@{ ProviderId = $id; LogPath = $path }
                }
            )
            # Validate every destination before creating anything. New-Item rejects
            # existing directories, including a collision with a concurrent collector.
            if (-not $PSCmdlet.ShouldProcess($outputDirectory, 'Create provider log output directory')) { return }
            try { $null = New-Item -Path $outputDirectory -ItemType Directory -Confirm:$false -ErrorAction Stop }
            catch {
                if ($_.CategoryInfo.Category -ne [Management.Automation.ErrorCategory]::ResourceExists) { throw }
                $outputDirectory = Join-Path $outputRoot "$timestamp.$([Guid]::NewGuid().ToString('N'))"
                continue
            }
            Assert-AauLocalPath -Path $outputDirectory
            break
        }
        $collectionErrors = [Collections.Generic.List[string]]::new()
        foreach ($request in $requests) {
            $parameters = @{}
            foreach ($key in $PSBoundParameters.Keys) { $parameters[$key] = $PSBoundParameters[$key] }
            $parameters.Remove('IncludeAllLogs')
            $parameters.ProviderId = @($request.ProviderId)
            $parameters.LogPath = $request.LogPath
            if ($request.ProviderId -ine $script:AauProviderId) { $parameters.Remove('StatePath') }
            try { Get-UOPProviderLogs @parameters }
            catch { $collectionErrors.Add("$($request.ProviderId): $($_.Exception.Message)") }
        }
        if ($collectionErrors.Count -gt 0) {
            throw "$($collectionErrors -join ' ') One or more provider collections failed."
        }
        return
    }
    $outputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogPath)
    Assert-AauLocalPath -Path $outputPath
    $outputPath = [IO.Path]::GetFullPath($outputPath)
    Assert-UopOutputPath -OutputPath $outputPath -SourceSets $sourceSets -Force:$Force
    $decoder = Join-Path ([Environment]::GetFolderPath('System')) 'tracerpt.exe'
    if (-not $PSCmdlet.ShouldProcess($outputPath, 'Collect diagnostics into a new raw bundle and write UTC-ordered log')) {
        return
    }

    $collectionId = [Guid]::NewGuid().ToString('N')
    $bundlePath = Join-Path ([IO.Path]::GetTempPath()) "UOPProviderLogs.$collectionId.diagnostics"
    Assert-UopOutputPath -OutputPath $bundlePath -SourceSets $sourceSets -AllowMissingParent
    if ([IO.Directory]::Exists($bundlePath) -or [IO.File]::Exists($bundlePath)) {
        throw "Diagnostic workspace already exists; it will not be reused: $bundlePath"
    }
    $null = New-Item -Path $bundlePath -ItemType Directory -Confirm:$false -ErrorAction Stop
    $warnings = [Collections.Generic.List[string]]::new()
    $failures = [Collections.Generic.List[string]]::new()
    $snapshots = [Collections.Generic.List[object]]::new()
    $events = [Collections.Generic.List[object]]::new()
    $providers = [Collections.Generic.List[object]]::new()
    $retainDiagnostics = $KeepDiagnostics -or $RawOnly
    $collectionFailed = $false
    $stagedReport = "$outputPath.$collectionId.tmp"
    $stagedReportCreated = $false
    try {
        $copiedBytes = 0L
        foreach ($id in $selected) {
            if ($id -ieq $script:AauProviderId) { continue }
            $providers.Add([pscustomobject]@{
                ProviderId = $id; Status = 'Unsupported'; EventCount = 0; BundlePath = $null
            })
            $warnings.Add("Unsupported registered ProviderId: $(ConvertTo-AauLogText $id). No files collected for this provider.")
        }
        if ($selected.Count -eq 0) { $warnings.Add('No native UOP providers are registered in the 64-bit System registry key.') }
        $sources = @()
        $providerBundle = $null
        if ($collectAau) {
            $providerBundle = Join-Path $bundlePath $script:AauProviderId
            [void][IO.Directory]::CreateDirectory($providerBundle)
            foreach ($sourceSet in $sourceSets) {
                try { $sources += @(Get-UopSourceFiles @sourceSet) }
                catch { $failures.Add("Source discovery failed for '$($sourceSet.Directory)': $($_.Exception.Message)") }
            }
            $sources = @($sources | Sort-Object FullName -Unique)
            if ($sources.Count -eq 0 -and $failures.Count -eq 0) {
                $missingSources = "No AutomaticAppUpdater/AppUpdateCSP ETLs or AAU reporting logs found. Searched '$inputDirectory' for AutomaticAppUpdater.*.etl and AppUpdateCSP.*.etl; '$stateDirectory' for AAUReportingEvents.log and AAUReportingEvents.<number>.log."
                $warnings.Add($missingSources)
                $failures.Add($missingSources)
            }
            foreach ($category in @('AutomaticAppUpdater.*.etl', 'AppUpdateCSP.*.etl',
                'AAUReportingEvents.log')) {
                if (@($sources | Where-Object Name -like $category).Count -eq 0) {
                    $warnings.Add("Source category missing: $category")
                }
            }
            $warnings.Add('Live files are copied without flushing or stopping ETW. Unflushed buffers and changes during circular-file copying may not be recoverable.')
        }

        $sourceIndex = 0
        $duplicateNames = @($sources | Group-Object Name | Where-Object Count -gt 1 | ForEach-Object Name)
        foreach ($source in $sources) {
            $sourceIndex++
            $snapshotDirectory = $providerBundle
            $sourceLabel = $source.Name
            if ($source.Name -in $duplicateNames) {
                # Preserve distinct source files with the same basename; never overwrite one.
                $sourceFolder = 'Source{0:D4}' -f $sourceIndex
                $snapshotDirectory = Join-Path $providerBundle $sourceFolder
                $sourceLabel = "$sourceFolder\$($source.Name)"
            }
            $snapshotPath = Join-Path $snapshotDirectory $source.Name
            $budgetAccounted = $false
            $scenario = if ($source.Extension -ine '.etl') { 'Reporting' }
                elseif ($source.Name -like 'AppUpdateCSP.*') { 'CSP' } else { 'UOP' }
            try {
                if ($snapshotDirectory -ne $providerBundle) {
                    [void][IO.Directory]::CreateDirectory($snapshotDirectory)
                }
                $snapshot = Copy-AauSnapshot -Source $source -Destination $snapshotPath `
                    -MaximumBytes ($MaxInputBytes - $copiedBytes)
                $copiedBytes += $snapshot.Length
                $budgetAccounted = $true
                $snapshot | Add-Member -NotePropertyName ProviderId -NotePropertyValue $script:AauProviderId
                $snapshot | Add-Member -NotePropertyName Scenario -NotePropertyValue $scenario
                $snapshots.Add($snapshot)
                if (-not $snapshot.UnchangedDuringCopy) {
                    $warnings.Add("Source changed during snapshot; consistency is not guaranteed: $($source.Name)")
                }
            }
            catch {
                if (-not $budgetAccounted -and [IO.File]::Exists($snapshotPath)) {
                    $copiedBytes += [IO.FileInfo]::new($snapshotPath).Length
                }
                $failures.Add("Snapshot failed for '$($source.FullName)': $($_.Exception.Message)")
                continue
            }
            if ($RawOnly -or $source.Extension -ine '.etl') {
                continue
            }
            try {
                $xmlPath = Invoke-UopEtlDecoder -Decoder $decoder -SnapshotPath $snapshotPath `
                    -TimeoutSeconds $DecoderTimeoutSeconds
                $previousCount = $events.Count
                Read-AauDecodedEvents -Path $xmlPath -SourceFile $sourceLabel `
                    -MaximumBytes $MaxDecodedXmlBytes | ForEach-Object {
                    if ($events.Count -ge $MaxEvents) {
                        throw "Decoded event budget exceeded ($MaxEvents). Earlier events and raw evidence are preserved."
                    }
                    $_ | Add-Member -NotePropertyName UopProviderId -NotePropertyValue $script:AauProviderId
                    $_ | Add-Member -NotePropertyName Scenario -NotePropertyValue $scenario
                    $events.Add($_)
                }
                if ($events.Count -eq $previousCount) {
                    $warnings.Add("No decodable component events in '$($source.Name)'; see raw ETL and decoder summary.")
                }
            }
            catch {
                $failures.Add("Decode failed for '$($source.Name)': $($_.Exception.Message)")
            }
        }

        Set-UopPolicyCoverage -Events $events
        $incompletePolicyRecords = @($events | Where-Object {
            $_.PSObject.Properties['PolicyCoverage'] -and $_.PolicyCoverage.PartCoverage -ne 'Complete'
        }).Count
        if ($incompletePolicyRecords -gt 0) {
            $warnings.Add("Policy capture coverage is missing, duplicated or invalid for $incompletePolicyRecords records. Producer truncation is reported separately; retain raw events.")
        }
        $aauStatus = if ($failures.Count -gt 0) { 'Incomplete' }
            elseif ($RawOnly) { 'RawOnly' }
            elseif (@($sources | Where-Object Extension -eq '.etl').Count -eq 0) { 'TextOnly' }
            elseif ($events.Count -eq 0) { 'NoEvents' }
            else { 'Decoded' }
        if ($collectAau) {
            $providers.Add([pscustomobject]@{
                ProviderId = $script:AauProviderId; Status = $aauStatus; EventCount = $events.Count
                BundlePath = $providerBundle; InputPath = $inputDirectory; StatePath = $stateDirectory
                SourceDirectories = @($sourceSets | ForEach-Object { $_.Directory } | Sort-Object -Unique)
            })
        }
        $status = if ($failures.Count -gt 0) { 'Incomplete' }
            elseif ($selected.Count -eq 0) { 'NoProviders' }
            elseif (-not $collectAau) { 'Unsupported' }
            elseif ($providers.Count -gt 1) { 'Partial' }
            else { $aauStatus }
        $retainDiagnostics = $KeepDiagnostics -or $RawOnly -or $failures.Count -gt 0
        $manifest = [ordered]@{
            SchemaVersion = 1
            CollectedUtc = [DateTimeOffset]::UtcNow.ToString('o')
            Discovery = $(if ($offline) { 'Offline' } else { 'Registry64' })
            Providers = @($providers.ToArray())
            LogPath = $outputPath
            BundlePath = $bundlePath
            Status = $status
            Decoder = $(if ($RawOnly -or -not $collectAau) { $null } else { $decoder })
            EventCount = $events.Count
            CopiedBytes = $copiedBytes
            Limits = [ordered]@{
                MaxInputBytes = $MaxInputBytes
                MaxEvents = $MaxEvents
                MaxDecodedXmlBytes = $MaxDecodedXmlBytes
                DecoderTimeoutSeconds = $DecoderTimeoutSeconds
            }
            Snapshots = @($snapshots.ToArray())
            Warnings = @($warnings.ToArray())
            Errors = @($failures.ToArray())
        }
        $encoding = [Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllText((Join-Path $bundlePath 'Collection.json'),
            ($manifest | ConvertTo-Json -Depth 8), $encoding)
        $reportStream = [IO.File]::Open($stagedReport, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::None)
        $stagedReportCreated = $true
        $writer = $null
        try {
            $writer = [IO.StreamWriter]::new($reportStream, $encoding)
            $writer.WriteLine("# UOP Providers | Status=$status | Events=$($events.Count) | UTC")
            if ($retainDiagnostics) { $writer.WriteLine("# Bundle=$bundlePath") }
            else { $writer.WriteLine('# Diagnostics retention not requested; use -KeepDiagnostics for raw evidence.') }
            foreach ($provider in $providers) {
                $writer.WriteLine("# Provider=$(ConvertTo-AauLogText $provider.ProviderId) | Status=$($provider.Status)")
            }
            if ($collectAau) { $writer.WriteLine("# AAU/UOP, AAU/CSP = $script:AauProviderId; reporting text is separate raw evidence.") }
            foreach ($warning in $warnings) { $writer.WriteLine("# Warning: $(ConvertTo-AauLogText $warning)") }
            foreach ($failure in $failures) { $writer.WriteLine("# Error: $(ConvertTo-AauLogText $failure)") }
            $jsonWriter = [IO.StreamWriter]::new((Join-Path $bundlePath 'DecodedEvents.jsonl'), $false, $encoding)
            try {
                foreach ($eventRecord in ($events | Sort-Object TimestampUtc, UopProviderId, SourceFile)) {
                    $jsonWriter.WriteLine(($eventRecord | ConvertTo-Json -Depth 12 -Compress))
                    $writer.WriteLine((Format-AauEvent $eventRecord))
                }
            }
            finally {
                $jsonWriter.Dispose()
            }
        }
        finally {
            if ($null -ne $writer) { $writer.Dispose() }
            else { $reportStream.Dispose() }
        }
        # Atomic publication never opens an existing output for truncation, including
        # an existing hardlink. Recheck replacement authorization after collection.
        Assert-AauLocalPath -Path $outputPath
        if ([IO.File]::Exists($outputPath)) {
            if (-not $Force) {
                throw "Output was created during collection; raw diagnostics remain at '$bundlePath'. Use -Force to replace it."
            }
            [IO.File]::Replace($stagedReport, $outputPath, [Management.Automation.Language.NullString]::Value)
        }
        else {
            [IO.File]::Move($stagedReport, $outputPath)
        }
        foreach ($warning in $warnings) {
            Write-Warning $warning
        }
        if ($failures.Count -gt 0) {
            throw "$($failures -join ' ') Diagnostic collection is incomplete. Report: '$outputPath'; raw bundle: '$bundlePath'."
        }
    }
    catch {
        $collectionFailed = $true
        $retainDiagnostics = $retainDiagnostics -or $failures.Count -gt 0 -or
            $snapshots.Count -gt 0 -or $events.Count -gt 0
        if ($retainDiagnostics) {
            Write-Warning "Collector-owned evidence remains at '$bundlePath'; this bundle can be deleted when no longer needed." -WarningAction Continue
        }
        throw
    }
    finally {
        if ($stagedReportCreated -and [IO.File]::Exists($stagedReport)) {
            try {
                if ($retainDiagnostics) {
                    [IO.File]::Move($stagedReport, (Join-Path $bundlePath 'Collected.log'))
                }
                else { [IO.File]::Delete($stagedReport) }
            }
            catch {
                $cleanupError = "Temporary report cleanup failed at '$stagedReport': $($_.Exception.Message)"
                if ($collectionFailed) { Write-Warning $cleanupError -WarningAction Continue }
                else { throw $cleanupError }
            }
        }
        if (-not $retainDiagnostics) {
            # Only this invocation's new GUID-named workspace, after atomic publication.
            # Never enumerate or remove earlier retained bundles or any source directory.
            try { [IO.Directory]::Delete($bundlePath, $true) }
            catch {
                $cleanupError = "Diagnostic workspace cleanup failed at '$bundlePath': $($_.Exception.Message)"
                if ($collectionFailed) { Write-Warning $cleanupError -WarningAction Continue }
                else { throw $cleanupError }
            }
            if (-not [IO.Directory]::Exists($bundlePath)) {
                $bundlePath = $null
                foreach ($provider in $providers) { $provider.BundlePath = $null }
            }
        }
    }
    [pscustomobject]@{
        LogPath = $outputPath
        BundlePath = $bundlePath
        Status = $status
        EventCount = $events.Count
        Providers = @($providers.ToArray())
        Warnings = @($warnings.ToArray())
    }
}

Export-ModuleMember -Function Get-UOPProviderLogs
