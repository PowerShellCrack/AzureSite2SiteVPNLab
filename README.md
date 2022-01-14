# Hybrid Lab Setup using Hyper-V and Azure Site-2-Site VPN


![Concept](/.images/concept.png)
## Prereqs

- 1 or 2 Azure subscriptions (VSE or Trial will work)
- Windows OS that will support Hyper-V (UEFI or TPM not needed)
- Router with S2S IPSEC VPN capabilities __OR__ VyOS Router
  - This lab uses a virtual router called VyOS. The ISO can be found [**here**](https://s3.amazonaws.com/s3-us.VyOS.io/VyOS-1.1.8-amd64.iso). The script will auto download it
- Home router is issuing IP (DHCP)
- SSH utility with SCP and SSH-Keygen. These are installed with Git for Windows. You can get it [**here**](https://git-scm.com/downloads)
- Azure PowerShell Modules installed (specifically  **Az.Accounts, Az.Resources ,Az.Network, Az.Storage, Az.Compute**)
- Partial knowledge with PowerShell

## Scripts

- **configs.ps1**. <-- This script is used to answer script values; linked to all scripts
  - _Advanced:_ You shouldn't have to change to much in the hashtables; recommend only changing the variable at top of script.
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

$DHCPLocation = '<IP, server, or router>'   #defaults to DHCP server not on router; assumes DHCP is on a server
                                            #if <router> is specified, DHCP server will be enabled but a full DHCP scope will be built for each subnets automatically (eg. 10.22.1.1-10.22.1.255)

$DNSServer = '<IP, IP addresses (comma delimitated), router>'   #if not specified; defaults to fourth IP in spoke subnet scope (eg. 10.22.1.4). This would be Azure's first available IP for VM
                                                                # if <router> is specified; google IP 8.8.8.8 will be used since no DNS server exist on router

$HyperVVMLocation = '<default>' #Leave as <default> for auto detect
$HyperVHDxLocation = '<default>' #Leave as <default> for auto detect

$VyOSIsoPath = '<default>' #Add path (eg. 'E:\ISOs\VyOS-1.1.8-amd64.iso') or use <latest> to get the latest VyOS ISO (this is still in BETA)
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

#Uses Git, SSH and SCP to build VyOS router
# 99% automated; but 90% successful
$RouterAutomationMode = $True

```

- **library.ps1** <-- Custom functions used for common automation
- **network.ps1** <-- Custom functions used to generating network subnets
- **VyOS.ps1** <-- Custom functions used for VyOS automation
- **azure.ps1** <-- Custom functions used for Azure automation
- **hyperv.ps1** (not used) <-- developing for hyper-v VM automation

**NOTE**: All logs are written using a transcript to the logs folder including VyOS scripts

## Setup Hyper-V Lab

**NOTE:** be sure to run these scripts with elevated rights.

1. run script: **Step 1. Setup HyperV for Lab.ps1**

This script does a few things:
- Installs hyper-v (if needed)
- Sets up networking (external and internal interfaces)
- Check to see if device is on wifi and attaches that to external; otherwise it used physical

### Setup VyOS Router (in Hyper-V)

1. run script: **Step 2. Setup VyOS Router in Lab.ps1**

This script does a few things:
- Downloads the VyOS ISO if path not found (downloads to user downloads folder or temp folder)
- Setups the VyOS basic configuration (manual steps required)
- Established SSH to VyOS and attempts auto configurations for LAN network
  - You will be prompted to make configurations to the router. Also once SSH is established the script will generate RSA key to auto logon.
   This is a temporary process because VyOS does not save authorized_keys. if login is successful, it will auto configure the VyOS router for you otherwise you will be presented with a copy/paste configurations.

Change the value to something like this:
```powershell
	$VyOSIsoPath = 'D:\ISOs\VyOS-1.1.8-amd64.iso'
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

If all went well, the VyOS router will connect each Azure site.
### Azure VM

The last thing to do is setup a VM in your Azure lab without Public IP and connect to it from you hyper-V vm. This is a good test to see if your VPN is connected

To setup a VM, run the script corresponding to the type of Azure VPN you set up prior:


  _Option 1_: **Step 4A-1. Build Azure VM.ps1**

  _Option 2_: **Step 4B-1. Build Azure VM - Region 1.ps1**

  _Option 3_ Run scripts:

1. **Step 4B-1. Build Azure VM - Region 1.ps1**
2. **Step 4B-2. Build Azure VM - Region 2.ps1**

_BETA_: **Step 4A-2. Build Hyper-V VM.ps1** <-- Sets up a VM in Hyper-V (not unattended)

<span style="background-color:Yellow;">**IMPORTANT**: All scripts list above can be ran multiple times! If ran a second time, The script with create another VM incrementing the name automatically or you can specify an name like so:</span>
```powershell
	& '.\Step 4A. Build Azure VM.ps1' -VMName 'contoso-dc1'
```

**INFO**: The _VyOS_setup_ folder are templates and samples of known working configurations. Can be used to compare configurations in your VyOS router

## Known Issues

- Some devices have reduce network quality with hyper-v's external switch connecting to WiFi adapter. Recommend using physical adapter if possible
- Some ISP's (especially hotels) don't allow public IP to pulled from web crawlers such as http://ipinfo.io/json; this could be an issue with setting up Site-2-Site-VPN
- Some ISP's may not allow VPN traffic; no know work around for this
- These scripts have not been tested with Azure Gov or other Azure community clouds
- After Site 2 Site VPN is created; step that check for connectivity may show _unknown) or _not connected_; this may be due to Azure's graph api call not updating immediately. Recommend manual check
- VyOS router will remove it trusted ssh host list on each reboot. This is by design and will require login for each script implementation; looking for alternate method to resolve this
## References

- [Create a VPN Gateway and add a Site-to-Site connection using PowerShell](https://docs.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-create-site-to-site-rm-powershell)
- [Site-to-Site Powershell Sample script](https://docs.microsoft.com/en-us/azure/vpn-gateway/scripts/vpn-gateway-sample-site-to-site-powershell)
- [Hub-spoke network topology with shared services in Azure](https://docs.microsoft.com/en-us/azure/architecture/reference-architectures/hybrid-networking/shared-services)
- [VyOS Releases](http://packages.VyOS.net/iso/release/)
- [How to install VyOS Router/Appliance on Hyper-V](http://luisrato.azurewebsites.net/2014/06/17/)
- [Azure BGP Network Triangulation](https://azure-in-action.blog/2017/01/04/azure-bgp-network-triangulation-from-home/)
- [Route-Based Site-to-Site VPN to Azure (BGP over IKEv2/IPsec)](https://VyOS.readthedocs.io/en/latest/appendix/examples/azure-vpn-bgp.html)
- [Configuring Azure Site-to-Site connectivity using VyOS Behind a NAT – Part 3](http://www.lewisroberts.com/2015/07/17/configuring-azure-site-to-site-connectivity-using-VyOS-behind-a-nat-part-3/)
 - [BUILD A HYBRID CLOUD LAB INTO MICROSOFT AZURE WITH VyOS](https://bretty.me.uk/build-a-hybrid-cloud-lab-into-microsoft-azure-with-VyOS/)
 - [VyOS Site-to-Site](https://VyOS.readthedocs.io/en/latest/vpn/site2site_ipsec.html)
