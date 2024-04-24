# Hybrid Lab Setup using Hyper-V and Azure Site-2-Site VPN

A hybrid lab setup combines on-premises infrastructure with cloud resources to create a flexible and scalable environment for testing, development, to **mimic** production workloads. Azure Site-to-Site VPN extends your on-premises network to Azure, enabling secure and seamless communication between your on-premises environment and Azure resources.

**In this setup:**

1. Hyper-V: These script will install and configure Hyper-V on your "on-premises host" or workstation to create and manage virtual machines. These VMs can mimic various server roles, applications, or network configurations that you want to test or deploy.
2. Azure Site-to-Site VPN: These script will configure a Site-to-Site VPN connection between your on-premises network and Azure Virtual Network. This VPN connection ensures that your on-premises resources can securely communicate with Azure resources over the Internet as if they are part of the same network.

**Benefits of this setup include:**

- **Scalability**: Easily add or remove virtual machines in Hyper-V or Azure based on your needs without significant hardware investments.
- **Flexibility**: Test different scenarios or configurations in a sandboxed environment without affecting your production infrastructure.
- **Security**: Securely connect your on-premises network to Azure using Site-to-Site VPN, ensuring data encryption and compliance with organizational security policies.

Overall, a hybrid lab setup using Hyper-V and Azure Site-to-Site VPN provides a powerful and flexible solution for testers looking to simulate a true on-premises and cloud resources effectively.

The script will setup whats in red:
![Network](/.images/network.png)


You can then use this network setup to build your environment. Here is an example:
![Concept](/.images/concept.png)

## Supported Environments

- Azure Commercial
- Azure Government High

## Prereqs

- 1 or 2 Azure subscriptions (VSE or Trial will work)
- Windows OS that will support Hyper-V
- Internet connectivity
- Home router to issue IP to virtual router (vYOS)
- SSH utility with SCP and SSH-Keygen. These are installed with _Git for Windows_. You can get it [**here**](https://git-scm.com/downloads)
- Azure PowerShell Modules installed (specifically  **Az.Accounts, Az.Resources ,Az.Network, Az.Storage, Az.Compute**)
- Partial knowledge with PowerShell and Azure modules

## Scripts

- **configs.ps1**. <-- This script is used to answer script values; linked to all scripts
  - Make sure you edit the variables in the top section under the _General Configurations_
  - _Advanced:_ Recommend you don't make changed in this section
  - All scripts use this as an answer file for each setup. The answers are loaded in hashtable format and all of the required values are generated dynamically or will be prompted during execution
  
## Helper Functions

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
   > This is a temporary process because VyOS does not save authorized_keys. if login is successful, it will auto configure the VyOS router for you otherwise you will be presented with a copy/paste configurations.
  - If ssh does not work, you can manually run the scripts within the VM. Scripts are exported to log folder for each step

- Change the value to something like this:

```powershell
$VyOSIsoPath = 'D:\ISOs\VyOS-1.1.8-amd64.iso'
```

## Azure VPN Lab
There are few options when building the Site2Site VPN lab:

### Option A: Simple Network

- **Step 3A. Build Azure Basic S2S.ps1** <-- Sets up a very basic azure S2S VPN , no hub and spoke configurations.

### Option B: Hub and Spoke

- **Step 3B-1. Build Azure Advanced S2S - TenantA.ps1** <--Sets up a more complex Azure S2S VPN with hub and spoke design. Also run scripts:

  1. **Step 3B-2. Build Azure Advanced S2S - TenantB.ps1** <-- Optional if you want to setup a second site
  2. **Step 3B-3. Connect Azure Advanced S2S Tenants.ps1** <-- Only Required if a second site is setup

### Option C: Existing network

- **Step 3C. Attach Azure S2S to Existing Network.ps1** <-- Connect to an existing Azure network. You must run it like this:

<span style="background-color:Orange;">**NOTE: If connected to Azure, hit tab for the virtualNetwork and Resourcegroup values to iterate through existing Azure resources. </span>
```powershell
  & '.\Step 3C. Attach Azure S2S to Existing Network.ps1' -Prefix MECMCBLAB -ResourceGroup mecmcb-lab-rg -vNet mecmcblab-vnet -DnsIp 10.0.0.4 -RemovePublicIps -EnableVMAutoShutdown -AttachNsg -Force
```

<span style="background-color:Red;">**IMPORTANT**: All scripts list above can be ran multiple times! If ran a second time, it will check all configurations and attempt to repair and issues. this can be useful when public IP has changed on home network</span>

### Validate connection

If all went well, the VyOS router will connect each Azure site. You can check it two ways:

1. Run command on router:

```cmd
show vpn ipsec sa
```

2. Go to Azure Portal --> Local Network Gateways --> Click on gateway --> Connections

### Azure VM

The last thing to do is setup a VM in your Azure lab without Public IP and connect to it from you hyper-V vm. This is a good test to see if your VPN is connected

To setup a VM, run the script corresponding to the type of Azure VPN you set up prior:


  _Option 1_: **Step 4A-1. Build Azure VM.ps1**

  _Option 2_: **Step 4B-1. Build Azure VM - TenantA.ps1**

  _Option 3_ Run scripts:

1. **Step 4B-1. Build Azure VM - TenantA.ps1**
2. **Step 4B-2. Build Azure VM - TenantB.ps1**

_BETA_: **Step 4C. Build Hyper-V VM.ps1** <-- Sets up a VM in Hyper-V (not unattended)

<span style="background-color:Orange;">**IMPORTANT**: All scripts list above can be ran multiple times! If ran a second time, The script with create another VM incrementing the name automatically or you can specify an name like so:</span>
```powershell
	& '.\Step 4A. Build Azure VM.ps1' -VMName 'contoso-dc1'
```

**INFO**: The _VyOS_setup_ folder are templates and samples of known working configurations. Can be used to compare configurations in your VyOS router

## Known Issues

- Some devices have reduce network quality with hyper-v's external switch connecting to WiFi adapter. Recommend using physical adapter if possible
- Some ISP's (especially hotels) don't allow public IP to pulled from web crawlers such as http://ipinfo.io/json; this can be an issue with when the script is setting up Site-2-Site-VPN
- Some ISP's may not allow VPN traffic; no know work around for this
- After Site 2 Site VPN is created; step that check for connectivity may show _unknown) or _not connected_; this may be due to Azure's graph api call not updating immediately. Recommend manual check
    - Go to Azure Portal --> Local Network Gateways --> Click on new gateway --> Connections
- VyOS router will remove it trusted ssh host list on each reboot. This is by design and will require login for each script implementation; looking for alternate method to resolve this.
- There are known issues with the PowerShell ISE interface during VyOS configurations; Recommend running with Powershell console or VScode.
- Running this script over a LAN network may not work. Copy local before running
- Hyper-V VM setup script will require PowerSHell 5.1 for Chassis setting configurations

## Not Supported

- These scripts have not been tested on Azure clouds other than what is stated in supported section
- Target multiple subscriptions per tenant (such as [Mission LZ](https://github.com/Azure/missionlz))
- Vnet peering between Azure and Azure Gov is NOT supported

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

# DISCLAIMER
This Sample Code is provided for the purpose of illustration only and is not
intended to be used in a production environment.  THIS SAMPLE CODE AND ANY
RELATED INFORMATION ARE PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER
EXPRESSED OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE IMPLIED WARRANTIES OF
MERCHANTABILITY AND/OR FITNESS FOR A PARTICULAR PURPOSE.  We grant You a
nonexclusive, royalty-free right to use and modify the Sample Code and to
reproduce and distribute the object code form of the Sample Code, provided
that You agree: (i) to not use Our name, logo, or trademarks to market Your
software product in which the Sample Code is embedded; (ii) to include a valid
copyright notice on Your software product in which the Sample Code is embedded;
and (iii) to indemnify, hold harmless, and defend Us and Our suppliers from and
against any claims or lawsuits, including attorneys’ fees, that arise or result
from the use or distribution of the Sample Code.

This posting is provided "AS IS" with no warranties, and confers no rights. Use
of included script samples are subject to the terms specified
at https://www.microsoft.com/en-us/legal/copyright.