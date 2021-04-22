# https://azure-in-action.blog/2017/01/04/azure-bgp-network-triangulation-from-home/

# IMPORTANT: Before running each command, replace these items with your environment:
#--------------------------------------------------------------------------
# SharedPSKey --> Azure Virtual Gateway shared key
# GatewayDescription --> Azure First Gateway Description (eg. 'Azure VNet East Gateway')
# a.b.c.d --> Azure Public IP (eg. '52.168.24.110')
# a.0.0.0/8 --> Your Azure CIDR for gateway (eg. '10.0.0.0/8')
# a.b.0.0/16 --> Your local router prefix (eg. '10.100.0.0/16')
# i.j.k.l --> Your local router external interface IP (eg. '192.168.1.36')
# m.n.o.p --> Your physical router local IP (eg. '192.168.1.1')
#----------------------------------------------------------------------------

# Enter configuration mode.
configure

#clear settings
delete vpn
delete protocols

# Set up the IPsec preamble for link Azures gateway
set vpn ipsec esp-group azure compression 'disable'
set vpn ipsec esp-group azure lifetime '3600'
set vpn ipsec esp-group azure mode 'tunnel'
set vpn ipsec esp-group azure pfs 'disable'
set vpn ipsec esp-group azure proposal 1 encryption 'aes256'
set vpn ipsec esp-group azure proposal 1 hash 'sha1'
set vpn ipsec ike-group azure-ike ikev2-reauth 'no'
set vpn ipsec ike-group azure-ike key-exchange 'ikev2'
set vpn ipsec ike-group azure-ike lifetime '10800'
set vpn ipsec ike-group azure-ike proposal 1 dh-group '2'
set vpn ipsec ike-group azure-ike proposal 1 encryption 'aes256'
set vpn ipsec ike-group azure-ike proposal 1 hash 'sha1'

set vpn ipsec ipsec-interfaces interface 'eth0'
set vpn ipsec nat-traversal 'enable'

#Initiate tunnel to Azure East Gateway:
set vpn ipsec site-to-site peer a.b.c.d authentication mode 'pre-shared-secret'
set vpn ipsec site-to-site peer a.b.c.d authentication pre-shared-secret 'SharedPSKey'
set vpn ipsec site-to-site peer a.b.c.d connection-type 'initiate'
set vpn ipsec site-to-site peer a.b.c.d default-esp-group 'azure'
set vpn ipsec site-to-site peer a.b.c.d description 'GatewayDescription'
set vpn ipsec site-to-site peer a.b.c.d ike-group 'azure-ike'
set vpn ipsec site-to-site peer a.b.c.d ikev2-reauth 'inherit'
set vpn ipsec site-to-site peer a.b.c.d local-address 'i.j.k.l'
set vpn ipsec site-to-site peer a.b.c.d tunnel 1 allow-nat-networks 'disable'
set vpn ipsec site-to-site peer a.b.c.d tunnel 1 allow-public-networks 'disable'
set vpn ipsec site-to-site peer a.b.c.d tunnel 1 local prefix 'a.b.0.0/16'
set vpn ipsec site-to-site peer a.b.c.d tunnel 1 remote prefix 'a.0.0.0/8'

set protocols static route 0.0.0.0/0 next-hop m.n.o.p

#Save Configure
commit
save
exit

#check the IPsec tunnels are up:
show vpn ipsec sa

# Create a script that has these commands within:
#/bin/vbash
source /opt/vyatta/etc/functions/script-template
run=/opt/vyatta/bin/vyatta-op-cmd-wrapper

#restart vpn
bash restart vpn