# Change log for AzureSite2SiteVPNLab

## 1.3.8 - January 12, 2022

- fixed static routes on VyOS; was using local subnets and changed to azure subnets
- adding ability for multiple spoke subnets
- updated readme; added concept image and known issues
## 1.3.7 - December 7, 2021

- add VyOS size check; fixes issue if download fails or is stopped. Also check local ISOs folder in root of script
- Added secondary tunnel to advanced VPN; to connect to both vNets.
- Fixed VyOS prompted issue for external IP; change response variables to be unique
- added lab name to file name to provide multiple router saves
- added function for retrieving public IP; found some networks don't allow ipinfo.io request; loop through multiple URLs in attempt to grab public IP
- Added Autoshutdown enablement to existing network script for VMs
- Added the ability to Attach an NSG to vNet in existing networks; secures the vNet to only allow 3389
- Fixed adding rules and subnet to NSG for existing network; need to update vNet after gateway addition

## 1.3.7 - December 2, 2021

- Added additional VyOS script commands; added NAT protocols for CIDR addresses
- Added RemovePublicIP parameter in Step 3C script; since VPN is place; public IP no longer need to be attached to VMs

## 1.3.6 - December 1, 2021

- Formatted normal output to use white; provides better User experience if user is using custom PowerShell colors.
- Added additional VyOS script commands; reset and fixes VPN peers and added static routes
- Added autocompleter to parameters in Step 3C script; provides Azure values

## 1.3.5 - November 30, 2021

- Change logging names; better output with scripts
- Add prompt for VM name if found; allows dynamic VM creations
- Changed hyper-v subnet names to reflex lab prefix; easier management when multiple network exists.
- Add Hyper-V VM build script; still in Beta
- Added script for existing networks; provides a means to deploy site-to-site VPN to any existing virtual network in azure.

## 1.3.4 - November 28, 2021

- Fixed VM deployments; increments name if ran again, keeps same storage account, fixes autoshutdown, and prompts for valid password (if required)
- Fixed stop on failures; missing break after each failure
- Emphasized errors with read background and black text.
- Added Sharedkey during reset. Fixes VPN connection
- Added DNS and DHCP option in config; auto builds values for azure VM
- Added vyatta CMD function; provides a in prompt CMD's remotely if needed
- BETA: working support for latest VyOS image

## 1.3.3 - November 27, 2021

- Simplified Azure connection; removed Connect-AzureEnvironment function; fixed azure subscription selection
- Added requires check for each script; Fixed require module statement for Az; must specify individual modules.
- Forced VyOS scripts output always even if automatic; named same as log
- Fixed VyOS LAN switch attachments; created more than needed when similar named networks existed
- Changed resources to lowercase; easier readability in Azure
- Fixed VyOS reset function; disabled function for region 2
- Fixed SSH keygen process; less password prompts

## 1.3.2 - November 26, 2021

- Added VPN check after rerun; allows script to fix the connection is ran again
- updated output to be cleaner; easier to view status during output
- Standardized configs naming using literal strings.
- Added VyOS ISO downloader; only downloads if iso path is invalid

## 1.3.1 - November 23, 2021

- Scripts can now be ran multiple times without breaking something; checks if resources exists
- Fixed RSA keygen when file exists already; outputs RSA value instead of redoing it.
- Added more logic and output for VyOS router creation; check when VM is booted
- Fixed hyper-v networking: kept building same subnets over and over and checks for config paths
- Added SSH-keygen check; need for SSH shared key

## 1.3.0 - November 22, 2021

- Resolved Basic S2S script issues; using wrong gateway subnets and configs
- Added output for monitoring script run steps
- Fixed Azure connect script; gateway subnet was failing.
- Add Linux format function; ensures VyOS scripts are formatted correctly for VyOS router
- Added dynamic config; auto build networking for each type of build
- Added simple networking function; builds subnets for gateway and hub/spoke
- included CHANGELOG.md

## 1.2.0 - November 18, 2021

- Added manual process back as optional; found automation script does not work 100%; defaults to manual process instead

## 1.1.5 - September 3, 2021

- Added VyOS automation; SSH and SCP VyOS script to router and automates setup

## 1.1.0 April 22, 2021

- Added disclaimer
- added vNet peering for cross tenant communication

## 1.0.1 - Jun 10, 2020

- Added readme info; provided each scripts details
- Change config default values; instead of leaving them blank add <> to them


## 1.0.0 - May 20, 2020

- initial build
