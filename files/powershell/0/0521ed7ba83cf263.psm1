function Get-StartApps($Name) {
    Get-AllStartApps | Where-Object { $_.Name -like "*$Name*" }
}

function Get-AllStartApps {
    (New-Object -ComObject Shell.Application).
        NameSpace("shell:::{4234d49b-0245-4df3-b780-3893943456e1}"). # FOLDERID_AppsFolder
            Items() | % {
               [PSCustomObject]@{
                    'Name'=$_.Name
                    'AppID'=$_.Path
                }
        }
}