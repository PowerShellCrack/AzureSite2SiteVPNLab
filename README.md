# Hybrid Lab Setup using Hyper-V and Azure Site-2-Site VPN

## Prereqs

- Azure subscription (VSE or Trial will work)
- Windows OS that will support Hyper-V (UEFI or TPM not needed)
- Edge router with S2S IPSEC VPN capabilities __OR__ vyOS Router
  - This lab uses a virtual router called VyOS. The ISO can be found [**here**](https://s3.amazonaws.com/s3-us.vyos.io/vyos-1.1.8-amd64.iso). The script will auto download it for you as well
- Partial knowledge with Powershell
- SSH utility with SCP and SSH-Keygen. These are installed with Git for Windows. You can get it [**here**](https://git-scm.com/downloads)

## Scripts

- **configs.ps1**. <-- This script is used to answer script values; linked to all scripts
  - Rename _configs.example.ps1_ to **configs.ps1**
  - _Advanced:_ Be sure to look through the hashtables and change anything you feel is necessary.
  - All scripts use this as an answer file for each setup. The answers are loaded in hashtable format and all of the required values are generated dynamically or will be prompted during execution
  - There are few things you should change on the top section:

```powershell
$LabPrefix = 'contoso' #identifier for names in lab

$domain = 'lab.contoso.com' #just a name for now (no DC install....yet)

$Email = '' #used only in autoshutdown (for now)

#this is used to configure default username and password on Azure VM's
$VMAdminUser = 'xAdmin'
$VMAdminPassword = '<password>'

#NOTE: Make sure ALL subnets do not overlap!
$OnPremSubnetCIDR = '10.120.0.0/16' #Always use /16
$OnPremSubnetCount = 2

$RegionSiteAId = 'SiteA'
$AzureSiteAHubCIDR = '10.23.0.0/16' #Always use /16
$AzureSiteASpokeCIDR = '10.22.0.0/16' #Always use /16

$RegionSiteBId = 'SiteB'
$AzureSiteBHubCIDR = '10.33.0.0/16' #Always use /16
$AzureSiteBSpokeCIDR = '10.32.0.0/16' #Always use /16

$DHCPLocation = '<ip, server, or router>'   #defaults to dhcp server not on router; assumes dhcp is on a server
                                            #if <router> is specified, dhcp server will be enabled but a full DHCP scope will be built for each subnets automatically (eg. 10.22.1.1-10.22.1.255)

$DNSServer = '<ip, ip addresses (comma delimitated), router>'   #if not specified; defaults to fourth IP in spoke subnet scope (eg. 10.22.1.4). This would be Azure's first available ip for VM
                                                                # if <router> is specified; google ip 8.8.8.8 will be used since no dns server exist on router

$HyperVVMLocation = '<default>' #Leave as <default> for auto detect
$HyperVHDxLocation = '<default>' #Leave as <default> for auto detect

$VyosIsoPath = '<default>' #Add path (eg. 'E:\ISOs\VyOS-1.1.8-amd64.iso') or use <latest> to get the latest vyos ISO (this is still in BETA)
                  #If path left blank or default, it will attempt to download the supported versions (1.1.8)

$UseBGP = $false # not required for VPN, but can help. Costs more.
#https://docs.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-bgp-overview

#used in step 5
$AzureVnetToVnetPeering = @{
    SiteASubscriptionID = '<SubscriptionAID>'
    SiteATenantID= '<TenantAID>'
    SiteBSubscriptionID = '<SubscriptionBID>'
    SiteBTenantID = '<TenantBID>'
}

#Uses Git, SSH and SCP to build vyos router
# 99% automated; but 90% successful
$RouterAutomationMode = $True
```

- **library.ps1** <-- Custom functions used for Azure automation
- **network.ps1** <-- Custom functions used to generating network subnets
- **vyos.ps1** <-- Custom functions used for vyos automation

**NOTE**: All logs are written using a transcript to the logs folder including vyos scripts

## Setup Hyper-V Lab

**NOTE:** be sure to run these scripts with elevated rights.

1. run script: **Step 1. Setup HyperV for Lab.ps1**

This script does a few things:
- Installs hyper-v (if needed)
- Sets up networking (external and internal interfaces)
- Check to see if device is on wifi and attaches that to external; otherwise it used physical

### Setup VYOS Router (in Hyper-V)

1. run script: **Step 2. Setup Vyos Router in Lab.ps1**

This script does a few things:
- Downloads the vyos ISO if path not found (downloads to user downloads folder or temp folder)
- Setups the vyos basic configuration (manual steps required)
- Established SSH to vyos and attempts auto confougrations for lan network
  - You will be prompted to make configurations to the router. Also once SSH is established the script will generate RSA key to auto logon.
   This is a temporary process because vyos does not save authorized_keys. if login is successful, it will auto configure the vyos router for you otherwise you will be presented with a copy/paste configurations.

Change the value to something like this:
```powershell
	$VyosIsoPath = 'D:\ISOs\VyOS-1.1.8-amd64.iso'
```

## Azure VPN Lab
There are few options when building the Site2Site VPN lab:

  _Option A_: **Step 3A. Build Azure Basic S2S.ps1** <-- Sets up a very basic azure S2S VPN , no hub and spoke configurations.

  _Option B_: **Step 3B-1. Build Azure Advanced S2S - Region 1.ps1** <--Sets up a more complex Azure S2S VPN with hub and spoke design. Also run scripts:

1. **Step 3B-2. Build Azure Advanced S2S - Region 2.ps1** <-- Optional if you want to setup a second site
2. **Step 3B-3. Connect Azure Advanced S2S Regions.ps1** <-- Only Required if a second site is setup

  _Option C_: **Step 3C. Attach Azure S2S to Existing Network.ps1** <-- Connect to an existing Azure network. You must run it like this:

<span style="background-color:Yellow;">**NOTE: If connected to Azure, hit tab for the virtualNetwork and Resourcegroup values to iterate through existing Azure resources. </span>
```powershell
  & '.\Step 3C. Attach Azure S2S to Existing Network.ps1' -Prefix MECMCBLAB -ResourceGroup mecmcb-lab-rg -vNet mecmcblab-vnet -DnsIp 10.0.0.4 -RemovePublicIps -EnableVMAutoShutdown -AttachNsg -Force
```

<span style="background-color:Red;">**IMPORTANT**: All scripts list above can be ran multiple times! If ran a second time, it will check all configurations and attempt to repair and issues. this can be useful when public IP has changed on home network</span>

If all went well, the vyos router will connect each Azure site.
### Azure VM

The last thing to do is setup a VM in your Azure lab without Public IP and connect to it from you hyper-V vm. This is a good test to see if your VPN is connected

To setup a VM, run the script corresponding to the type of Azure VPN you set up prior:


  _Option 1_: **Step 4A-1. Build Azure VM.ps1**

  _Option 2_: **Step 4B-1. Build Azure VM - Region 1.ps1**

  _Option 3_ Run scripts:

1. **Step 4B-1. Build Azure VM - Region 1.ps1**
2. **Step 4B-2. Build Azure VM - Region 2.ps1**

_BETA_: **Step 4A-2. Build Hyper-V VM.ps1** <-- Sets up a VM in Hyper-V.

<span style="background-color:Yellow;">**IMPORTANT**: All scripts list above can be ran multiple times! If ran a second time, The script with create another VM incrementing the name automatically or you can specify an name like so:</span>
```powershell
	& '.\Step 4A. Build Azure VM.ps1' -VMName 'contoso-dc1'
```

**INFO**: The _vyos_setup_ folder are templates and samples of known working configurations. Can be used to compare configurations in your VyOS router

## References

- [Create a VPN Gateway and add a Site-to-Site connection using PowerShell](https://docs.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-create-site-to-site-rm-powershell)
- [Site-to-Site Powershell Sample script](https://docs.microsoft.com/en-us/azure/vpn-gateway/scripts/vpn-gateway-sample-site-to-site-powershell)
- [Hub-spoke network topology with shared services in Azure](https://docs.microsoft.com/en-us/azure/architecture/reference-architectures/hybrid-networking/shared-services)
- [VYOS Releases](http://packages.vyos.net/iso/release/)
- [How to install VyOS Router/Appliance on Hyper-V](http://luisrato.azurewebsites.net/2014/06/17/)
- [Azure BGP Network Triangulation](https://azure-in-action.blog/2017/01/04/azure-bgp-network-triangulation-from-home/)
- [Route-Based Site-to-Site VPN to Azure (BGP over IKEv2/IPsec)](https://vyos.readthedocs.io/en/latest/appendix/examples/azure-vpn-bgp.html)
- [Configuring Azure Site-to-Site connectivity using VyOS Behind a NAT – Part 3](http://www.lewisroberts.com/2015/07/17/configuring-azure-site-to-site-connectivity-using-vyos-behind-a-nat-part-3/)
 - [BUILD A HYBRID CLOUD LAB INTO MICROSOFT AZURE WITH VYOS](https://bretty.me.uk/build-a-hybrid-cloud-lab-into-microsoft-azure-with-vyos/)
 - [VyOS Site-to-Site](https://vyos.readthedocs.io/en/latest/vpn/site2site_ipsec.html)
