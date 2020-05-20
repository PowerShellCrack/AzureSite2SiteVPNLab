# Enter configuration mode.
configure

#CLEAR CONFIGS
delete service dns forwarding
delete service dhcp-server
delete nat source rule 
delete protocols static route 
delete vpn ipsec esp-group
delete vpn ipsec ike-group
delete vpn ipsec ipsec-interfaces
delete vpn ipsec logging
delete vpn ipsec site-to-site
delete vpn

#Save Configure
commit
save

#Exit configure
exit

#reboot
reboot