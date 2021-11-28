# Change log for AzureSite2SiteVpnLab



## 1.3.4 - November 28, 2021

- Added dns and dhcp option in config; auto builds values for azure vm
- Added vyatta cmd function; provides a in prompt cmd's remotely if needed
- BETA: working support for latest vyos image

## 1.3.3 - November 27, 2021

- Simplified Azure connection; removed Connect-AzureEnvironment function; fixed azure subscription selection
- Added requires check for each script; Fixed require module statement for Az; must specify individual modules.
- Forced vyos scripts output always even if automatic; named same as log
- Fixed Vyos lan switch attachments; created more than needed when similar named networks existed
- Changed resources to lowercase; easier readability in Azure
- Fixed vyos reset function; disabled function for region 2
- Fixed ssh keygen process; less password prompts

## 1.3.2 - November 26, 2021

- Added vpn check after rerun; allows script to fix the connection is ran again
- updated output to be cleaner; easier to view status during output
- Standardized configs naming using literal strings.
- Added vyos ISO downloader; only downloads if iso path is invalid

## 1.3.1 - November 23, 2021

- Scripts can now be ran multiple times without breaking something; checks if resources exists
- Fixed rsa keygen when file exists already; outputs rsa value instead of redoing it.
- Added more logic and output for VYOS router creation; check when vm is booted
- Fixed hyper-v networking: kept building same subnets over and over and checks for config paths
- Added ssh-keygen check; need for ssh shared key

## 1.3.0 - November 22, 2021

- Resolved Basic S2S script issues; using wrong gateway subnets and configs
- Added output for monitoring script run steps
- Fixed Azure connect script; gateway subnet was failing.
- Add Linux format function; ensures vyos scripts are formatted correctly for vyos router
- Added dynamic config; auto build networking for each type of build
- Added simple networking function; builds subnets for gateway and hub/spoke
- included CHANGELOG.md

## 1.2.0 - November 18, 2021

- Added manual process back as optional; found automation script does not work 100%; defaults to manual process instead

## 1.1.5 - September 3, 2021

- Added vyos automation; ssh and scp vyos script to router and automates setup

## 1.1.0 April 22, 2021

- Added disclaimer
- added vnet peering for cross tenant communication

## 1.0.1 - Jun 10, 2020

- Added readme info; provided each scripts details
- Change config default values; instead of leaving them blank add <> to them


## 1.0.0 - May 20, 2020

- initial build
