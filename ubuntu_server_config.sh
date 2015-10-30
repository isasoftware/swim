#!/bin/sh
#
# Automatic configuration of IPsec/L2TP VPN server on a Ubuntu or Debian instance. 
# Tested with Ubuntu 14.04 & 12.04 and Debian 8 & 7. This script will also work on
# EC2 instances assuming you have the appropriate ports open in your security group
# (UDP ports 500 & 4500)
#
# Copyright (C) 2015 Dan Pearce
# Based on the work of Lin Song (Copyright 2014) and Thomas Sarlandie (Copyright 2012)
#
# Important Notes:
# For Windows users, a registry change is required to allow connections
# to a VPN server behind NAT. Refer to section "Error 809" on this page:
# https://documentation.meraki.com/MX-Z/Client_VPN/Troubleshooting_Client_VPN

if [ "$(lsb_release -si)" != "Ubuntu" ] && [ "$(lsb_release -si)" != "Debian" ]; then
  echo "Looks like you aren't running this script on a Ubuntu or Debian system."
  exit
fi

if [ "$(id -u)" != 0 ]; then
  echo "Sorry, you need to run this script as root."
  exit
fi

# ================== EDIT BELOW THIS LINE =====================

IPSEC_PSK='AS_SHARED'
PRIVATE_IP='10.0.1.1'
LEFT_EIP='52.20.30.40'
LEFT_SUBNET='{10.0.0.1/32 10.0.0.2/32 10.0.0.3/32}'

RIGHT_IP='155.178.172.1'
RIGHT_SUBNET='{155.178.68.32/27}'

# ================ DO NOT EDIT BELOW THIS LINE ================

# Update package index and install wget, dig (dnsutils) and nano
echo "Updating packages"
apt-get -y update

# Install necessary packages
echo "Installing necessary packages..."
apt-get -y install openswan

# Prepare various config files
cat > /etc/ipsec.conf <<EOF
# /etc/ipsec.conf - Openswan IPsec configuration file

# This file:  /usr/share/doc/openswan/ipsec.conf-sample
#
# Manual:     ipsec.conf.5

version 2.0 # conforms to second version of ipsec.conf specification
	config setup
	dumpdir=/var/run/pluto/
	virtual_private=%v4:10.0.0.0/24,%v4:192.168.0.0/16,%v4:172.16.0.0/12,%v4:25.0.0.0/8,%v6:fd00::/8,%v6:fe80::/10
	oe=off
	protostack=netkey
	nat_traversal=no
	interfaces="%defaultroute"
	plutoopts=" --perpeerlog"
	force_keepalive=yes
	keep_alive=20
	plutostderrlog=/dev/null
	plutodebug=none
	
conn SWIM
	auth=esp
	ike=aes256-sha1;modp1536
	authby=secret
	auto=start
	forceencaps=yes
	pfs=yes
	keyexchange=ike
	rekey=yes
	keyingtries=3
	phase2alg=aes256-sha1;modp1024
	type=tunnel

	left=$PRIVATE_IP
	leftid=$LEFT_EIP
	leftnexthop=%defaultroute
	leftsourceip=$PRIVATE_IP
	leftsubnets=$LEFT_SUBNET

	right=$RIGHT_IP
	rightid=$RIGHT_IP
	rightsubnets=$RIGHT_SUBNET

	dpddelay=10
	dpdtimeout=20
	dpdaction=clear

EOF

cat > /etc/ipsec.secrets <<EOF
$LEFT_EIP		$RIGHT_IP  : PSK "$IPSEC_PSK"

EOF

/bin/cp -f /etc/sysctl.conf /etc/sysctl.conf.old-$(date +%Y-%m-%d-%H:%M:%S) 2>/dev/null
cat > /etc/sysctl.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.eth0.send_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.eth0.accept_redirects = 0

EOF

sudo sysctl -p /etc/sysctl.conf

/bin/cp -f /etc/iptables.rules /etc/iptables.rules.old-$(date +%Y-%m-%d-%H:%M:%S) 2>/dev/null
cat > /etc/iptables.rules <<EOF
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:ICMPALL - [0:0]
-A INPUT -m conntrack --ctstate INVALID -j DROP
-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A INPUT -i lo -j ACCEPT
-A INPUT -p icmp --icmp-type 255 -j ICMPALL
-A INPUT -p udp --dport 67:68 --sport 67:68 -j ACCEPT
-A INPUT -p tcp --dport 22 -j ACCEPT
-A INPUT -p tcp --dport 10000 -j ACCEPT
-A INPUT -p udp -m multiport --dports 500,4500 -j ACCEPT
-A INPUT -p udp --dport 1701 -m policy --dir in --pol ipsec -j ACCEPT
-A INPUT -p udp --dport 1701 -j DROP
-A INPUT -j DROP
-A FORWARD -m conntrack --ctstate INVALID -j DROP
-A FORWARD -i eth+ -o ppp+ -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A FORWARD -i ppp+ -o eth+ -j ACCEPT
-A FORWARD -j DROP
-A ICMPALL -p icmp -f -j DROP
-A ICMPALL -p icmp --icmp-type 0 -j ACCEPT
-A ICMPALL -p icmp --icmp-type 3 -j ACCEPT
-A ICMPALL -p icmp --icmp-type 4 -j ACCEPT
-A ICMPALL -p icmp --icmp-type 8 -j ACCEPT
-A ICMPALL -p icmp --icmp-type 11 -j ACCEPT
-A ICMPALL -p icmp -j DROP
COMMIT
*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s 10.0.0.0/24 -o eth+ -j SNAT --to-source $PRIVATE_IP
COMMIT

EOF

cat > /etc/network/if-pre-up.d/iptablesload <<EOF
#!/bin/sh
/sbin/iptables-restore < /etc/iptables.rules
exit 0
EOF

/bin/cp -f /etc/rc.local /etc/rc.local.old-$(date +%Y-%m-%d-%H:%M:%S) 2>/dev/null
cat > /etc/rc.local <<EOF
#!/bin/sh -e
#
# rc.local
#
# This script is executed at the end of each multiuser runlevel.
# Make sure that the script will "exit 0" on success or any other
# value on error.
#
# In order to enable or disable this script just change the execution
# bits.
#
# By default this script does nothing.
/usr/sbin/service ipsec restart
echo 1 > /proc/sys/net/ipv4/ip_forward
exit 0
EOF

/sbin/sysctl -p
/bin/chmod +x /etc/network/if-pre-up.d/iptablesload
/sbin/iptables-restore < /etc/iptables.rules

/usr/sbin/service ipsec restart


