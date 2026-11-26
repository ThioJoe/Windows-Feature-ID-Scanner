
$global:DONamespace = "root/Microsoft/Windows/DeliveryOptimization"

enum DownloadMode
{
    CdnOnly = 0
    Lan = 1
    Group = 2
    Internet = 3
    Simple = 99
    Bypass = 100
}

enum SwarmStatus
{
    Downloading = 0
    Complete
    Caching
    Paused
}

enum Priority
{
    Background
    Foreground
}

enum ConfigProvider
{
    RegistryProvider = 5
    MdmProvider = 7
    SettingsProvider       # Settings (UX) provider
    AdminProvider          # Admin provider (powershell, WMI, etc.)

    DefaultProvider = 99
}

enum PeerType
{
    PeerType_none = 0
    PeerType_LAN
    PeerType_CDN
    PeerType_Internet
    PeerType_Group
    PeerType_DOINC
    PeerType_LocalCache
    PeerType_LinkLocal
}

class DOPeerInfo
{
    [string] $IP;
    [PeerType] $PeerType;
    [bool] $ConnectionEstablished;
    [uint64] $BytesSent;
    [uint64] $BytesReceived;
    [uint32] $UploadRateBytes;
    [uint32] $DownloadRateBytes;
}

class DOSwarmStats
{
    [string] $FileId
    [uint64] $FileSize
    [uint64] $FileSizeInCache
    [uint64] $TotalBytesDownloaded
    [double] $PercentPeerCaching
    [uint64] $BytesFromPeers
    [uint64] $BytesFromHttp
    [SwarmStatus] $Status
    [Priority] $Priority
    [uint64] $BytesFromCacheServer
    [uint64] $BytesFromLanPeers
    [uint64] $BytesFromLinkLocalPeers
    [uint64] $BytesFromGroupPeers
    [uint64] $BytesFromInternetPeers
    [uint64] $BytesToLanPeers
    [uint64] $BytesToLinkLocalPeers
    [uint64] $BytesToGroupPeers
    [uint64] $BytesToInternetPeers
    [timespan] $DownloadDuration
    [uint32] $HttpConnectionCount
    [uint32] $CacheServerConnectionCount
    [uint32] $LanConnectionCount
    [uint32] $LinkLocalConnectionCount
    [uint32] $GroupConnectionCount
    [uint32] $InternetConnectionCount
    [DownloadMode] $DownloadMode
    [uri] $SourceURL
    [uri] $CacheHost
    [uint32] $NumPeers
    [string] $PredefinedCallerApplication
    [Nullable[datetime]] $ExpireOn
    [bool] $IsPinned
}

class DOFilePeerInfo
{
    [string] $FileId
    [DOPeerInfo[]] $PeersInfo
}

class DOPerfSnap
{
    [uint32] $FilesDownloaded
    [uint32] $FilesUploaded
    [uint32] $Files
    [uint64] $TotalBytesDownloaded
    [uint64] $TotalBytesUploaded
    [uint64] $AverageDownloadSize
    [uint64] $AverageUploadSize
    [DownloadMode] $DownloadMode
    [uint64] $CacheSizeBytes
    [uint64] $TotalDiskBytes
    [uint64] $AvailableDiskBytes
    [float] $CpuUsagePct
    [uint64] $MemUsageKB
    [uint32] $NumberOfPeers
    [uint32] $CacheHostConnections
    [uint32] $CdnConnections
    [uint32] $LanConnections
    [uint32] $LinkLocalConnections
    [uint32] $GroupConnections
    [uint32] $InternetConnections
    [uint32] $DownlinkBps
    [uint32] $DownlinkUsageBps
    [uint32] $UplinkBps
    [uint32] $UplinkUsageBps
    [uint32] $ForegroundDownloadRatePct
    [uint32] $BackgroundDownloadRatePct
    [uint32] $UploadRatePct
    [uint32] $UploadCount
    [uint32] $ForegroundDownloadCount
    [uint32] $ForegroundDownloadsPending
    [uint32] $BackgroundDownloadCount
    [uint32] $BackgroundDownloadsPending
}

class DOMonthlyPerfSnap
{
    [uint64] $UploadLanBytes
    [uint64] $UploadInternetBytes
    [uint64] $DownloadHttpBytes
    [uint64] $DownloadCacheHostBytes
    [uint64] $DownloadLanBytes
    [uint64] $DownloadInternetBytes
    [uint64] $DownloadFgRateKbps
    [uint64] $DownloadBgRateKbps
    [bool] $UploadLimitReached
    [datetime] $MonthStartDate
}

class DOConfig
{
    [DownloadMode] $DownloadMode
    [ConfigProvider] $DownloadModeProvider
    [uint32] $DownBackLimitBps
    [ConfigProvider] $DownBackLimitBpsProvider
    [uint32] $DownloadForegroundLimitBps
    [ConfigProvider] $DownloadForegroundLimitBpsProvider
    [uint32] $DownBackLimitPct
    [ConfigProvider] $DownBackLimitPctProvider
    [uint16] $DownloadForegroundLimitPct
    [ConfigProvider] $DownloadForegroundLimitPctProvider
    [uint16] $MaxUploadRatePct
    [ConfigProvider] $MaxUploadRateProvider
    [double] $UploadLimitMonthlyGB
    [ConfigProvider] $UploadLimitMonthlyGBProvider
}

class DOExtendedConfig : DOConfig
{
    [uint16] $BatteryPctToSeed
    [ConfigProvider] $BatteryPctToSeedProvider
    [string] $WorkingDirectory
    [ConfigProvider] $WorkingDirectoryProvider
    [uint32] $MinTotalDiskSize
    [ConfigProvider] $MinTotalDiskSizeProvider
    [uint32] $MinTotalRAM
    [ConfigProvider] $MinTotalRAMProvider
    [bool] $VpnPeerCachingAllowed
    [ConfigProvider] $VpnPeerCachingAllowedProvider
    [string] $VpnKeywords
    [ConfigProvider] $VpnKeywordsProvider
    [string] $SetHoursToLimitDownloadBackground
    [ConfigProvider] $SetHoursToLimitDownloadBackgroundProvider
    [string] $SetHoursToLimitDownloadForeground
    [ConfigProvider] $SetHoursToLimitDownloadForegroundProvider
}

function Get-DeliveryOptimizationStatus
{
    <#
    .LINK
    https://aka.ms/do-cmdlets
    #>
    [CmdletBinding()]
    [OutputType([DOSwarmStats],[DOFilePeerInfo],[string],[DOPeerInfo])]
    Param(
        [Parameter(ParameterSetName="PeerInfo")]
        [switch] $PeerInfo,
        [Parameter(ParameterSetName="PeerInfo")]
        [switch] $AsObject,
        [Parameter(ParameterSetName="PeerInfo")]
        [int] $SelectPeerCount = 5
    )

    if ($PeerInfo)
    {
        $swarms = Get-CimInstance -Namespace $global:DONamespace -ClassName MSFT_DeliveryOptimizationFilePeerInfo
        foreach ($swarm in $swarms)
        {
            $doSwarmInfo = [DOFilePeerInfo]@{
                FileId=$swarm.FileId
                PeersInfo=@()
            }
            if ($swarm.IPs)
            {
                for ($i = 0; $i -lt $swarm.IPs.Length; $i++)
                {
                    $doSwarmInfo.PeersInfo += [DOPeerInfo]@{
                        IP=$swarm.IPs[$i]
                        PeerType=$swarm.PeerTypes[$i]
                        ConnectionEstablished=$swarm.ConnectionEstablished[$i]
                        BytesSent=$swarm.BytesSent[$i]
                        BytesReceived=$swarm.BytesReceived[$i]
                        UploadRateBytes=$swarm.UploadRates[$i]
                        DownloadRateBytes=$swarm.DownloadRates[$i]
                    }
                }
                $doSwarmInfo.PeersInfo = ([object[]]($doSwarmInfo.PeersInfo | Sort-Object BytesReceived -Descending))[0..$($SelectPeerCount-1)]
            }
            if ($AsObject)
            {
                Write-output $doSwarmInfo
            }
            elseif ($doSwarmInfo.PeersInfo -ne $null)
            {
                Write-Output $doSwarmInfo.FileId
                Write-Output $doSwarmInfo.PeersInfo[0..$($SelectPeerCount-1)]
            }
        }
    }
    else
    {
        $swarms = Get-CimInstance -Namespace $global:DONamespace -ClassName MSFT_DeliveryOptimizationFile
        foreach ($swarm in $swarms)
        {
            $doSwarmStats = [DOSwarmStats]@{
                FileId=$swarm.FileId
                FileSize=$swarm.FileSize
                FileSizeInCache=$swarm.FileSizeInCache
                TotalBytesDownloaded=$swarm.TotalBytesDownloaded
                PercentPeerCaching=0
                BytesFromHttp=$swarm.BytesFromHttp
                Status=$swarm.Status
                BytesFromCacheServer=$swarm.BytesFromCacheServer
                BytesFromLanPeers=$swarm.BytesFromLanPeers
                BytesFromLinkLocalPeers=$swarm.BytesFromLinkLocalPeers
                BytesFromGroupPeers=$swarm.BytesFromGroupPeers
                BytesFromInternetPeers=$swarm.BytesFromInternetPeers
                BytesToLanPeers=$swarm.BytesToLanPeers
                BytesToLinkLocalPeers=$swarm.BytesToLinkLocalPeers
                BytesToGroupPeers=$swarm.BytesToGroupPeers
                BytesToInternetPeers=$swarm.BytesToInternetPeers
                DownloadDuration=[TimeSpan]::FromMilliseconds($swarm.DownloadDurationMsecs)
                HttpConnectionCount=$swarm.HttpConnectionCount
                CacheServerConnectionCount=$swarm.CacheServerConnectionCount
                LanConnectionCount=$swarm.LanConnectionCount
                LinkLocalConnectionCount=$swarm.LinkLocalConnectionCount
                GroupConnectionCount=$swarm.GroupConnectionCount
                InternetConnectionCount=$swarm.InternetConnectionCount
                DownloadMode=$swarm.DownloadMode
                SourceURL=$swarm.SourceURL
                CacheHost=$swarm.CacheHost
                NumPeers=$swarm.PeerCount
                PredefinedCallerApplication=$swarm.PredefinedCallerApplication
                ExpireOn=$swarm.ExpireOn
                IsPinned=$swarm.IsPinned
            }
            $doSwarmStats.BytesFromPeers = $doSwarmStats.BytesFromLanPeers + $doSwarmStats.BytesFromInternetPeers
            if ($doSwarmStats.TotalBytesDownloaded -ne 0)
            {
                $doSwarmStats.PercentPeerCaching = (100.0 * $doSwarmStats.BytesFromPeers) / $doSwarmStats.TotalBytesDownloaded
            }
            if ($swarm.IsBackground)
            {
                $doSwarmStats.Priority = [Priority]::Background
            }
            else
            {
                $doSwarmStats.Priority = [Priority]::Foreground
            }
            Write-Output $doSwarmStats
        }
    }
}

function Get-DeliveryOptimizationPerfSnap
{
    <#
    .LINK
    https://aka.ms/do-cmdlets
    #>
    [CmdletBinding()]
    [OutputType([DOPerfSnap])]
    Param()

    $allStats = Get-CimInstance -Namespace $global:DONamespace -ClassName MSFT_DOBaseStatus
    $basicConfig = $allStats | Where-Object {($_.CimClass).CimClassName -eq "MSFT_DeliveryOptimizationConfig"}
    $currentStatus = $allStats | Where-Object {($_.CimClass).CimClassName -eq "MSFT_DOCurrentStatus"}
    $downloadUsage = $allStats | Where-Object {($_.CimClass).CimClassName -eq "MSFT_DODownloadUsage"}
    $uploadUsage = $allStats | Where-Object {($_.CimClass).CimClassName -eq "MSFT_DOUploadUsage"}
    $snapInfo = [DOPerfSnap]@{
        DownloadMode=$basicConfig.DownloadMode
        Files=$currentStatus.Swarms
        CacheSizeBytes=$currentStatus.CacheSizeBytes
        TotalDiskBytes=$currentStatus.DiskTotalBytes
        AvailableDiskBytes=$currentStatus.DiskAvailableBytes
        CpuUsagePct=$currentStatus.CpuUsagePct
        MemUsageKB=$currentStatus.MemUsageKBytes
        NumberOfPeers=$currentStatus.PeerInfoCount
        CacheHostConnections=$currentStatus.CacheServerConnections
        CdnConnections=$currentStatus.CdnConnections
        LanConnections=$currentStatus.LanConnections
        LinkLocalConnections=$currentStatus.LinkLocalConnections
        GroupConnections=$currentStatus.GroupConnections
        InternetConnections=$currentStatus.InternetConnections
        DownlinkBps=$downloadUsage.LinkBps
        DownlinkUsageBps=$downloadUsage.LinkUsageBps
        UplinkBps=$uploadUsage.LinkBps
        UplinkUsageBps=$uploadUsage.LinkUsageBps
        ForegroundDownloadRatePct=$downloadUsage.ForegroundRatePct
        BackgroundDownloadRatePct=$downloadUsage.BackgroundRatePct
        UploadRatePct=$uploadUsage.UploadRatePct
        UploadCount=$uploadUsage.Uploads
        ForegroundDownloadCount=$downloadUsage.PriorityDownloads
        ForegroundDownloadsPending=$downloadUsage.PriorityDownloadsPending
        BackgroundDownloadCount=$downloadUsage.NormalDownloads
        BackgroundDownloadsPending=$downloadUsage.NormalDownloadsPending
    }
    foreach ($swarmStats in (Get-DeliveryOptimizationStatus))
    {
        if ($swarmStats.TotalBytesDownloaded -gt 0)
        {
            $snapInfo.FilesDownloaded++
            $snapInfo.TotalBytesDownloaded += $swarmStats.TotalBytesDownloaded
            $bytesToPeers = $swarmStats.BytesToLanPeers + $swarmStats.BytesToInternetPeers
            $snapInfo.TotalBytesUploaded += $bytesToPeers
            if ($bytesToPeers -gt 0)
            {
                $snapInfo.FilesUploaded++
            }
        }

        if ($snapInfo.FilesDownloaded -gt 0)
        {
            $snapInfo.AverageDownloadSize = $snapInfo.TotalBytesDownloaded / $snapInfo.FilesDownloaded;
        }

        if ($snapInfo.FilesUploaded -gt 0)
        {
            $snapInfo.AverageUploadSize = $snapInfo.TotalBytesUploaded / $snapInfo.FilesUploaded
        }
    }
    return $snapInfo
}

function Get-DeliveryOptimizationPerfSnapThisMonth
{
    <#
    .LINK
    https://aka.ms/do-cmdlets
    #>
    [CmdletBinding()]
    [OutputType([DOMonthlyPerfSnap])]
    Param()

    $usage = Get-CimInstance -Namespace $global:DONamespace -ClassName MSFT_DOBaseStatus
    $downloadUsage = $usage | Where-Object {($_.CimClass).CimClassName -eq "MSFT_DODownloadUsage"}
    $uploadUsage = $usage | Where-Object {($_.CimClass).CimClassName -eq "MSFT_DOUploadUsage"}

    $snapInfo = [DOMonthlyPerfSnap]@{
        UploadLanBytes=$uploadUsage.MonthlyLanBytes
        UploadInternetBytes=$uploadUsage.MonthlyInternetBytes
        DownloadHttpBytes=$downloadUsage.MonthlyCdnBytes
        DownloadCacheHostBytes=$downloadUsage.MonthlyCacheHostBytes
        DownloadLanBytes=$downloadUsage.MonthlyLanBytes
        DownloadInternetBytes=$downloadUsage.MonthlyInternetBytes
        DownloadFgRateKbps=$downloadUsage.MonthlyFrRateBps * 8 / 1Kb
        DownloadBgRateKbps=$downloadUsage.MonthlyBkRateBps * 8 / 1Kb
        UploadLimitReached=$false
        MonthStartDate=Get-Date -Day 1 -Hour 0 -Minute 0 -Second 0
    }
    if ($uploadUsage.MonthlyUploadRestriction -ne 0)
    {
        $snapInfo.MonthlyUploadLimitReached = $true
    }

    return $snapInfo
}

function Get-DODownloadMode
{
    <#
    .LINK
    https://aka.ms/do-cmdlets
    #>
    [CmdletBinding()]
    [OutputType([DownloadMode])]
    Param()

    $config = Get-CimInstance -Namespace $global:DONamespace -ClassName MSFT_DeliveryOptimizationConfig
    return [DownloadMode]($config.DownloadMode)
}

function Get-DOMaxBackgroundBandwidth
{
    <#
    .LINK
    https://aka.ms/do-cmdlets
    #>
    [CmdletBinding()]
    [OutputType([uint32])]
    Param()

    $config = Get-CimInstance -Namespace $global:DONamespace -ClassName MSFT_DeliveryOptimizationConfig
    return $config.DownBackLimitBps
}

function Get-DOMaxForegroundBandwidth
{
    <#
    .LINK
    https://aka.ms/do-cmdlets
    #>
    [CmdletBinding()]
    [OutputType([uint32])]
    Param()

    $config = Get-CimInstance -Namespace $global:DONamespace -ClassName MSFT_DeliveryOptimizationConfig
    return $config.DownForeLimitBps
}

function Get-DOPercentageMaxBackgroundBandwidth
{
    <#
    .LINK
    https://aka.ms/do-cmdlets
    #>
    [CmdletBinding()]
    [OutputType([System.Byte])]
    Param()

    $config = Get-CimInstance -Namespace $global:DONamespace -ClassName MSFT_DeliveryOptimizationConfig
    return $config.DownBackLimitPct
}

function Get-DOPercentageMaxForegroundBandwidth
{
    <#
    .LINK
    https://aka.ms/do-cmdlets
    #>
    [CmdletBinding()]
    [OutputType([System.Byte])]
    Param()

    $config = Get-CimInstance -Namespace $global:DONamespace -ClassName MSFT_DeliveryOptimizationConfig
    return $config.DownForeLimitPct
}

function PopulateBaseConfig([DOConfig] $outConfig)
{
    $config = Get-CimInstance -Namespace $global:DONamespace -ClassName MSFT_DeliveryOptimizationConfig -verbose:$false
    $outConfig.DownloadMode = $config.DownloadMode
    $outConfig.DownloadModeProvider = $config.DownloadModeProvider
    $outConfig.DownBackLimitBps = $config.DownBackLimitBps
    $outConfig.DownBackLimitBpsProvider = $config.DownBackLimitBpsProvider
    $outConfig.DownloadForegroundLimitBps = $config.DownForeLimitBps
    $outConfig.DownloadForegroundLimitBpsProvider = $config.DownForeLimitBpsProvider
    $outConfig.DownBackLimitPct = $config.DownBackLimitPct
    $outConfig.DownBackLimitPctProvider = $config.DownBackLimitPctProvider
    $outConfig.DownloadForegroundLimitPct = $config.DownForeLimitPct
    $outConfig.DownloadForegroundLimitPctProvider  = $config.DownForeLimitPctProvider
    $outConfig.MaxUploadRatePct = $config.MaxUploadRatePct
    $outConfig.MaxUploadRateProvider = $config.MaxUploadRateProvider
    $outConfig.UploadLimitMonthlyGB = $config.UpLimitMonthlyGB
    $outConfig.UploadLimitMonthlyGBProvider = $config.UpLimitMonthlyGBProvider
}

function Get-DOConfig
{
    <#
    .LINK
    https://aka.ms/do-cmdlets
    #>
    [CmdletBinding()]
    [OutputType([DOConfig],[DOExtendedConfig])]
    Param()

    if ($VerbosePreference -ne "SilentlyContinue")
    {
        $extendedConfig = Get-CimInstance -Namespace $global:DONamespace -ClassName MSFT_DeliveryOptimizationExtendedConfig -verbose:$false
        $config = [DOExtendedConfig]@{
            BatteryPctToSeed=$extendedConfig.BatteryPctToSeed
            BatteryPctToSeedProvider=$extendedConfig.BatteryPctToSeedProvider
            WorkingDirectory=$extendedConfig.WorkingDirectory
            WorkingDirectoryProvider=$extendedConfig.WorkingDirectoryProvider
            MinTotalDiskSize=$extendedConfig.MinTotalDiskSize
            MinTotalDiskSizeProvider=$extendedConfig.MinTotalDiskSizeProvider
            MinTotalRAM=$extendedConfig.MinTotalRAM
            MinTotalRAMProvider=$extendedConfig.MinTotalRAMProvider
            VpnPeerCachingAllowed=$extendedConfig.VpnPeerCachingAllowed
            VpnPeerCachingAllowedProvider=$extendedConfig.VpnPeerCachingAllowedProvider
            VpnKeywords=$extendedConfig.VpnKeywords
            VpnKeywordsProvider=$extendedConfig.VpnKeywordsProvider
            SetHoursToLimitDownloadBackground=$extendedConfig.SetHoursToLimitDownloadBackground
            SetHoursToLimitDownloadBackgroundProvider=$extendedConfig.SetHoursToLimitDownloadBackgroundProvider
            SetHoursToLimitDownloadForeground=$extendedConfig.SetHoursToLimitDownloadForeground
            SetHoursToLimitDownloadForegroundProvider=$extendedConfig.SetHoursToLimitDownloadForegroundProvider
        }
    }
    else
    {
        $config = [DOConfig]@{}
    }
    PopulateBaseConfig($config)
    return $config
}
