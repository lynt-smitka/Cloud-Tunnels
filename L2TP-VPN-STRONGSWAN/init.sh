#!/bin/bash
#L2TP VPN
#========YOUR SETTINGS========#
#fill in your values before running the script!

#VPN user's credentials
USER={user}
PASS={pass}
#L2TP preshared key
PSK={psk}
#your IP address for SSH access
MYIP={myip}
#=======/YOUR SETTINGS========#

#RedHat repository (on AWS) doesn't include epel-release package, install it form RPM
RELEASE=$(rpm -E %{rhel}) && rpm -i https://dl.fedoraproject.org/pub/epel/epel-release-latest-$RELEASE.noarch.rpm

#Install firewall, let's encrypt certbot and strongswan
yum install firewalld strongswan ppp xl2tpd -y

#config files

#ipsec config
cat <<EOF > /etc/strongswan/ipsec.conf
conn l2tp-ikev1-psk
  authby=secret
  auto=add
  dpdaction=clear
  dpddelay=30
  dpdtimeout=120
  keyingtries=5
  left=%defaultroute
  leftid=%myid
  leftprotoport=17/1701
  pfs=no
  rekey=no
  right=%any
  rightprotoport=17/%any
  rightsubnet=vhost:%priv
  type=transport
EOF

#xl2tpd config
cat <<EOF > /etc/xl2tpd/xl2tpd.conf
[lns default]
ip range = 10.0.1.10-10.0.1.254
local ip = 10.0.1.1
refuse chap = yes
refuse pap = yes
require authentication = yes
name = l2tpd
ppp debug = yes
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF

cat <<EOF > /etc/ppp/options.xl2tpd
ipcp-accept-local
ipcp-accept-remote
require-mschap-v2
ms-dns 8.8.8.8
ms-dns 8.8.4.4
asyncmap 0
auth
hide-password
name l2tpd
proxyarp
lcp-echo-interval 30
lcp-echo-failure 4
mtu 1400
noccp
connect-delay 5000
EOF

#secrets
cat <<EOF > /etc/strongswan/ipsec.secrets
: PSK "$PSK"
EOF

cat <<EOF > /etc/ppp/chap-secrets
# client     server     secret               IP addresses
$USER          l2tpd     $PASS               *
EOF


#allow forwarding a disable rp_filter
cat <<EOF > /etc/sysctl.conf
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.eth0.rp_filter = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
EOF

sysctl -p /etc/sysctl.conf

#yum daily updates + certificates renew
cat <<EOF > /etc/cron.daily/update.sh
#!/bin/bash
/usr/bin/yum -y update
EOF

chmod a+x /etc/cron.daily/update.sh

#missing l2tp_ppp module fix
cat <<EOF > /usr/local/bin/l2tp_ppp_fix.sh
#!/bin/bash
if ! modprobe -q l2tp_ppp; then
  sed -i '/^ExecStartPre/s/^/#/' /usr/lib/systemd/system/xl2tpd.service
  systemctl daemon-reload
fi
EOF



#firewall rules
systemctl stop firewalld

#allow access from your IP and from VPN
firewall-offline-cmd --zone=public --add-rich-rule="rule family=ipv4 source address=$MYIP accept"
firewall-offline-cmd --zone=public --add-rich-rule="rule family=ipv4 source address=10.0.1.0/24 accept"  
firewall-offline-cmd --zone=public --add-port=500/udp
firewall-offline-cmd --zone=public --add-port=4500/udp
firewall-offline-cmd --remove-service=ssh
firewall-offline-cmd --zone=public --add-masquerade
firewall-offline-cmd --zone=public --add-interface=eth0

sh /usr/local/bin/l2tp_ppp_fix.sh

systemctl start xl2tpd strongswan firewalld
systemctl enable xl2tpd strongswan firewalld
 
