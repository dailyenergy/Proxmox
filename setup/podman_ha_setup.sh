#!/usr/bin/env bash

set -o errexit
set -o errtrace
set -o nounset
set -o pipefail
shopt -s expand_aliases
alias die='EXIT=$? LINE=$LINENO error_exit'
CROSS='\033[1;31m\xE2\x9D\x8C\033[0m'
CHECKMARK='\033[0;32m\xE2\x9C\x94\033[0m'
RETRY_NUM=5
RETRY_EVERY=3
NUM=$RETRY_NUM
trap die ERR
trap 'die "Script interrupted."' INT

function error_exit() {
  trap - ERR
  local DEFAULT='Unknown failure occured.'
  local REASON="\e[97m${1:-$DEFAULT}\e[39m"
  local FLAG="\e[91m[ERROR:LXC] \e[93m$EXIT@$LINE"
  msg "$FLAG $REASON"
  exit $EXIT
}
function msg() {
  local TEXT="$1"
  echo -e "$TEXT"
}

echo -e "${CHECKMARK} \e[1;92m Setting up Container OS... \e[0m"
sed -i "/$LANG/ s/\(^# \)//" /etc/locale.gen
locale-gen >/dev/null
while [ "$(hostname -I)" = "" ]; do
  1>&2 echo -e "${CROSS} \e[1;31m No Network: \e[0m $(date)"
  sleep $RETRY_EVERY
  ((NUM--))
  if [ $NUM -eq 0 ]
  then
    1>&2 echo -e "${CROSS} \e[1;31m No Network After $RETRY_NUM Tries \e[0m"
    exit 1
  fi
done
  echo -e "${CHECKMARK} \e[1;92m Network Connected: \e[0m $(hostname -I)"

echo -e "${CHECKMARK} \e[1;92m Updating Container OS... \e[0m"
apt-get update &>/dev/null
apt-get -qqy upgrade &>/dev/null

echo -e "${CHECKMARK} \e[1;92m Installing Dependencies... \e[0m"
apt-get update &>/dev/null
apt-get -qqy install \
    curl \
    sudo \
    runc &>/dev/null

echo -e "${CHECKMARK} \e[1;92m Installing Podman... \e[0m"
apt-get -y install podman &>/dev/null

echo -e "${CHECKMARK} \e[1;92m Pulling Yacht Image...\e[0m"
podman pull ghcr.io/selfhostedpro/yacht:latest &>/dev/null

echo -e "${CHECKMARK} \e[1;92m Installing Yacht... \e[0m"
podman volume create yacht >/dev/null
podman run -d \
  --name yacht \
  -v /var/run/podman/podman.sock:/var/run/docker.sock \
  -v yacht:/config \
  -v /etc/localtime:/etc/localtime:ro \
  -v /etc/timezone:/etc/timezone:ro \
  -p 8000:8000 \
  selfhostedpro/yacht:latest &>/dev/null

echo -e "${CHECKMARK} \e[1;92m Pulling Home Assistant Image...\e[0m"
podman pull docker.io/homeassistant/home-assistant:stable &>/dev/null

echo -e "${CHECKMARK} \e[1;92m Installing Home Assistant... \e[0m"
podman volume create hass_config >/dev/null
podman run -d \
  --name homeassistant \
  --restart unless-stopped \
  -v /dev:/dev \
  -v hass_config:/config \
  -v /etc/localtime:/etc/localtime:ro \
  -v /etc/timezone:/etc/timezone:ro \
  --net=host \
  homeassistant/home-assistant:stable &>/dev/null

echo -e "${CHECKMARK} \e[1;92m Creating Update Script... \e[0m"
file_path="/root/update.sh"
echo "#!/bin/bash
echo -e '\e[1;33m Pulling New Stable Version... \e[0m'
podman pull docker.io/homeassistant/home-assistant:stable
echo -e '\e[1;33m Stopping Home Assistant... \e[0m'
podman stop homeassistant
echo -e '\e[1;33m Removing Home Assistant... \e[0m'
podman rm homeassistant
echo -e '\e[1;33m Starting Home Assistant... \e[0m'
podman run -d \
  --name homeassistant \
  --restart unless-stopped \
  -v /dev:/dev \
  -v hass_config:/config \
  -v /etc/localtime:/etc/localtime:ro \
  -v /etc/timezone:/etc/timezone:ro \
  --net=host \
  homeassistant/home-assistant:stable
echo -e '\e[1;33m Removing Old Image... \e[0m'
podman image prune -f
echo -e '\e[1;33m Finished Update! \e[0m'" > $file_path
sudo chmod +x /root/update.sh

echo -e "${CHECKMARK} \e[1;92m Customizing LXC... \e[0m"
rm /etc/motd
rm /etc/update-motd.d/10-uname
touch ~/.hushlogin
GETTY_OVERRIDE="/etc/systemd/system/container-getty@1.service.d/override.conf"
mkdir -p $(dirname $GETTY_OVERRIDE)
cat << EOF > $GETTY_OVERRIDE
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud tty%I 115200,38400,9600 \$TERM
EOF
systemctl daemon-reload
systemctl restart $(basename $(dirname $GETTY_OVERRIDE) | sed 's/\.d//')
podman generate systemd \
    --new --name homeassistant \
    > /etc/systemd/system/homeassistant.service 
systemctl enable homeassistant &>/dev/null

echo -e "${CHECKMARK} \e[1;92m Cleanup... \e[0m"
rm -rf /podman_ha_setup.sh /var/{cache,log}/* /var/lib/apt/lists/*
