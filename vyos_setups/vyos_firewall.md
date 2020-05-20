# Enter configuration mode.
configure

set firewall name WAN-to-LAN-v4 default-action drop
set firewall name WAN-to-LAN-v4 rule 10 action accept
set firewall name WAN-to-LAN-v4 rule 10 state established enable
set firewall name WAN-to-LAN-v4 rule 10 state related enable

set firewall name WAN-to-LAN-v4 rule 20 action accept
set firewall name WAN-to-LAN-v4 rule 20 icmp type-name echo-request
set firewall name WAN-to-LAN-v4 rule 20 protocol icmp
set firewall name WAN-to-LAN-v4 rule 20 state new enable

set firewall name WAN-to-LOCAL-v4 default-action drop
set firewall name WAN-to-LOCAL-v4 rule 10 action accept
set firewall name WAN-to-LOCAL-v4 rule 10 state established enable
set firewall name WAN-to-LOCAL-v4 rule 10 state related enable

set firewall name WAN-to-LOCAL-v4 rule 20 action accept
set firewall name WAN-to-LOCAL-v4 rule 20 icmp type-name echo-request
set firewall name WAN-to-LOCAL-v4 rule 20 protocol icmp
set firewall name WAN-to-LOCAL-v4 rule 20 state new enable

set interfaces ethernet eth0 firewall in name WAN-to-LAN-v4
set interfaces ethernet eth0 firewall local name WAN-to-LOCAL-v4

#Save Configure
commit
save

#Exit configure
exit