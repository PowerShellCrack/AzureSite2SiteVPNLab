#SETUP VPN TO AZURE
#http://www.lewisroberts.com/2015/07/17/configuring-azure-site-to-site-connectivity-using-vyos-behind-a-nat-part-3/
#https://bretty.me.uk/build-a-hybrid-cloud-lab-into-microsoft-azure-with-vyos/

# Enter configuration mode.
configure

set vpn ipsec ike-group azure-ike key-exchange ikev2
set vpn ipsec ike-group azure-ike lifetime 28800
set vpn ipsec ike-group azure-ike proposal 1 encryption aes256
set vpn ipsec ike-group azure-ike proposal 1 hash sha1
set vpn ipsec ike-group azure-ike proposal 1 dh-group 2

set vpn ipsec ike-group azure-ike dead-peer-detection action 'restart'
set vpn ipsec ike-group azure-ike dead-peer-detection interval '15'
set vpn ipsec ike-group azure-ike dead-peer-detection timeout '30'
set vpn ipsec ike-group azure-ike ikev2-reauth 'yes'
set vpn ipsec ike-group azure-ike key-exchange 'ikev2'
set vpn ipsec ike-group azure-ike lifetime '28800'
set vpn ipsec ike-group azure-ike proposal 1 dh-group '2'
set vpn ipsec ike-group azure-ike proposal 1 encryption 'aes256'
set vpn ipsec ike-group azure-ike proposal 1 hash 'sha1'

set vpn ipsec esp-group AZURE compression 'disable'
set vpn ipsec esp-group AZURE lifetime '3600'
set vpn ipsec esp-group AZURE mode 'tunnel'
set vpn ipsec esp-group AZURE pfs 'dh-group2'
set vpn ipsec esp-group AZURE proposal 1 encryption 'aes256'
set vpn ipsec esp-group AZURE proposal 1 hash 'sha1'

set vpn ipsec ipsec-interfaces interface eth0

set vpn ipsec site-to-site peer 52.170.82.8 description 'Azure Basic VPN'
set vpn ipsec site-to-site peer 52.170.82.8 authentication mode 'pre-shared-secret'
set vpn ipsec site-to-site peer 52.170.82.8 authentication pre-shared-secret 'bB8u6Tj60uJL2RKYR0OCKLew8df:gwsud3bRTTVRK1'
set vpn ipsec site-to-site peer 52.170.82.8 connection-type respond 
set vpn ipsec site-to-site peer 52.170.82.8 default-esp-group 'azure'
set vpn ipsec site-to-site peer 52.170.82.8 ike-group 'azure-ike'
set vpn ipsec site-to-site peer 52.170.82.8 local-address '192.168.1.36'

set vpn ipsec site-to-site peer 52.170.82.8 tunnel 1 local prefix '10.100.0.0/16'
set vpn ipsec site-to-site peer 52.170.82.8 tunnel 1 remote prefix '10.1.0.0/16'
show vpn ipsec sa

set nat source rule 5 source address '10.100.0.0/16'
set nat source rule 5 destination address '10.1.0.0/16'
set nat source rule 5 outbound-interface 'eth0'
set nat source rule 5 'exclude'
set nat source rule 20 source address '10.1.0.0/16'
set nat source rule 20 destination address '10.100.0.0/16'
set nat source rule 20 outbound-interface 'eth0'
set nat source rule 20 'exclude'
set nat source rule 10 outbound-interface eth0
set nat source rule 10 source address 10.100.1.0/24
set nat source rule 10 translation address masquerade
set nat source rule 11 outbound-interface eth0
set nat source rule 11 source address 10.100.2.0/24
set nat source rule 11 translation address masquerade

set firewall name WAN-to-LOCAL-v4 rule 30 action accept
set firewall name WAN-to-LOCAL-v4 rule 30 protocol udp
set firewall name WAN-to-LOCAL-v4 rule 30 destination port 500
set firewall name WAN-to-LOCAL-v4 rule 30 state new enable

set firewall name WAN-to-LOCAL-v4 rule 40 action accept
set firewall name WAN-to-LOCAL-v4 rule 40 source address 10.1.0.0/16

#Save Configure
commit
save

#Exit configure
exit

#reboot
reboot