#!/bin/bash

CONTINUE=1
function error { echo "Error : $@"; CONTINUE=0; }
function die { echo "$@" ; exit 1; }
function checkpoint { [ "$CONTINUE" = "0" ] && echo "Unrecoverable errors found, exiting ..." && exit 1; }

OPENVPNDIR="/etc/openvpn"

# Providing defaults values for missing env variables
[ "$CERT_COUNTRY" = "" ]    && export CERT_COUNTRY="US"
[ "$CERT_PROVINCE" = "" ]   && export CERT_PROVINCE="AL"
[ "$CERT_CITY" = "" ]       && export CERT_CITY="Birmingham"
[ "$CERT_ORG" = "" ]        && export CERT_ORG="ACME"
[ "$CERT_EMAIL" = "" ]      && export CERT_EMAIL="nobody@example.com"
[ "$CERT_OU" = "" ]         && export CERT_OU="IT"
[ "$VPNPOOL_NETWORK" = "" ] && export VPNPOOL_NETWORK="10.43.0.0"
[ "$VPNPOOL_CIDR" = "" ]    && export VPNPOOL_CIDR="16"
[ "$REMOTE_IP" = "" ]       && export REMOTE_IP="ipOrHostname"
[ "$REMOTE_PORT" = "" ]     && export REMOTE_PORT="1194"
[ "$PUSHDNS" = "" ]         && export PUSHDNS="169.254.169.250"
[ "$PUSHSEARCH" = "" ]      && export PUSHSEARCH="rancher.internal"

[ "$ROUTE_NETWORK" = "" ]   && export ROUTE_NETWORK="10.42.0.0"
[ "$ROUTE_NETMASK" = "" ]   && export ROUTE_NETMASK="255.255.0.0"

export RANCHER_METADATA_API='push "route 169.254.169.250 255.255.255.255"'
[ "$NO_RANCHER_METADATA_API" != "" ] && export RANCHER_METADATA_API=""


# Checking mandatory variables
for i in AUTH_METHOD
do
    [ "${!i}" = "" ] && error "empty value for variable '$i'"
done

# Checks
[ "${#CERT_COUNTRY}" != "2" ] && error "Certificate Country must be a 2 characters long string only"

checkpoint

env | grep "REMOTE_"

# Saving environment variables

[ -e "$OPENVPNDIR/auth.env" ] && rm "$OPENVPNDIR/auth.env"
env | grep "AUTH_" | while read i
do
    var=$(echo "$i" | awk -F= '{print $1}')
    var_data=$( echo "${!var}" | sed "s/'/\\'/g" )
    echo "export $var='$var_data'" >> $OPENVPNDIR/auth.env
done

env | grep "REMOTE_" | while read i
do
    var=$(echo "$i" | awk -F= '{print $1}')
    var_data=$( echo "${!var}" | sed "s/'/\\'/g" )
    echo "export $var='$var_data'" >> $OPENVPNDIR/remote.env
done

#=====[ Generating server config ]==============================================
VPNPOOL_NETMASK=$(netmask -s $VPNPOOL_NETWORK/$VPNPOOL_CIDR | awk -F/ '{print $2}')

cat > $OPENVPNDIR/server.conf <<- EOF
port 1194
proto tcp
link-mtu 1544
dev tun
ca easy-rsa/keys/ca.crt
cert easy-rsa/keys/server.crt
key easy-rsa/keys/server.key
dh easy-rsa/keys/dh2048.pem
auth SHA1
server $VPNPOOL_NETWORK $VPNPOOL_NETMASK
push "dhcp-option DNS $PUSHDNS"
push "dhcp-option DOMAIN $PUSHSEARCH"
push "route $ROUTE_NETWORK $ROUTE_NETMASK"
$RANCHER_METADATA_API
keepalive 10 120
compress lz4-v2
push "compress lz4-v2"
persist-key
persist-tun
client-to-client
username-as-common-name
verify-client-cert none
script-security 3
auth-user-pass-verify /usr/local/bin/openvpn-auth.sh via-env

EOF

echo $OPENVPN_EXTRACONF |sed 's/\\n/\n/g' >> $OPENVPNDIR/server.conf

#=====[ Generating certificates ]===============================================
if [ ! -d $OPENVPNDIR/easy-rsa ]; then
   # Copy easy-rsa tools to /etc/openvpn
   rsync -avz /usr/share/easy-rsa $OPENVPNDIR/

   cp $OPENVPNDIR/easy-rsa/vars.example $OPENVPNDIR/easy-rsa/vars

    # Configure easy-rsa vars file
   sed -i "s/#set_var EASYRSA_REQ_COUNTRY.*/set_var EASYRSA_REQ_COUNTRY\\t\"$CERT_COUNTRY\"/g" $OPENVPNDIR/easy-rsa/vars
   sed -i "s/#set_var EASYRSA_REQ_PROVINCE.*/set_var EASYRSA_REQ_PROVINCE\\t\"$CERT_PROVINCE\"/g" $OPENVPNDIR/easy-rsa/vars
   sed -i "s/#set_var EASYRSA_REQ_CITY.*/set_var EASYRSA_REQ_CITY\\t\"$CERT_CITY\"/g" $OPENVPNDIR/easy-rsa/vars
   sed -i "s/#set_var EASYRSA_REQ_ORG.*/set_var EASYRSA_REQ_ORG\\t\"$CERT_ORG\"/g" $OPENVPNDIR/easy-rsa/vars
   sed -i "s/#set_var EASYRSA_REQ_EMAIL.*/set_var EASYRSA_REQ_EMAIL\\t\"$CERT_EMAIL\"/g" $OPENVPNDIR/easy-rsa/vars
   sed -i "s/#set_var EASYRSA_REQ_OU.*/set_var EASYRSA_REQ_OU\\t\"$CERT_OU\"/g" $OPENVPNDIR/easy-rsa/vars
   sed -i "s/#set_var EASYRSA_BATCH.*/set_var EASYRSA_BATCH\\t\"1\"/g" $OPENVPNDIR/easy-rsa/vars
   sed -i "s/#set_var EASYRSA_DN.*/set_var EASYRSA_DN\\t\"org\"/g" $OPENVPNDIR/easy-rsa/vars
   sed -i "s/#set_var EASYRSA_REQ_CN.*/set_var EASYRSA_REQ_CN\\t\"$CERT_CN\"/g" $OPENVPNDIR/easy-rsa/vars

   pushd $OPENVPNDIR/easy-rsa
   . ./vars
   ./easyrsa init-pki hard || error "Cannot clean previous keys"
   checkpoint
   ./easyrsa build-ca nopass || error "Cannot build certificate authority"
   checkpoint
   ./easyrsa build-server-full server nopass || error "Cannot create server key"
   checkpoint
   ./easyrsa gen-dh || error "Cannot create dh file"
   checkpoint
   ./easyrsa build-client-full RancherVPNClient nopass
   popd

   # COPY keys to old directory structure
   mkdir -p $OPENVPNDIR/easy-rsa/keys
   openvpn --genkey --secret keys/ta.key
   cp $OPENVPNDIR/easy-rsa/pki/ca.crt $OPENVPNDIR/easy-rsa/keys/
   cp $OPENVPNDIR/easy-rsa/pki/dh.pem $OPENVPNDIR/easy-rsa/keys/dh2048.pem
   cp $OPENVPNDIR/easy-rsa/pki/issued/server.crt $OPENVPNDIR/easy-rsa/keys/
   cp $OPENVPNDIR/easy-rsa/pki/private/server.key $OPENVPNDIR/easy-rsa/keys/

fi

#=====[ Enable tcp forwarding and add iptables MASQUERADE rule ]================
echo 1 > /proc/sys/net/ipv4/ip_forward
iptables-legacy -t nat -F
iptables-legacy -t nat -A POSTROUTING -s $VPNPOOL_NETWORK/$VPNPOOL_NETMASK -j MASQUERADE


/usr/local/bin/openvpn-get-client-config.sh > $OPENVPNDIR/client.conf

echo "=====[ OpenVPN Server config ]============================================"
cat $OPENVPNDIR/server.conf
echo "=========================================================================="


#=====[ Display client config  ]================================================
echo ""
echo "=====[ OpenVPN Client config ]============================================"
echo " To regenerate client config, run the 'openvpn-get-client-config.sh' script "
echo "--------------------------------------------------------------------------"
cat $OPENVPNDIR/client.conf
echo ""
echo "=========================================================================="
#=====[ Starting OpenVPN server ]===============================================
/usr/sbin/openvpn --cd /etc/openvpn --config server.conf
