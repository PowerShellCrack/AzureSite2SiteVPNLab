# Hyper-V Lab Setup with Azure Site 2 Site VPN

## Prereqs

- Azure subscription (VSE or Trial will work)
- Windows OS thats supports Hyper-V
- Edge router with S2S IPSEC VPN capabilities OR vyOS Router
  - This lab uses a virtual router named VyOS. The ISO can be found [**here**](https://downloads.vyos.io/?dir=release/legacy/1.1.8/VyOS-1.1.8-amd64.iso)
- Access to home router and port forwarding
- Partial knowledge with Powershell
- SSH utility such as putty or git cmd. You can get it [**here**](https://git-scm.com/downloads)

## Scripts

- **configs.ps1**. <-- This script is used to answer script values; linked to all scripts
  - Rename _configs.example.ps1_ to **configs.ps1**. 
  - Be sure to look through the hashtables and change anything you feel is necessary.  
  - All the script use this as an answer file for each of the setup. The answers are loaded in hashtable format
  - There are few things you should change or verify the values:

```powershell
    $domain = 'fqdn'
    $LabPrefix = 'domain'
    $UseBGP = $false
    $AzEmail = 'youralias@microsoft.com'
    $AzSubscription = 'Visual Studio Enterprise'
 ```
 
 ```json
    ISOLocation = 'D:\ISOs\VyOS-1.1.8-amd64.iso'
    TimeZone = 'US/Eastern'
    LocationName = 'East US 2'
    LocalAdminUser = ''
    LocalAdminPassword = ''
    ShutdownTimeZone = 'Eastern Standard Time'
    ShutdownTime = '21:00'
```

- **library.ps1** <-- Custom functions used to automate; linked to all scripts
  - Don't change anything in here unless you know what your are doing

**NOTE**: All logs are written using a transcript to the logs folder; just in case you need to troubleshoot powershell errors

## Setup Hyper-V Lab

**NOTE:** be sure to run these scripts with elevated rights.

1. run script: **Step 1. Setup HyperV Lab.ps1**

### Setup VYOS Router (in Hyper-V)

1. run script: **Step 2. Setup Vyos Router in Lab.ps1**
2. The first few steps for the vyos will be manual until SSH is established
   - You will be prompted to make configurations to the router. Also once SSH is established, at the end, you will be presented with a copy/paste configurations.
   - You can use the script to load the vYOS router as long as you change the location to your ISO. eg:

```json
	ISOLocation = 'D:\ISOs\VyOS-1.1.8-amd64.iso'
```

## Azure VPN Lab
There are few options when building the Azure lab. Your Options are:

  _Option A_: **Step 3A. Build Azure Basic S2S.ps1** <-- Sets up a very basic azure S2S VPN , no hub or spoke configurations. 

  _Option B_: **Step 3B-1. Build Azure Advanced S2S - Region 1.ps1** <--Sets up a more complex Azre S2S VPN with hub and spoke design. Run script: 

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

If all went well, you VM will connect to each other.

**INFO**: The _vyos_setup_ folder are templates and samples of known working configurations. Can be used to compare configurations in your VyOS router

## References

- [Create a VPN Gateway and add a Site-to-Site connection using PowerShell](https://docs.microsoft.com/en-us/azure/vpn-gateway/scripts/vpn-gateway-sample-site-to-site-powershell)
- [VYOS Releases](http://packages.vyos.net/iso/release/)
- [How to install VyOS Router/Appliance on Hyper-V](http://luisrato.azurewebsites.net/2014/06/17/)
- [Azure BGP Network Triangulation](https://azure-in-action.blog/2017/01/04/azure-bgp-network-triangulation-from-home/)
- [Route-Based Site-to-Site VPN to Azure (BGP over IKEv2/IPsec)](https://vyos.readthedocs.io/en/latest/appendix/examples/azure-vpn-bgp.html)
- [Configuring Azure Site-to-Site connectivity using VyOS Behind a NAT – Part 3](http://www.lewisroberts.com/2015/07/17/configuring-azure-site-to-site-connectivity-using-vyos-behind-a-nat-part-3/)
 - [BUILD A HYBRID CLOUD LAB INTO MICROSOFT AZURE WITH VYOS](https://bretty.me.uk/build-a-hybrid-cloud-lab-into-microsoft-azure-with-vyos/)
 - [VyOS Site-to-Site](https://vyos.readthedocs.io/en/latest/vpn/site2site_ipsec.html)