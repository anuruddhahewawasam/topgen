#
# Fedora GreyBox VM server
# (Gabriel L. Somlo <glsomlo at cert.org>, 2015)
#
text
url --url http://dl.fedoraproject.org/pub/fedora/linux/releases/22/Server/x86_64/os/
keyboard --vckeymap=us --xlayouts='us'
lang en_US.UTF-8
firewall --disabled
timezone America/New_York --isUtc
firstboot --disable
xconfig --startxonboot # for core-gui

authconfig --enableshadow --passalgo=sha512

# force default exercise password:
rootpw --plaintext 'tartans@1'

# create user admin (lxdm hates root logins, and core prefers lxde over mate):
user --name='admin' --password='tartans@1'

# set host name (no reverse DNS - install behind NAT):
network --hostname greybox.topgen.info

# services:
services --disabled=abrtd,avahi_daemon --enabled=sendmail

ignoredisk --only-use=vda
bootloader --location=mbr --boot-drive=vda
zerombr
clearpart --all --initlabel --drives=vda

part /boot --fstype=ext4 --recommended
part pv.0 --size=1 --grow
volgroup vg.0 --pesize=4096 pv.0
logvol swap --fstype=swap --name=swap --vgname=vg.0 --recommended
logvol / --fstype=ext4 --name=root --vgname=vg.0 --size=1 --grow


repo --name=Everything --baseurl=http://dl.fedoraproject.org/pub/fedora/linux/releases/22/Everything/x86_64/os/
repo --name=Updates --baseurl=http://dl.fedoraproject.org/pub/fedora/linux/updates/22/x86_64/
# FIXME: replace with official repository before publication (topgen, core-*)
repo --name=GLS --baseurl=http://mirror.ini.cmu.edu/gls/22/x86_64/


%packages
# bare-bones Fedora install:
@core
@mail-server
@standard
@system-tools
expect
inotify-tools
iperf
logwatch
minicom
sipcalc
wireshark

# basic graphical lxde desktop (for core-gui):
@base-x # for lxde-desktop (core-gui)
@lxde-desktop # for core-gui
dejavu-sans-mono-fonts # for lxde-desktop (core-gui)
-xscreensaver* # lxde pulls them in, and annoyingly starts them by default

# web clients for troubleshooting topgen:
lynx
firefox

# required (but not explicitly via rpm) by core:
quagga

gls-release # FIXME: move to an official repository before publication
topgen
core-daemon
core-gui
%end


%post

# update packages:
dnf -y update

# fix up 'dir' alias (for root only, not sure system-wide is appropriate):
echo -e "\nalias dir='ls -Alh --color=auto'" >> /root/.bashrc

# fix up how color-ls handles directories (normal color, bold type):
sed -i 's/^DIR.*/DIR 01/' /etc/DIR_COLORS*

# audit craps all over the system log (BZ 1227379)
cat > /etc/rc.d/rc.local <<- "EOT"
	#!/bin/sh

	# F22 audit craps all over system log (BZ 1227379)
	auditctl -e 0
	EOT
chmod 755 /etc/rc.d/rc.local


# remove xscreensaver-* (BZ 1199868, should be fixed in F23)
rpm -e $(rpm -qa | grep xscreensaver)


### TopGen & GreyBox Setup
#


# configure local DNS to use 8.8.8.8 and 8.8.4.4 (either real or in-game)
#

# leave /etc/resolv.conf unmanaged by NetworkManager
sed -i '/^\[main\]/a dns=none' /etc/NetworkManager/NetworkManager.conf
# replace all nameservers in resolv.conf "google cache" addresses:
sed -i '/^nameserver/d' /etc/resolv.conf
cat > /etc/resolv.conf <<- "EOT"
	nameserver 8.8.4.4
	nameserver 8.8.8.8
	EOT


# configure Quagga for TopGen (announce default route):
#

declare -a DFLTRT=($(ip route show | grep ^default))
DFLGWY=${DFLTRT[2]}
DEVICE=${DFLTRT[4]}
ADRPFX=$(ip addr show dev $DEVICE | grep 'inet ' | awk '{print $2}')
IPADDR=${ADRPFX%/*}

cat > /etc/quagga/zebra.conf <<- EOT
	! zebra.conf generated by TopGen/GreyBox kickstart install

	hostname topgen-zebra

	! failure to properly list all interfaces (particularly loopback)
	! may result in strange behavior should BGP attempt to redistribute
	! connected loopback secondary /32 routes !!!

	interface lo
	  description loopback
	interface $DEVICE
	  ip address $ADRPFX

	! NOTE: Edit the $DEVICE IP address to match your topology !!!
	EOT

cat > /etc/quagga/bgpd.conf <<- EOT
	! bgpd.conf generated by TopGen/GreyBox kickstart install

	hostname topgen-bgpd

	router bgp 6483
	  bgp router-id $IPADDR
	  neighbor $DFLGWY remote-as 7018
	  neighbor $DFLGWY default-originate
	  neighbor $DFLGWY distribute-list 10 in
	access-list 10 deny any

	! NOTE: In this example, we have:
	!  topgen:      AS # 6483,  IPaddr $IPADDR
	!  peer_router: AS # 7018,  IPaddr $DFLGWY
	!
	! When cloning topgen, ensure the following:
	!  1. IP addresses are updated to match your topology
	!  2. the AS numbers MUST differ !!!
	!     (if they don't, the peer_router MAY NOT use or re-advertise
	!      our default to its other neighbors !!!)
	EOT


# mark all network interfaces unmanaged (except the default)
# (NOTE: using $DEVICE computed above for the default route)

for NETDEV in $(ls -1 /sys/class/net | grep -v lo | grep -v $DEVICE); do
	echo 'NM_CONTROLLED=no' >> /etc/sysconfig/network-scripts/ifcfg-$NETDEV
done


# prepare NGINX for TopGen:
#

# global optimizations:
sed -i '/^events {/ r /dev/stdin' /etc/nginx/nginx.conf <<- "EOT"
	    use epoll;
	    multi_accept on;
	EOT

# comment out default server block:
sed -i '/^    server {/,/^    }/s/^/#/' /etc/nginx/nginx.conf


# NOTE: topgen content to be either restored manually or scraped in-place
#        to /var/lib/topgen/...

# auto-start greybox core topoloy if available:
# (copy /usr/share/doc/topgen/contrib/greybox.imn to /etc/topgen, and customize)
#
cat >> /etc/rc.d/rc.local <<- "EOT"

	# start GreyBox topology in CORE, if available:
	[ -s /etc/topgen/topgen.imn ] &&
	  su -l admin -c 'core-gui --batch /etc/topgen/topgen.imn'
	EOT

%end
