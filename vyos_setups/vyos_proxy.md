# Enter configuration mode.
configure

#enable proxy service
set service webproxy listen-address 192.168.0.1

#By default it will listen to port 3128. 
set service webproxy listen-address 192.168.0.1 port 2050

#to disable the transparent proxy on that interface
set service webproxy listen-address 192.168.0.1 disable-transparent