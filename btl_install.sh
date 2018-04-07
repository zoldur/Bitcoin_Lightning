#!/bin/bash

TMP_FOLDER=$(mktemp -d)
CONFIG_FILE="Bitcoin_Lightning.conf"
BTL_DAEMON="/usr/local/bin/Bitcoin_Lightningd"
BTL_REPO="https://github.com/Bitcoinlightning/Bitcoin-Lightning/releases/download/v1.1.0.0/Bitcoin_Lightning-Daemon-1.1.0.0.tar.gz"
BTL_ZIP=$(echo $BTL_REPO | awk -F'/' '{print $NF}')
DEFAULTBTLPORT=17127
DEFAULTBTLUSER="btl"
NODEIP=$(curl -s4 icanhazip.com)


RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'


function compile_error() {
if [ "$?" -gt "0" ];
 then
  echo -e "${RED}Failed to compile $@. Please investigate.${NC}"
  exit 1
fi
}


function checks() {
if [[ $(lsb_release -d) != *16.04* ]]; then
  echo -e "${RED}You are not running Ubuntu 16.04. Installation is cancelled.${NC}"
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}$0 must be run as root.${NC}"
   exit 1
fi

if [ -n "$(pidof $BTL_DAEMON)" ] || [ -e "$BTL_DAEMOM" ] ; then
  echo -e "${GREEN}\c"
  read -e -p "Bitcoin-Lightning is already installed. Do you want to add another MN? [Y/N]" NEW_BTL
  echo -e "{NC}"
  clear
else
  NEW_BTL="new"
fi
}

function prepare_system() {

echo -e "Preparing the system to install Bitcoin-Lightning master node."
apt-get update >/dev/null 2>&1
DEBIAN_FRONTEND=noninteractive apt-get update > /dev/null 2>&1
DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -y -qq upgrade >/dev/null 2>&1
apt install -y software-properties-common >/dev/null 2>&1
echo -e "${GREEN}Adding bitcoin PPA repository"
apt-add-repository -y ppa:bitcoin/bitcoin >/dev/null 2>&1
echo -e "Installing required packages, it may take some time to finish.${NC}"
apt-get update >/dev/null 2>&1
apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" make software-properties-common \
build-essential libtool autoconf libssl-dev libboost-dev libboost-chrono-dev libboost-filesystem-dev libboost-program-options-dev \
libboost-system-dev libboost-test-dev libboost-thread-dev sudo automake git wget pwgen curl libdb4.8-dev bsdmainutils libdb4.8++-dev \
libminiupnpc-dev libgmp3-dev ufw >/dev/null 2>&1
clear
if [ "$?" -gt "0" ];
  then
    echo -e "${RED}Not all required packages were installed properly. Try to install them manually by running the following commands:${NC}\n"
    echo "apt-get update"
    echo "apt -y install software-properties-common"
    echo "apt-add-repository -y ppa:bitcoin/bitcoin"
    echo "apt-get update"
    echo "apt install -y make build-essential libtool software-properties-common autoconf libssl-dev libboost-dev libboost-chrono-dev libboost-filesystem-dev \
libboost-program-options-dev libboost-system-dev libboost-test-dev libboost-thread-dev sudo automake git pwgen curl libdb4.8-dev \
bsdmainutils libdb4.8++-dev libminiupnpc-dev libgmp3-dev ufw"
 exit 1
fi

clear
}

function compile_node() {
  echo -e "Downloading BTL binaru files."
  cd $TMP_FOLDER
  wget -q $BTL_REPO
  tar xvzf $BTL_ZIP >/dev/null 2>&1
  chmod +x ./Bitcoin_Lightningd
  cp -a  ./Bitcoin_Lightningd /usr/local/bin 
  cd ~ >/dev/null 2>&1
  rm -rf $TMP_FOLDER
  clear
}

function enable_firewall() {
  echo -e "Installing fail2ban and setting up firewall to allow ingress on port ${GREEN}$BTLPORT${NC}"
  ufw allow $BTLPORT/tcp comment "BTL MN port" >/dev/null
  ufw allow $[BTLPORT-1]/tcp comment "BTL RPC port" >/dev/null
  ufw allow ssh comment "SSH" >/dev/null 2>&1
  ufw limit ssh/tcp >/dev/null 2>&1
  ufw default allow outgoing >/dev/null 2>&1
  echo "y" | ufw enable >/dev/null 2>&1
}

function configure_systemd() {
  cat << EOF > /etc/systemd/system/$BTLUSER.service
[Unit]
Description=BTL service
After=network.target

[Service]
Type=forking

ExecStart=$BTL_DAEMON -daemon -conf=$BTLFOLDER/$CONFIG_FILE -datadir=$BTLFOLDER
ExecStop=$BTL_DAEMON -conf=$BTLFOLDER/$CONFIG_FILE -datadir=$BTLFOLDER stop

User=$BTLUSER
Group=$BTLUSER

Restart=always
PrivateTmp=true
TimeoutStopSec=60s
TimeoutStartSec=10s
StartLimitInterval=120s
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  sleep 3
  systemctl start $BTLUSER.service
  systemctl enable $BTLUSER.service

  if [[ -z "$(ps axo user:15,cmd:100 | egrep ^$BTLUSER | grep $BTL_DAEMON)" ]]; then
    echo -e "${RED}BTL is not running${NC}, please investigate. You should start by running the following commands as root:"
    echo -e "${GREEN}systemctl start $BTLUSER.service"
    echo -e "systemctl status $BTLUSER.service"
    echo -e "less /var/log/syslog${NC}"
    exit 1
  fi
}

function ask_port() {
read -p "Bitcoin-Lightning Port: " -i $DEFAULTBTLPORT -e BTLPORT
: ${BTLPORT:=$DEFAULTBTLPORT}
}

function ask_user() {
  read -p "Bitcoin-Lightning user: " -i $DEFAULTBTLUSER -e BTLUSER
  : ${BTLUSER:=$DEFAULTBTLUSER}

  if [ -z "$(getent passwd $BTLUSER)" ]; then
    USERPASS=$(pwgen -s 12 1)
    useradd -m $BTLUSER
    echo "$BTLUSER:$USERPASS" | chpasswd

    BTLHOME=$(sudo -H -u $BTLUSER bash -c 'echo $HOME')
    DEFAULTBTLFOLDER="$BTLHOME/.Bitcoin_Lightning"
    read -p "Configuration folder: " -i $DEFAULTBTLFOLDER -e BTLFOLDER
    : ${BTLFOLDER:=$DEFAULTBTLFOLDER}
    mkdir -p $BTLFOLDER
    chown -R $BTLUSER: $BTLFOLDER >/dev/null
  else
    clear
    echo -e "${RED}User exits. Please enter another username: ${NC}"
    ask_user
  fi
}

function check_port() {
  declare -a PORTS
  PORTS=($(netstat -tnlp | awk '/LISTEN/ {print $4}' | awk -F":" '{print $NF}' | sort | uniq | tr '\r\n'  ' '))
  ask_port

  while [[ ${PORTS[@]} =~ $BTLPORT ]] || [[ ${PORTS[@]} =~ $[BTLPORT-1] ]]; do
    clear
    echo -e "${RED}Port in use, please choose another port:${NF}"
    ask_port
  done
}

function create_config() {
  RPCUSER=$(pwgen -s 8 1)
  RPCPASSWORD=$(pwgen -s 15 1)
  cat << EOF > $BTLFOLDER/$CONFIG_FILE
rpcuser=$RPCUSER
rpcpassword=$RPCPASSWORD
rpcallowip=127.0.0.1
rpcport=$[BTLPORT-1]
listen=1
server=1
daemon=1
port=$BTLPORT
EOF
}

function create_key() {
  echo -e "Enter your ${RED}Masternode Private Key${NC}. Leave it blank to generate a new ${RED}Masternode Private Key${NC} for you:"
  read -e BTLKEY
  if [[ -z "$BTLKEY" ]]; then
  su $BTLUSER -c "$BTL_DAEMON -conf=$BTLFOLDER/$CONFIG_FILE -datadir=$BTLFOLDER"
  sleep 5
  if [ -z "$(ps axo user:15,cmd:100 | egrep ^$BTLUSER | grep $BTL_DAEMON)" ]; then
   echo -e "${RED}Bitcoin-Lightning server couldn't start. Check /var/log/syslog for errors.{$NC}"
   exit 1
  fi
  BTLKEY=$(su $BTLUSER -c "$BTL_DAEMON -conf=$BTLFOLDER/$CONFIG_FILE -datadir=$BTLFOLDER masternode genkey")
  su $BTLUSER -c "$BTL_DAEMON -conf=$BTLFOLDER/$CONFIG_FILE -datadir=$BTLFOLDER stop"
fi
}

function update_config() {
  sed -i 's/daemon=1/daemon=0/' $BTLFOLDER/$CONFIG_FILE
  cat << EOF >> $BTLFOLDER/$CONFIG_FILE
maxconnections=256
masternode=1
masternodeaddr=$NODEIP:$BTLPORT
masternodeprivkey=$BTLKEY
addnode=104.238.148.195:17127
addnode=207.148.68.114:17127
addnode=104.156.227.16:17127
addnode=134.119.181.141:17127
addnode=108.61.117.137:17127
addnode=134.119.181.141:17127
addnode=89.47.166.126:17127
EOF
  chown -R $BTLUSER: $BTLFOLDER >/dev/null
}

function important_information() {
 echo
 echo -e "================================================================================================================================"
 echo -e "Bitcoin-Lightning Masternode is up and running as user ${GREEN}$BTLUSER${NC} and it is listening on port ${GREEN}$BTLPORT${NC}."
 echo -e "${GREEN}$BTLUSER${NC} password is ${RED}$USERPASS${NC}"
 echo -e "Configuration file is: ${RED}$BTLFOLDER/$CONFIG_FILE${NC}"
 echo -e "Start: ${RED}systemctl start $BTLUSER.service${NC}"
 echo -e "Stop: ${RED}systemctl stop $BTLUSER.service${NC}"
 echo -e "VPS_IP:PORT ${RED}$NODEIP:$BTLPORT${NC}"
 echo -e "MASTERNODE PRIVATEKEY is: ${RED}$BTLKEY${NC}"
 echo -e "Please check Bitcoin-Lightning is running with the following command: ${GREEN}systemctl status $BTLUSER.service${NC}"
 echo -e "================================================================================================================================"
}

function setup_node() {
  ask_user
  check_port
  create_config
  create_key
  update_config
  enable_firewall
  configure_systemd
  important_information
}


##### Main #####
clear

checks
if [[ ("$NEW_BTL" == "y" || "$NEW_BTL" == "Y") ]]; then
  setup_node
  exit 0
elif [[ "$NEW_BTL" == "new" ]]; then
  prepare_system
  compile_node
  setup_node
else
  echo -e "${GREEN}Bitcoin-Lightning already running.${NC}"
  exit 0
fi
