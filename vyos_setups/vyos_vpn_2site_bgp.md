# https://azure-in-action.blog/2017/01/04/azure-bgp-network-triangulation-from-home/

# IMPORTANT: Before running each command, replace these items with your environment:
#--------------------------------------------------------------------------
# SharedPSKey --> Azure Virtual Gateway shared key
# Gateway1Description --> Azure First Gateway Description (eg. 'Azure VNet East Gateway')
# Gateway2Description --> Azure Second Gateway Description (eg. 'Azure VNet West Gateway')
# a.b.c.d --> Azure First Public IP (eg. '52.168.24.110')
# e.f.g.h --> Azure Second Public IP (eg. '40.121.70.7')
# a.0.0.0/8 --> Your Azure CIDR for gateway (eg. '10.0.0.0/8')
# a.b.0.0/16 --> Your local router (eg. '10.100.0.0/16')
# i.j.k.l --> Your local router external interface IP (eg. '192.168.1.36')
# m.n.o.p --> Your local router network gateway (eg. '192.168.1.1')
# q.r.s.t --> Azure First BGN Address (eg. 10.10.200.62')
# u.v.w.x --> Azure Second BGN Address (eg. 10.10.200.62')
# 12345 --> Azure First BGN ASN (eg. '65010')
# 67890 --> Azure Second BGN ASN (eg. '65011')
#----------------------------------------------------------------------------


# Enter configuration mode.
configure

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
set vpn ipsec site-to-site peer a.b.c.d description 'Gateway1Description'
set vpn ipsec site-to-site peer a.b.c.d ike-group 'azure-ike'
set vpn ipsec site-to-site peer a.b.c.d ikev2-reauth 'inherit'
set vpn ipsec site-to-site peer a.b.c.d local-address 'i.j.k.l'
set vpn ipsec site-to-site peer a.b.c.d tunnel 1 allow-nat-networks 'disable'
set vpn ipsec site-to-site peer a.b.c.d tunnel 1 allow-public-networks 'disable'
set vpn ipsec site-to-site peer a.b.c.d tunnel 1 local prefix 'a.b.0.0/16'
set vpn ipsec site-to-site peer a.b.c.d tunnel 1 remote prefix 'a.0.0.0/8'

#Initiate tunnel to Azure West Gateway:
set vpn ipsec site-to-site peer e.f.g.h authentication mode 'pre-shared-secret'
set vpn ipsec site-to-site peer e.f.g.h authentication pre-shared-secret 'SharedPSKey'
set vpn ipsec site-to-site peer e.f.g.h connection-type 'initiate'
set vpn ipsec site-to-site peer e.f.g.h default-esp-group 'azure'
set vpn ipsec site-to-site peer e.f.g.h description 'Gateway2Description'
set vpn ipsec site-to-site peer e.f.g.h ike-group 'azure-ike'
set vpn ipsec site-to-site peer e.f.g.h ikev2-reauth 'inherit'
set vpn ipsec site-to-site peer e.f.g.h local-address 'i.j.k.l'
set vpn ipsec site-to-site peer e.f.g.h tunnel 2 allow-nat-networks 'disable'
set vpn ipsec site-to-site peer e.f.g.h tunnel 2 allow-public-networks 'disable'
set vpn ipsec site-to-site peer e.f.g.h tunnel 2 local prefix 'a.b.0.0/16'
set vpn ipsec site-to-site peer e.f.g.h tunnel 2 remote prefix 'a.0.0.0/8'

#Default route – and blackhole route for BGP and set private ASN number
set protocols static route 0.0.0.0/0 next-hop 'm.n.o.p'
set protocols static route a.b.0.0/16 'blackhole'
set protocols bgp 65168 network 'a.b.0.0/16'

#BGP for Azure East
set protocols bgp 65168 neighbor q.r.s.t ebgp-multihop '8'
set protocols bgp 65168 neighbor q.r.s.t remote-as '12345'
set protocols bgp 65168 neighbor q.r.s.t soft-reconfiguration 'inbound'

#BGP for Azure West
set protocols bgp 65168 neighbor u.v.w.x ebgp-multihop '8'
set protocols bgp 65168 neighbor u.v.w.x remote-as '67890'
set protocols bgp 65168 neighbor u.v.w.x soft-reconfiguration 'inbound'

#check the IPsec tunnels are up:
show vpn ipsec sa

# Create a script that has these commands within:
#/bin/vbash
source /opt/vyatta/etc/functions/script-template
run=/opt/vyatta/bin/vyatta-op-cmd-wrapper
$run restart vpn

# Test if BGP is functioning, run the command:
show ip bgp

#Save Configure
commit
save

#Exit configure
exit