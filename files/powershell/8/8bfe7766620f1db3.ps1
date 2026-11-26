# Copyright (c) Microsoft Corporation. All rights reserved.
# Private fragment, dot-sourced into its owning module; not an independent entrypoint.
function Set-UopPolicyCoverage {
    param([Collections.IEnumerable]$Events)

    # This describes observed capture coverage, not delivery/ingestion or policy effectiveness.
    # Preserve original Fields. Never deduplicate copied/overlapping events or invent missing rows.
    $groups = @{}
    foreach ($event in $Events) {
        if ($event.EventName -ne 'PolicyStatusCritical' -or
            -not (Test-AauSameGuid $event.ProviderId '{584f8d8e-9a40-4c95-ad7b-1602a9895a5f}')) { continue }
        $coverage = [pscustomobject]@{
            PartCoverage = 'Invalid'; MissingPartCount = $null
            Reason = ''; PayloadLocation = 'DecodedEvents.jsonl'
        }
        $event | Add-Member -NotePropertyName PolicyCoverage -NotePropertyValue $coverage -Force
        $group = $null
        try {
            $values = @{}
            $duplicates = $false
            foreach ($field in $event.Fields) {
                if ($field.Kind -ne 'Data' -or $field.Path -ne $field.Name) { continue }
                if ($values.ContainsKey($field.Name)) { $duplicates = $true }
                else { $values[$field.Name] = ([string]$field.Value).Trim() }
            }
            $snapshot = [guid]::Empty
            $process = [uint32]0
            if (-not [guid]::TryParse($values['snapshotId'], [ref]$snapshot) -or $snapshot -eq [guid]::Empty -or
                -not (Test-AauSameGuid $event.ActivityId $snapshot.ToString()) -or
                -not [uint32]::TryParse($event.ProcessId, [ref]$process) -or $process -eq 0) {
                throw [FormatException]::new('Missing or inconsistent snapshot/activity/process identity.')
            }
            # Include schema identity so parts from different schemas are never combined.
            $key = "$process/$snapshot/$($values['schemaVersion'])"
            if (-not $groups.ContainsKey($key)) {
                $groups[$key] = @{
                    Records = [Collections.Generic.List[object]]::new()
                    Indices = [Collections.Generic.HashSet[uint32]]::new()
                    Expected = $null; Duplicate = $false; Invalid = $false
                }
            }
            $group = $groups[$key]
            $group.Records.Add($coverage)
            if ($duplicates) { throw [FormatException]::new('Duplicate top-level payload fields.') }
            if ($values['schemaVersion'] -ne '1') {
                throw [FormatException]::new('Unsupported policy detail schema; raw fields retained.')
            }
            if (-not $values.ContainsKey('policyStatus') -or [string]::IsNullOrEmpty($values['policyStatus']) -or
                ($values['policyStatus'].Length + 1) * 2 -gt 12 * 1024) {
                throw [FormatException]::new('Missing or oversized policyStatus payload.')
            }
            $numbers = @{}
            $names = @('partIndex', 'partCount')
            foreach ($name in $names) {
                $number = [uint64]0
                if (-not [uint64]::TryParse($values[$name], [Globalization.NumberStyles]::None,
                    [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
                    throw [FormatException]::new("Invalid or unavailable $name.")
                }
                $numbers[$name] = $number
            }
            if ($numbers.partCount -eq 0 -or $numbers.partCount -gt [uint32]::MaxValue -or
                $numbers.partIndex -ge $numbers.partCount) {
                throw [FormatException]::new('Invalid part indices/counts.')
            }
            # Policy snapshots are never truncated; every row is carried by some part.
            if ($values.ContainsKey('truncated') -or $values.ContainsKey('omittedRows') -or
                $values.ContainsKey('snapshotIncludedRows') -or $values.ContainsKey('maximumParts') -or
                $values.ContainsKey('maximumRows')) {
                throw [FormatException]::new('Policy snapshots cannot carry truncation fields.')
            }
            if ($null -eq $group.Expected) { $group.Expected = $numbers.partCount }
            elseif ($group.Expected -ne $numbers.partCount) {
                throw [FormatException]::new('Conflicting partCount within one snapshot.')
            }
            if (-not $group.Indices.Add([uint32]$numbers.partIndex)) { $group.Duplicate = $true }
        }
        catch [FormatException] {
            $coverage.Reason = $_.Exception.Message
            if ($null -ne $group) { $group.Invalid = $true }
        }
    }
    foreach ($group in $groups.Values) {
        $status = 'Invalid'
        $missing = $null
        if (-not $group.Invalid) {
            $missing = ([decimal]$group.Expected - $group.Indices.Count).ToString([Globalization.CultureInfo]::InvariantCulture)
            $status = if ($group.Duplicate) { 'Duplicate' }
                elseif ($group.Indices.Count -ne $group.Expected) { 'Missing' }
                else { 'Complete' }
        }
        foreach ($coverage in $group.Records) {
            $coverage.PartCoverage = $status
            $coverage.MissingPartCount = $missing
            if ($status -eq 'Invalid' -and -not $coverage.Reason) {
                $coverage.Reason = 'Conflicting or invalid part metadata.'
            }
        }
    }
}

function Format-AauEvent {
    param([Parameter(Mandatory = $true)]$Event)

    $values = @{}
    foreach ($field in $Event.Fields) {
        if ($field.Kind -eq 'Data' -and $field.Path -eq $field.Name) {
            # tracerpt pads numeric XML values; preserve those bytes in Fields, not the readable view.
            $values[$field.Name] = ([string]$field.Value).Trim()
        }
    }
    $result = ''
    foreach ($name in @('Result', 'HResult')) {
        if ($values.ContainsKey($name) -and $values[$name]) {
            $result = Format-AauResult $values[$name]
            break
        }
    }
    $isCspEvent = $Event.Provider -match 'AppUpdateCSP'
    $isWilFailure = $Event.EventName -in @('WilFailure', 'WilFailureEvent') -or
        ($isCspEvent -and $Event.EventName -eq 'Failure')
    $severity = 'Information'
    if ($values.ContainsKey('Verbosity')) {
        $severityNames = @{ '0' = 'Error'; '1' = 'Warning'; '2' = 'Information'; '3' = 'Verbose' }
        if ($severityNames.ContainsKey($values['Verbosity'])) {
            $severity = $severityNames[$values['Verbosity']]
        }
    }
    elseif ($Event.SystemMetadata.Contains('Level')) {
        $level = ([xml]$Event.SystemMetadata.Level).DocumentElement.InnerText
        $levelNames = @{ '1' = 'Critical'; '2' = 'Error'; '3' = 'Warning'; '4' = 'Information'; '5' = 'Verbose' }
        if ($levelNames.ContainsKey($level)) {
            $severity = $levelNames[$level]
        }
    }
    if ($result -match '^0x[89A-F]' -or $isWilFailure) {
        $severity = 'Error'
    }
    $component = $Event.Component
    if ($component -eq 'Microsoft.Windows.Update.AppUpdateCSP') { $component = 'AppUpdateCSP' }
    elseif ($component -in @('Microsoft.Windows.AutomaticAppUpdater', 'Microsoft.Windows.Update.AutomaticAppUpdater',
        'Microsoft.Windows.AutomaticAppUpdater.Diagnostics')) {
        $component = 'AAU'
    }
    $operation = $Event.EventName
    if ($values['OperationName']) { $operation = $values['OperationName'] }
    if ($values['StageName']) { $operation += "/$($values['StageName'])" }
    $hasNamedCspOperation = $isCspEvent -and $values['Operation'] -and $values['Operation'] -notmatch '^\d+$'
    if ($hasNamedCspOperation) {
        $operation = $values['Operation']
        if ($values['Phase']) { $operation += "/$($values['Phase'])" }
    }
    if (-not $operation) { $operation = 'Event' }
    $failureTypes = @{ '0' = 'thrown'; '1' = 'returned'; '2' = 'logged'; '3' = 'fail-fast' }
    if ($isWilFailure -and $values.ContainsKey('FailureType') -and $failureTypes.ContainsKey($values['FailureType'])) {
        $operation = "Failure $($failureTypes[$values['FailureType']])"
    }
    if ($isWilFailure) {
        $failureKind = $operation
        $failureCode = if ($result -match '^0x[0-9A-Fa-f]{8}$') { $result.Substring(2) } else { 'unavailable' }
        $module = $values['SourceModule']
        if (-not $module) { $module = $values['ProcessName'] }
        $module = if ($module) { ($module -split '[\\/]')[-1] } else { 'module-unavailable' }
        $file = $values['SourceFile']
        if (-not $file) { $file = $values['File'] }
        $file = if ($file) { ($file -split '[\\/]')[-1] } else { '' }
        $fileLine = $values['SourceLine']
        if (-not $fileLine) { $fileLine = $values['Line'] }
        $operation = "*FAILED* [$failureCode] $module"
        if ($file) {
            $operation += ", $file"
            if ($fileLine) { $operation += " @$fileLine" }
        }
        $operation += " | $failureKind"
    }
    $isScanDisposition = $Event.EventName -eq 'WorkflowEvent' -and
        $values['OperationName'] -eq 'Scan' -and $values['StageName'] -eq 'Disposition'
    if ($isScanDisposition -and $result) {
        if ($result -match '^0x[89A-F]') { $operation = 'Scan failed.' }
        elseif ($result -eq '0x00000000' -and $values.ContainsKey('ItemCount')) {
            $operation = "Scan completed; updates=$($values['ItemCount'])."
        }
    }
    $message = ConvertTo-AauLogText $values['Message']
    if ($Event.EventName -eq 'SimpleTrace' -and $message) {
        $operation = $message
        $message = ''
    }
    $timestamp = [DateTimeOffset]::Parse($Event.TimestampUtc, [Globalization.CultureInfo]::InvariantCulture)
    $scenario = if ($Event.PSObject.Properties['Scenario']) { "AAU/$($Event.Scenario) " } else { '' }
    $line = '{0} {1,6} {2,6} {3}{4,-18} {5,-11} {6}' -f
        $timestamp.ToUniversalTime().ToString('yyyy/MM/dd HH:mm:ss.fffffff', [Globalization.CultureInfo]::InvariantCulture),
        $Event.ProcessId, $Event.ThreadId, $scenario, (ConvertTo-AauLogText $component), $severity,
        (ConvertTo-AauLogText $operation)
    if ($message) { $line += " $message" }
    $details = [Collections.Generic.List[string]]::new()
    if ($Event.PSObject.Properties['PolicyCoverage']) {
        $coverage = $Event.PolicyCoverage
        $details.Add("PolicyParts=$($coverage.PartCoverage)")
        if ($null -ne $coverage.MissingPartCount) { $details.Add("MissingParts=$($coverage.MissingPartCount)") }
        $details.Add('PolicyPayload=DecodedEvents.jsonl')
        if ($coverage.Reason) { $details.Add("PolicyCoverageReason=$(ConvertTo-AauLogText $coverage.Reason)") }
    }
    if ($result -and $result -ne '0x00000000' -and -not $isWilFailure) {
        $resultLabel = if ($Event.EventName -eq 'WorkflowEvent') { 'OperationHResult' } else { 'Result' }
        $details.Add("$resultLabel=$result")
    }

    # File/line is sufficient to navigate source, without template-expanded compiler signatures.
    $source = ''
    foreach ($name in @('SourceFile', 'File')) {
        if ($values[$name]) {
            $source = ($values[$name] -split '[\\/]')[-1]
            break
        }
    }
    $sourceLine = $values['SourceLine']
    if (-not $sourceLine) { $sourceLine = $values['Line'] }
    if ($sourceLine -and $sourceLine -ne '0') {
        if ($source) { $source += ":$sourceLine" }
        else { $details.Add("SourceLine=$sourceLine") }
    }
    if ($source -and -not $isWilFailure) { $details.Add("Source=$(ConvertTo-AauLogText $source)") }
    if (-not $isWilFailure -and $values['SourceModule'] -and $values['SourceModule'] -ne $values['ProcessName']) {
        $details.Add("Module=$(ConvertTo-AauLogText $values['SourceModule'])")
    }
    if ($values['JobId'] -and $values['JobId'] -notmatch '^\{?00000000-0000-0000-0000-000000000000\}?$') {
        $details.Add("Job=$(ConvertTo-AauLogText $values['JobId'])")
    }
    foreach ($name in @('ActivityId', 'RelatedActivityId')) {
        $value = [string]$Event.$name
        if ($name -eq 'RelatedActivityId' -and (Test-AauSameGuid $value $values['JobId'])) { continue }
        if ($value -and $value -notmatch '^\{?00000000-0000-0000-0000-000000000000\}?$') {
            $label = if ($name -eq 'ActivityId') { 'Activity' } else { 'RelatedActivity' }
            $details.Add("$label=$(ConvertTo-AauLogText $value)")
        }
    }
    $omitted = @('SchemaVersion', 'Component', 'ComponentId', 'Verbosity', 'Message',
        'Result', 'HResult', 'SourceFile', 'File', 'SourceLine', 'Line', 'SourceFunction', 'Function',
        'OperationName', 'StageName', 'JobId', 'SourceModule', 'HasWorkflowContext', 'PointerBits', 'FrameCount', 'Terminal')
    foreach ($field in $Event.Fields) {
        $name = [string]$field.Name
        $value = ([string]$field.Value).Trim()
        if ($name -eq 'policyStatus' -and $Event.PSObject.Properties['PolicyCoverage']) { continue }
        if ($field.Kind -ne 'Data' -or $name -in $omitted -or
            $field.Path -match '(?i)stack|address|returnaddr|calleraddr|function|signature' -or
            $name -match 'Available$' -or [string]::IsNullOrWhiteSpace($value)) { continue }
        if (($name -eq 'Operation' -and $values['OperationName']) -or
            ($name -eq 'Stage' -and $values['StageName'])) { continue }
        if ($hasNamedCspOperation -and $name -in @('Operation', 'Phase')) { continue }
        if ($name -eq 'RootActivityId' -and (Test-AauSameGuid $value $values['JobId'])) { continue }
        if ($isWilFailure -and ($name -eq 'ProcessName' -or
                ($name -eq 'FailureType' -and $failureTypes.ContainsKey($value)))) { continue }
        if ($isScanDisposition -and (($name -in @('Disposition', 'OutcomeCode') -and $value -eq '0') -or
                ($name -eq 'ItemCount' -and $operation.StartsWith('Scan completed;')))) { continue }
        if ($Event.EventName -eq 'WorkflowEvent' -and $value -eq '0' -and
            (($name -eq 'Progress' -and $values['StageName'] -ne 'Progress') -or
                ($name -eq 'Disposition' -and $values['StageName'] -ne 'Disposition'))) { continue }
        if ($name -eq 'SourceModule' -and $value -eq $values['ProcessName']) { continue }
        if (($name -eq 'ProcessId' -and $value -eq $Event.ProcessId) -or
            ($name -eq 'ThreadId' -and $value -eq $Event.ThreadId) -or
            ($name -eq 'OriginalWilThreadId' -and $value -eq $Event.ThreadId)) { continue }
        if ($name -eq 'TimestampUtc') {
            $captured = [DateTimeOffset]::MinValue
            if ([DateTimeOffset]::TryParse($value, [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$captured) -and $captured -eq $timestamp) { continue }
        }
        $availability = $values["${name}Available"]
        if ($name -eq 'DurationMilliseconds') { $availability = $values['DurationAvailable'] }
        if ($availability -in @('false', '0')) { continue }
        if ($name -eq 'ContextResult' -and $values['ContextAvailable'] -in @('false', '0')) { continue }
        if ($value -match '^\{?00000000-0000-0000-0000-000000000000\}?$' -or
            ($value -eq 'false' -and $name -match 'Truncated$|^(Terminal|RebootRequired|HasWorkflowContext|CorrelationOverflow)$') -or
            ($value -match '^(0|0x0+)$' -and $name -in @('Flags', 'FailureFlags', 'ContextResult', 'NtStatus',
                'OriginatingContextId', 'CurrentContextId', 'OriginalWilThreadId'))) {
            continue
        }
        if ($name -match '(Result|HResult|ExtendedError)$' -or $name -eq 'NtStatus') { $value = Format-AauResult $value }
        $label = $field.Path
        if ($name -in @('__TlgCV__', 'CorrelationVector')) { $label = 'CV' }
        $details.Add("$(ConvertTo-AauLogText $label)=$(ConvertTo-AauLogText $value)")
    }
    if ($details.Count -gt 0) { $line += ' | ' + ($details -join ' | ') }
    return $line
}
