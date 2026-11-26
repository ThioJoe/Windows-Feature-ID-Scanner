<#

Copyright (c) 2011 Microsoft Corporation. All Rights Reserved.

Module Name:

    SmbShare.Format.Helper.psm1

Description:

    Provides helper routines for formatting the output of
    SmbShare CmdLets.

#>

function Format-LinkSpeed($LinkSpeed)
<#
Function Description:
    This function returns the link speed of a network adapter

Arguments:
    $LinkSpeed

Return Value:
    Formatted link speed
#>
{
    $out=
      if($LinkSpeed -eq $null)
        {"Unknown"}
      else
        {
          switch ($LinkSpeed)
          {
            {$_ -lt 1000} {"$_  bps"; break}
            {$_ -lt 1000000} {"$($_/1000) Kbps"; break}
            {$_ -lt 1000000000} {"$($_/1000000) Mbps"; break}
            default {"$($_/1000000000) Gbps"}
          }
       }

     return $out
}

function Format-SmbInstances($Instances)
{
  $out =
    switch ($Instances)
      {
          {$_ -eq 0} {"None"; break}
          {$_ -eq 1} {"Default"; break}
          {$_ -eq 2} {"CSV"; break}
          {$_ -eq 4} {"SBL"; break}
          {$_ -eq 8} {"SR"; break}
          {$_ -eq 3} {"SBL, SR"; break}
          {$_ -eq 5} {"Default, CSV"; break}
          {$_ -eq 9} {"Default, SBL"; break}
          {$_ -eq 6} {"Default, SR"; break}
          {$_ -eq 10} {"CSV, SBL"; break}
          {$_ -eq 12} {"CSV, SR"; break}
          {$_ -eq 7} {"SBL, SR"; break}
          {$_ -eq 11} {"Default, CSV, SBL"; break}
          {$_ -eq 13} {"Default, SBL, SR"; break}
          {$_ -eq 14} {"CSV, SBL, SR"; break}
          {$_ -eq 15} {"Default, CSV, SBL, SR"; break}
          default {"None"}
      }

  return $out
}

function Format-TransportType($TransportType)
{
  $out =
    switch ($TransportType)
      {
        {$_ -eq 1} {"TCP"}
        {$_ -eq 2} {"RDMA"}
        {$_ -eq 4} {"QUIC"}
      }
  
  return $out
}

function Format-SmbDialect($SmbDialect)
{
  $out =
    switch ($SmbDialect)
      {
        {$_ -eq 0}     {"None"; break}
        {$_ -eq 514}   {"SMB202"; break}
        {$_ -eq 528}   {"SMB210"; break}
        {$_ -eq 768}   {"SMB300"; break}
        {$_ -eq 770}   {"SMB302"; break}
        {$_ -eq 785}   {"SMB311"; break}
        {$_ -eq 65535} {"None"; break}
        
        default {
          "0x" + $SmbDialect.ToString("X")
        }
      }

  return $out
}