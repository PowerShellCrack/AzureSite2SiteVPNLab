# Hybrid Lab Setup using Hyper-V and Azure Site-2-Site VPN

## Prereqs

- Azure subscription (VSE or Trial will work)
- Windows OS thats supports Hyper-V
- Edge router with S2S IPSEC VPN capabilities OR vyOS Router
  - This lab uses a virtual router called VyOS. The ISO can be found [**here**](https://downloads.vyos.io/?dir=release/legacy/1.1.8/VyOS-1.1.8-amd64.iso)
- Access to home router and port forwarding
- Partial knowledge with Powershell
- SSH utility such as putty or git cmd. You can get it [**here**](https://git-scm.com/downloads)

## Scripts

- **configs.ps1**. <-- This script is used to answer script values; linked to all scripts
  - Rename _configs.example.ps1_ to **configs.ps1**. 
  - Be sure to look through the hashtables and change anything you feel is necessary.  
  - All the script use this as an answer file for each of the setup. The answers are loaded in hashtable format
  - There are few things you should change on the top section:

```powershell
$LabPrefix = '<lab name>' #identifier for names in lab

$domain = '<lab fqdn>' #just a name for now (no DC install....yet)

$UseBGP = $false # not required for VPN, but can help. Costs more.
#https://docs.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-bgp-overview

$AzEmail = '' #used only in autoshutdown (for now)


#this is used to configure default username and password on Azure VM's
$VMAdminUser = '<admin>'
$VMAdminPassword = '<password>'

$OnPremSubnetCIDR = '10.100.0.0/16'

$AzureHubSubnetCIDR = '10.10.0.0/16'
$AzureSpokeSubnetCIDR = '10.20.0.0/16'

$ISOLocation = 'D:\ISOs\VyOS-1.1.8-amd64.iso'

#https://docs.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-bgp-overview
$UseBGP = $false # not required for VPN, but can help. Costs more.

#used in step 5
$AzureVnetToVnetPeering = @{
    SiteASubscriptionID = '<SubscriptionAID>'
    SiteATenantID= '<TenantAID>'
    SiteBSubscriptionID = '<SubscriptionBID>'
    SiteBTenantID = '<TenantBID>'
}
```

- **library.ps1** <-- Custom functions used to automate 

**NOTE**: All logs are written using a transcript to the logs folder; just in case you need to troubleshoot

## Setup Hyper-V Lab

**NOTE:** be sure to run these scripts with elevated rights.

1. run script: **Step 1. Setup HyperV Lab.ps1**

### Setup VYOS Router (in Hyper-V)

1. run script: **Step 2. Setup Vyos Router in Lab.ps1**
2. The first few steps for the vyos will be manual until SSH is established
   - You will be prompted to make configurations to the router. Also once SSH is established the script will generate RSA key to auto logon.
   This is a temporary process because vyos does not save authorized_keys.  if login is successful, it will auto configure the vyos router for you otherwise you will be presented with a copy/paste configurations.
   - You can use the script to load the vYOS router as long as you change the location to your ISO. eg:

```powershell
	ISOLocation = 'D:\ISOs\VyOS-1.1.8-amd64.iso'
```

## Azure VPN Lab
There are few options when building the Azure lab. Your Options are:

  _Option A_: **Step 3A. Build Azure Basic S2S.ps1** <-- Sets up a very basic azure S2S VPN , no hub or spoke configurations. 

  _Option B_: **Step 3B-1. Build Azure Advanced S2S - Region 1.ps1** <--Sets up a more complex Azure S2S VPN with hub and spoke design. Run script: 

  _Option C_: Sets up a duplicate Azure S2S VPN on another region and connects the two. Run scripts [in order]:
  
1. **Step 3B-1. Build Azure Advanced S2S - Region 1.ps1**
2. **Step 3B-2. Build Azure Advanced S2S - Region 2.ps1**
3. **Step 3B-3. Connect Azure Advanced S2S Regions.ps1**

### Azure VM

The last thing to do is setup a VM in your Azure lab without Public IP and connect to it from you hyper-V vm. This is a good test to see if your VPN is connected

To setup a VM, run the script corresponding to the type of Azure VPN you set up prior:


  _Option 1_: **Step 4A. Build Azure VM.ps1**

  _Option 2_: **Step 4B-1. Build Azure VM - Region 1.ps1**

  _Option 3_ Run scripts:

1. **Step 4B-1. Build Azure VM - Region 1.ps1**
2. **Step 4B-2. Build Azure VM - Region 2.ps1**

If all went well, the vyos router will connect each Azure site.

**INFO**: The _vyos_setup_ folder are templates and samples of known working configurations. Can be used to compare configurations in your VyOS router

## References

- [Create a VPN Gateway and add a Site-to-Site connection using PowerShell](https://docs.microsoft.com/en-us/azure/vpn-gateway/scripts/vpn-gateway-sample-site-to-site-powershell)
- [Hub-spoke network topology with shared services in Azure](https://docs.microsoft.com/en-us/azure/architecture/reference-architectures/hybrid-networking/shared-services)
- [VYOS Releases](http://packages.vyos.net/iso/release/)
- [How to install VyOS Router/Appliance on Hyper-V](http://luisrato.azurewebsites.net/2014/06/17/)
- [Azure BGP Network Triangulation](https://azure-in-action.blog/2017/01/04/azure-bgp-network-triangulation-from-home/)
- [Route-Based Site-to-Site VPN to Azure (BGP over IKEv2/IPsec)](https://vyos.readthedocs.io/en/latest/appendix/examples/azure-vpn-bgp.html)
- [Configuring Azure Site-to-Site connectivity using VyOS Behind a NAT – Part 3](http://www.lewisroberts.com/2015/07/17/configuring-azure-site-to-site-connectivity-using-vyos-behind-a-nat-part-3/)
 - [BUILD A HYBRID CLOUD LAB INTO MICROSOFT AZURE WITH VYOS](https://bretty.me.uk/build-a-hybrid-cloud-lab-into-microsoft-azure-with-vyos/)
 - [VyOS Site-to-Site](https://vyos.readthedocs.io/en/latest/vpn/site2site_ipsec.html)
