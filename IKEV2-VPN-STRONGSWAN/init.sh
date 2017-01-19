#!/bin/bash
#IKEv2 VPN
#========YOUR SETTINGS========#
#fill in your values before running the script!

#your mail address for Let's Encrypt registration
MAIL={mail}
#you can use your own domain name - it must exists and be pointed to the server's ip before launch
DOMAIN=
#VPN user's credentials
USER={user}
PASS={pass}
#your IP address for SSH access
MYIP={myip}
#=======/YOUR SETTINGS========#

#RedHat repository (on AWS) doesn't include epel-release package, install it form RPM
rpm -i https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm

#Install firewall, let's encrypt certbot and strongswan
yum install firewalld certbot strongswan -y

#config files

#strongswan config
cat <<EOF > /etc/strongswan/ipsec.conf
config setup
  protostack=netkey
  nhelpers=0

conn IKEv2-EAP
  keyexchange=ikev2
  leftid=
  leftcert=fullchain.pem
  leftsubnet=0.0.0.0/0
  right=%any
  rightsourceip=10.0.1.0/24
  rightdns=8.8.8.8
  dpdaction=clear
  dpddelay=30s
  dpdtimeout=1800s
  fragmentation=yes
  auto=add
  rekey=no
  leftsendcert=always
  rightauth=eap-mschapv2
  eap_identity=%identity
EOF

#secrets
cat <<EOF > /etc/strongswan/ipsec.secrets
: RSA privkey.pem
$USER : EAP "$PASS"
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
/usr/bin/certbot renew -q
EOF

chmod a+x /etc/cron.daily/update.sh

#firewall rules
systemctl stop firewalld

#allow access from your IP and from VPN
firewall-offline-cmd --zone=public --add-rich-rule="rule family=ipv4 source address=$MYIP accept"
firewall-offline-cmd --zone=public --add-rich-rule="rule family=ipv4 source address=10.0.1.0/24 accept"

firewall-offline-cmd --zone=public --add-port=500/udp
firewall-offline-cmd --zone=public --add-port=4500/udp
firewall-offline-cmd --zone=public --add-port=443/tcp
firewall-offline-cmd --zone=public --add-port=80/tcp
firewall-offline-cmd --remove-service=ssh
firewall-offline-cmd --zone=public --add-masquerade
firewall-offline-cmd --zone=public --add-interface=eth0

systemctl start firewalld
systemctl enable firewalld

#obtain public IP and register SSL certificate
#if domain isn't defined it will use nip.io service
if [ -z "$DOMAIN" ]
then
  IP=$(curl -s http://tools.lynt.cz/ip.php?raw=ikev2)
  certbot certonly --standalone -n -m $MAIL -d $IP.nip.io --agree-tos
  ln -s /etc/letsencrypt/live/$IP.nip.io/fullchain.pem /etc/strongswan/ipsec.d/certs/fullchain.pem
  ln -s /etc/letsencrypt/live/$IP.nip.io/privkey.pem /etc/strongswan/ipsec.d/private/privkey.pem
  sed -i "s/leftid=.*/leftid=$IP.nip.io/g" /etc/strongswan/ipsec.conf
else
  certbot certonly --standalone -n -m $MAIL -d $DOMAIN --agree-tos
  ln -s /etc/letsencrypt/live/$DOMAIN/fullchain.pem /etc/strongswan/ipsec.d/certs/fullchain.pem
  ln -s /etc/letsencrypt/live/$DOMAIN/privkey.pem /etc/strongswan/ipsec.d/private/privkey.pem
  sed -i "s/leftid=.*/leftid=$DOMAIN/g" /etc/strongswan/ipsec.conf
fi

#download CA and start strongswan
wget https://letsencrypt.org/certs/lets-encrypt-x3-cross-signed.pem -O /etc/strongswan/ipsec.d/cacerts/lets-encrypt-x3-cross-signed.pem

systemctl start strongswan
systemctl enable strongswan
 
