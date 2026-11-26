function Get-StartApps {
    param(
        [string]$Name = '*',
        [ValidateSet('Unsorted', 'Name', 'AppID')]
        [string]$SortOrder = 'Name'
    )
    $apps = Get-AllStartApps -SortOrder $SortOrder
    $apps | Where-Object { $_.Name -like "*$Name*" }
}

function Get-AllStartApps {
    param(
        [ValidateSet('Unsorted', 'Name', 'AppID')]
        [string]$SortOrder = 'Name'
    )

    $appsFolder = 'shell:::{4234d49b-0245-4df3-b780-3893943456e1}' # FOLDERID_AppsFolder
    $shell = New-Object -ComObject Shell.Application
    $appsFolderItems = $shell.NameSpace($appsFolder).Items()

    $apps = @()
    foreach ($item in $appsFolderItems) {
        $apps += [PSCustomObject]@{
            'Name' = $item.Name
            'AppID' = $item.Path
        }
    }

    # Return based on sort order
    switch ($SortOrder) {
        'Name' { $apps | Sort-Object Name }
        'AppID' { $apps | Sort-Object AppID }
        Default { $apps }
    }
}
