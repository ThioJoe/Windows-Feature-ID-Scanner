#########################################################################
# Winhttp Proxy
#########################################################################

<#
    .Synopsis
    Displays current WinHTTP proxy setting.

    .Description
    Displays current WinHTTP proxy setting.

    .Parameter Default
    Displays current WinHTTP default proxy settings.

    .Parameter Advanced
    Displays current WinHTTP advanced proxy settings.
#>
function Get-WinhttpProxy
{
    param
    (
        [parameter(mandatory, parametersetname="Default")]
        [switch]
        $Default,

        [parameter(mandatory, parametersetname="Advanced")]
        [switch]
        $Advanced
    )

    if ($Default)
    {
        netsh winhttp show proxy
    }

    if ($Advanced)
    {
        $line1, $line2, $line3, $JsonLines = netsh winhttp show advproxy
        Write-Output $line1, $line2, $line3

        $Json = ConvertFrom-Json (-Join $JsonLines)

        if ($Json.ConnectionName)
        {
            Write-Output ("Connection name: " + $Json.ConnectionName)
        }

        if ($Json.Proxy)
        {
            Write-Output ("Proxy: " + $Json.Proxy)
        }

        if ($Json.ProxyBypass)
        {
            Write-Output ("ProxyBypass: " + $Json.ProxyBypass)
        }

        if ($Json.AutoconfigUrl)
        {
            Write-Output ("AutoconfigUrl: " + $Json.AutoconfigUrl)
        }

        if ($Json.PSobject.Properties.name -match "AutoDetect")
        {
            Write-Output ("AutoDetect: " + $Json.AutoDetect)
        }
    }
}

<#
    .Synopsis
    Exports the current Winhttp proxy configuration.

    .Description
    Creates a script that contains the current configuration.
    If saved to a file, this script can be used to restore altered configuration settings.
#>
function Export-WinhttpProxy
{
    netsh winhttp dump proxy
}

<#
   .Synopsis
   Resets WinHTTP proxy settings.

   .Description
   Resets WinHTTP proxy settings.

   .Parameter Auto
   Resets WinHTTP proxy autodiscovery service.

   .Parameter Direct
   Resets WinHTTP proxy setting to DIRECT.
#>
function Reset-WinhttpProxy
{
    param
    (
        [parameter(mandatory, parametersetname="Auto")]
        [switch]
        $Auto,

        [parameter(mandatory, parametersetname="Direct")]
        [switch]
        $Direct
    )

    if ($Auto)
    {
        netsh winhttp reset autoproxy
    }

    if ($Direct)
    {
        netsh winhttp reset proxy
    }
}

<#
    .Synopsis
    Imports WinHTTP proxy settings.

    .Description
    Imports WinHTTP proxy settings.

    .Parameter Source
    from where the setting is imported. Accepted values:
        IE - Imports proxy setting from IE.
#>
function Import-WinhttpProxy
{
    param
    (
        [parameter(Mandatory=$true)]
        [ValidateSet("IE")]
        [string]
        $Source
    )

    netsh winhttp import proxy ie
}

<#
    .Synopsis
    Configures WinHTTP proxy settings.

    .Description
    Configures WinHTTP proxy settings.
#>
function Set-WinhttpProxy
{
    param
    (
        [parameter(mandatory, position=0, parametersetname="Default")]
        [string]
        $ProxyServer,

        [parameter(position=1, parametersetname="Default")]
        [string]
        $BypassList,

        [parameter(mandatory, position=0, parametersetname="Advanced")]
        [ValidateSet("User", "Machine")]
        [string]
        $SettingScope,

        [parameter(parametersetname="Advanced")]
        [string]
        $Proxy,

        [parameter(parametersetname="Advanced")]
        [string]
        $ProxyBypass,

        [parameter(parametersetname="Advanced")]
        [string]
        $AutoconfigUrl,

        [parameter(parametersetname="Advanced")]
        [switch]
        $AutoDetect
    )

    switch ($PSCmdlet.ParameterSetName)
    {
        "Default"
        {
            if ($PSBoundParameters.ContainsKey('BypassList'))
            {
                netsh winhttp set proxy proxy-server=$ProxyServer bypass-list=$BypassList
            }
            else
            {
                netsh winhttp set proxy proxy-server=$ProxyServer
            }
        }

        "Advanced"
        {
            $Settings = @{}

            if ($PSBoundParameters.ContainsKey('Proxy'))
            {
                $Settings.Proxy = $Proxy
            }

            if ($PSBoundParameters.ContainsKey('ProxyBypass'))
            {
                $Settings.ProxyBypass = $ProxyBypass
            }

            if ($PSBoundParameters.ContainsKey('AutoconfigUrl'))
            {
                $Settings.AutoconfigUrl = $AutoconfigUrl
            }

            $Settings.AutoDetect = $False
            if ($AutoDetect)
            {
                $Settings.AutoDetect = $True
            }

            $SettingsString = (ConvertTo-Json -Compress $Settings).replace('"', '\"')

            $Output = netsh winhttp set advproxy setting-scope=$SettingScope settings=$SettingsString

            Get-WinhttpProxy -Advanced
        }
    }
}
