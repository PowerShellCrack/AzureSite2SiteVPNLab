Write-Host "Building Tenant two Tenant configurations..." -NoNewline
#region Region 1 to Region 2 connection
#----------------------------------------------------------
$AzureAdvConfigTenantAtoBConn= @{
    rg1=$AzureAdvConfigTenantA.ResourceGroupName
    rg2=$AzureAdvConfigTenantB.ResourceGroupName
    loc1=$AzureAdvConfigTenantA.LocationName
    loc2=$AzureAdvConfigTenantB.LocationName
    VNetGatewayName1=$AzureAdvConfigTenantA.VnetGatewayName
    VNetGatewayName2=$AzureAdvConfigTenantB.VnetGatewayName

    Connection12  = 'cn-' + $SiteAName + '-to-' + $SiteBName +$Appendix
    Connection21  = 'cn-' + $SiteBName + '-to-' + $SiteAName +$Appendix
}

#endregion
Write-Host "Done" -ForegroundColor Green