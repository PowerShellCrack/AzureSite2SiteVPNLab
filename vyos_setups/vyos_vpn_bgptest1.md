# vyos.readthedocs.io/en/latest/appendix/examples/azure-vpn-bgp.html

## Enter configuration mode
configure


# Define the remote peering address
# Configure the IKE and ESP settings to match a subset of those supported by Azure:
set vpn ipsec esp-group AZURE-ESP-POLICY compression 'disable'
set vpn ipsec esp-group AZURE-ESP-POLICY lifetime '3600'
set vpn ipsec esp-group AZURE-ESP-POLICY mode 'tunnel'
set vpn ipsec esp-group AZURE-ESP-POLICY pfs 'dh-group2'
set vpn ipsec esp-group AZURE-ESP-POLICY proposal 1 encryption 'aes256'
set vpn ipsec esp-group AZURE-ESP-POLICY proposal 1 hash 'sha1'

set vpn ipsec ike-group AZURE-IKE-POLICY dead-peer-detection action 'restart'
set vpn ipsec ike-group AZURE-IKE-POLICY dead-peer-detection interval '15'
set vpn ipsec ike-group AZURE-IKE-POLICY dead-peer-detection timeout '30'
set vpn ipsec ike-group AZURE-IKE-POLICY ikev2-reauth 'yes'
set vpn ipsec ike-group AZURE-IKE-POLICY key-exchange 'ikev2'
set vpn ipsec ike-group AZURE-IKE-POLICY lifetime '28800'
set vpn ipsec ike-group AZURE-IKE-POLICY proposal 1 dh-group '2'
set vpn ipsec ike-group AZURE-IKE-POLICY proposal 1 encryption 'aes256'
set vpn ipsec ike-group AZURE-IKE-POLICY proposal 1 hash 'sha1'

# Enable IPsec on eth0
set vpn ipsec ipsec-interfaces interface 'eth0'


# Configure a VTI with a dummy IP address
set interfaces vti vti1 address '10.100.1.5/24'
set interfaces vti vti1 description 'Azure Tunnel'

# Clamp the VTI’s MSS to 1350 to avoid PMTU blackholes
set firewall options interface vti1 adjust-mss 1350

#Configure the VPN tunnel
set vpn ipsec site-to-site peer 23.101.136.84 authentication id '47.133.227.86'
set vpn ipsec site-to-site peer 23.101.136.84 authentication mode 'pre-shared-secret'
set vpn ipsec site-to-site peer 23.101.136.84 authentication pre-shared-secret 'bB8u6Tj60uJL2RKYR0OCyiGMdds9gaEUs9Q2d3bRTTVRK'
set vpn ipsec site-to-site peer 23.101.136.84 authentication remote-id '23.101.136.84'
set vpn ipsec site-to-site peer 23.101.136.84 connection-type 'respond'
set vpn ipsec site-to-site peer 23.101.136.84 description 'AZURE PRIMARY TUNNEL'
set vpn ipsec site-to-site peer 23.101.136.84 ike-group 'AZURE-IKE-POLICY'
set vpn ipsec site-to-site peer 23.101.136.84 ikev2-reauth 'inherit'
set vpn ipsec site-to-site peer 23.101.136.84 local-address '192.168.1.36'
set vpn ipsec site-to-site peer 23.101.136.84 vti bind 'vti1'
set vpn ipsec site-to-site peer 23.101.136.84 vti esp-group 'AZURE-ESP-POLICY'


#Important: Add an interface route to reach Azure’s BGP listener
set protocols static interface-route 10.1.0.5/32 next-hop-interface vti1

#Configure your BGP settings
set protocols bgp 64499 neighbor 10.1.255.30 remote-as '65515'
set protocols bgp 64499 neighbor 10.1.255.30 address-family ipv4-unicast soft-reconfiguration 'inbound'
set protocols bgp 64499 neighbor 10.1.255.30 timers holdtime '30'
set protocols bgp 64499 neighbor 10.1.255.30 timers keepalive '10'

#Important: Disable connected check
set protocols bgp 64499 neighbor 10.1.255.30 disable-connected-check