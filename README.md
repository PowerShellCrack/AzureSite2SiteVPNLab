# Hyper-V Lab Setup for Azure Site 2 Site VPN

## Prereqs
   - Azure subscription (VSE or AIRS will work)
   - Hyper-V VM
   - Edge router with S2S IPSEC VPN capabilties (Virtual or physical)
   - Access to home router and port forwarding
   - Partial knowledge with Powershell
   - ssh utility such as putty or git
 
## Scripts:
**NOTE:** To run each script be sure to run them with elevated rights.
    
 - Be sure to look through the hashtable san dchange anything you feel is necassary. 
	**configs.ps1** <-- Used to answer script values; linked to all scripts
	- All the script use this as an answer file for each of the setup. The answers are loaded in hashtable format
	- There are few things you should change or varify the values:
			$domain = 'fqdn'
			$LabPrefix = 'domain'
			$UseBGP = $false
			$AzEmail = 'youralias@microsoft.com'
			$AzSubscription = 'Visual Studio Enterprise'
			ISOLocation = 'D:\ISOs\VyOS-1.1.8-amd64.iso'
			TimeZone = 'US/Eastern'
			LocationName = 'East US 2'
			LocalAdminUser = ''
			LocalAdminPassword = ''
			ShutdownTimeZone = 'Eastern Standard Time'
			ShutdownTime = '21:00'
			
**library.ps1** <-- Custom functions used to automate; linked to all scripts
	- Don't change anything in here unless you know what your are doing

Also All logs written a transcript to the logs folder. Just in case you need to torubleshoot powershell errors. 

## Hyper-V Lab
 - Install Hyper-V using script: **Step 1. Setup HyperV Lab.ps1**
 - This lab uses a virtual router named VyOS. The ISO can be found here:
	https://downloads.vyos.io/?dir=release/legacy/1.1.8/VyOS-1.1.8-amd64.iso
 - You can use the script to load the vYOS router as long as you change the location to your ISO:
	ISOLocation = *'D:\ISOs\VyOS-1.1.8-amd64.iso'*
 - run script: **Step 2. Setup Vyos Router in Lab.ps1**
	The steps for the vyos will be manual. You will be prompted to make configurations to the router. Also once SSH is established, at the end, you will be presented with a copy/paste configurations. 
			

## Azure VPN Lab
 - There are few options when building the Azure lab.

 - _Option 1_: Sets up a very basic azure S2S VPN , no hub or spoke configurations. 
			Run script: **Step 3A. Build Azure Basic S2S.ps1**
	
 - _Option 2_: Sets up a more complex Azre S2S VPN with hub and spoke design.
			Run script: **Step 3B-1. Build Azure Advanced S2S - Region 1.ps1**
			
 - _Option 3_: Sets up a duplicate Azure S2S VPN on another region and connects the two
	Run script: **Step 3B-1. Build Azure Advanced S2S - Region 1.ps1**
		**Step 3B-2. Build Azure Advanced S2S - Region 2.ps1**
		**Step 3B-3. Connect Azure Advanced S2S Regions.ps1**
	
## Azure VM
 - The last thing to do is setup a VM in your Azure lab without Public IP and connect to it from you hyper-V vm. This is a good test to see if your VPN is connected

To setup a VM, run the script correspondign to the type of Azure VPN you set up:
 - For _Option 1_ Run script: **Step 4A. Build Azure VM.ps1**
 - For _Option 2_ Run script: **Step 4B-1. Build Azure VM - Region 1.ps1**
 - For _Option 3_ Run script: **Step 4B-1. Build Azure VM - Region 1.ps1**
		**Step 4B-2. Build Azure VM - Region 2.ps1**
									   
									   
If all went well, you VM will connect to each other.


INFO: The vyos_setup folder are templates and samples of known working configurations. Can be used to compare configurations in your VyOS router


# References
 - http://packages.vyos.net/iso/release/
 - http://luisrato.azurewebsites.net/2014/06/17/how-to-install-vyos-routerappliance-on-hyper-v-part-1-setup-and-install/
 - http://forum.vyos.net/showthread.php?tid=5326
 - https://azure-in-action.blog/2017/01/04/azure-bgp-network-triangulation-from-home/
 - https://vyos.readthedocs.io/en/latest/appendix/examples/azure-vpn-bgp.html
 - http://www.lewisroberts.com/2015/07/17/configuring-azure-site-to-site-connectivity-using-vyos-behind-a-nat-part-3/
 - https://bretty.me.uk/build-a-hybrid-cloud-lab-into-microsoft-azure-with-vyos/
 - https://vyos.readthedocs.io/en/latest/vpn/site2site_ipsec.html

 	
	


	
