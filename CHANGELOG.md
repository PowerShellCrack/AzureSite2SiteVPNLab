# Change log for AzureSite2SiteVpnLab

## 1.3.1 - November 23, 2021

- Scripts can now be ran multiple times without breaking something
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
