 data _system_translations 
 {
    ConvertFrom-StringData @'

    # Fallback text
    # Copy all the strings in the psd1 file here

    msg_ad_forest = SMB Delegation cmdlets require the Active Directory forest to be in Windows Server 2012 forest functional level.

    msg_ad_cmdlets = SMB Delegation cmdlets require the installation of the Active Directory module for Windows PowerShell.

'@
}
 
Import-LocalizedData -BindingVariable _system_translations -fileName SmbLocalization.psd1 -ErrorAction SilentlyContinue

 function Set-SmbPathAcl
 {
     [CmdletBinding()]
     param(
        [Parameter(Mandatory=$true)]
        [string]
        $ShareName,

        [Parameter()]
        [string]
        $ScopeName = $null
    )

    if( ($null -ne $ScopeName ) -and ( "" -ne $ScopeName) )
    {
        (Get-SmbShare -Name $ShareName -ScopeName $ScopeName ).PresetPathACL | Set-Acl
    }
    else
    {
        (Get-SmbShare -Name $ShareName ).PresetPathACL | Set-Acl
    }

 }

function CheckDelegationPrerequisites
{
    if( $null -eq (Get-Command -Module ActiveDirectory) )
    {
        Write-Error $_system_translations.msg_ad_cmdlets

        return $false
    }

    #
    # Forest mode should be greater than or equal to Windows2012Forest
    #
    if( (Get-AdForest).ForestMode.ToInt32($null) -lt [Microsoft.ActiveDirectory.Management.AdForestMode]::Windows2012Forest.ToInt32($null) )
    {
        Write-Error $_system_translations.msg_ad_forest

        return $false
    }

    return $true
}

 function Get-SmbDelegation
 {
     [CmdletBinding()]
     param(
        [Parameter(Mandatory=$true)]
        [string]
        $SmbServer
    )

    $check = CheckDelegationPrerequisites

    if( -not $check )
    {
        return
    }

    $result = @()

    $fsAD = Get-ADComputer -filter {Name -Like $SmbServer} -Properties 'msds-allowedtoactonbehalfofotheridentity'
    
    foreach ($AllowedAccount in $fsAD."msDS-AllowedToActOnBehalfOfOtherIdentity".Access) 
    { 
        $samAccountName = $AllowedAccount.IdentityReference.Value 
        $samAccountName = $samAccountName.Remove(0, ($samAccountName.IndexOf("\")+1))

        $result += Get-ADComputer -Filter {SamAccountName -Like $samAccountName} 
    }

    $result.Name
 }

 function Enable-SmbDelegation
 {
     [CmdletBinding()]
     param(
        [Parameter(Mandatory=$true)]
        [string]
        $SmbClient,

        [Parameter(Mandatory=$true)]
        [string]
        $SmbServer
    )

    $check = CheckDelegationPrerequisites

    if( -not $check )
    {
        return
    }

    $delegationPrinciples = @() 
    $fsAD = Get-ADComputer -Filter {Name -Like $SmbServer} -Properties msDS-AllowedToActOnBehalfOfOtherIdentity

    foreach ($AllowedAccount in $fsAD."msDS-AllowedToActOnBehalfOfOtherIdentity".Access) 
    { 
        $samAccountName = $AllowedAccount.IdentityReference.Value 
        $samAccountName = $samAccountName.Remove(0, ($samAccountName.IndexOf("\")+1))

        $delegationPrinciples += Get-ADComputer -Filter {SamAccountName -Like $samAccountName} 
    }

    $delegationPrinciples += Get-ADComputer -Identity $SmbClient 
    $fsAD | Set-ADComputer -PrincipalsAllowedToDelegateToAccount $delegationPrinciples 
 }


 function Disable-SmbDelegation
 {
     [CmdletBinding()]
     param(
        [Parameter()]
        [string]
        $SmbClient,

        [Parameter(Mandatory=$true)]
        [string]
        $SmbServer,

        [System.Management.Automation.SwitchParameter]
        [bool]
        $Force = $false
    )

    $check = CheckDelegationPrerequisites

    if( -not $check )
    {
        return
    }

    $delegationPrinciples = @() 
    $fsAD = Get-ADComputer -Filter {Name -Like $SmbServer} -Properties msDS-AllowedToActOnBehalfOfOtherIdentity

    if( ($null -ne $SmbClient) -and ("" -ne $SmbClient) )
    {
        foreach ($AllowedAccount in $fsAD."msDS-AllowedToActOnBehalfOfOtherIdentity".Access) 
        { 
            $samAccountName = $AllowedAccount.IdentityReference.Value 
            $samAccountName = $samAccountName.Remove(0, ($samAccountName.IndexOf("\")+1))

            $adc = Get-ADComputer -Filter {SamAccountName -Like $samAccountName} 

            if( $adc.Name -ne $SmbClient )
            {
                $delegationPrinciples += $adc
            }
        }
    }

    $fsAD | Set-ADComputer -PrincipalsAllowedToDelegateToAccount $delegationPrinciples 
 }

 function DumpAndTestCertificate([String]$Storename, [String]$Thumbprint) {

    # All SMB Server certificates for QUIC should be from the machine store
    $Certificate = (Get-Item -path Cert:\LocalMachine\$Storename\$Thumbprint)

    if ($null -eq $Certificate)
    {

        Write-Error -Message "Unable to retrieve certificate '$Storename' '$Thumbprint'" -Category ObjectNotFound;
        return;
    }

    # Certificate is self-signed if the issuer-name and subject-name match
    $IsSelfSigned = -not (Compare-Object $Certificate.IssuerName $Certificate.SubjectName)

    #$SubjectName = $Certificate.SubjectName.Name;
    $SubjectOid = $Certificate.SubjectName.Oid;
    $SubjectRawData = $Certificate.SubjectName.RawData;

    $SignatureAlgorithm = $Certificate.SignatureAlgorithm.Value.ToString() + " " + $Certificate.SignatureAlgorithm.FriendlyName.ToString();

    #$Certificate | Select-Object -Property *
    $Certificate | Select-Object -Property @{Name = 'SMBServerCertificateMappingName'; Expression = { $MappingName } },
                                           @{Name = 'SelfSigned'; Expression = { $IsSelfSigned.ToString() } },
                                           SubjectName,
                                           Subject,
                                           @{Name = 'SubjectOid'; Expression = { $SubjectOid } },
                                           @{Name = 'SubjectRawData'; Expression = { $SubjectRawData } },
                                           FriendlyName,
                                           @{Name = 'SignatureAlgorithm'; Expression = { $SignatureAlgorithm } }, 
                                           Thumbprint,
                                           NotBefore,
                                           NotAfter,
                                           SendAsTrustedIssuer,
                                           PublicKey,
                                           DnsNameList | Format-List

    if ($IsSelfSigned)
    {
        $TestResult = $Certificate | Test-Certificate -AllowUntrustedRoot
    }
    else
    {
        $TestResult = $Certificate | Test-Certificate 
    }

    if ($TestResult)
    {
        Write-Output "Test-Certificate result : PASS"
    }
    else
    {
        Write-Error "Test-Certificate result : FAIL"
    }

}
 function Get-SmbServerCertProps
 {
     [CmdletBinding()]
     param(
        [Parameter(Mandatory=$true)]
        [string]
        $Name,

        [System.Management.Automation.SwitchParameter]
        [bool]
        $Force = $false
    )

    $AllCertMappings = Get-SmbServerCertificateMapping -Name $Name;


    foreach ($CertMapping in $AllCertMappings) {

        Write-Output "---------------------------------------------------------------------------------------------------------------"

        $MappingName = $($CertMapping).Name

        Write-Output "Checking Mapping '$MappingName'....."

        $StoreName = $($CertMapping).StoreName

        DumpAndTestCertificate -Storename $StoreName -Thumbprint $CertMapping.Thumbprint

        $RenewalChain = $($CertMapping).RenewalChain

        Write-Output "`r`nRenewalChain: $RenewalChain"

        if ($RenewalChain -ne "") {

            Write-Output "`r`nTesting certificates in the RenewalChain.....`r`n"

            $RenewalChain -split ":" | ForEach-Object {

                $RenewedCert = $_
                if ($null -eq $RenewedCert -or $RenewedCert -eq "") {
                    continue
                }
                Write-Output "`r`nRenewedCert: $RenewedCert"
                Write-Output "-------------------------------------------------------"

                DumpAndTestCertificate -Storename $StoreName -Thumbprint $RenewedCert
            }
        }
    }
}

 Set-Alias -Name ssmbp -Value Set-SmbPathAcl
 Set-Alias -Name gsmbd -Value Get-SmbDelegation
 Set-Alias -Name esmbd -Value Enable-SmbDelegation
 Set-Alias -Name dsmbd -Value Disable-SmbDelegation
 Set-Alias -Name gsmbscp -Value Get-SmbServerCertProps


 Export-ModuleMember -Function Set-SmbPathAcl -Alias ssmbp
 Export-ModuleMember -Function Get-SmbDelegation -Alias gsmbd
 Export-ModuleMember -Function Enable-SmbDelegation -Alias esmbd
 Export-ModuleMember -Function Disable-SmbDelegation -Alias dsmbd
 Export-ModuleMember -Function Get-SmbServerCertProps -Alias gsmbscp