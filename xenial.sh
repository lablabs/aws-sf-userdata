#!/bin/bash

ME=$(basename "$0")
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

readonly PACKAGES_INSTALL=("jq" "awscli")

readonly NET_CONF_FILE_PATH='/etc/network/interfaces.d/51-static-interface.cfg'
readonly DHCP_CONF_FILE_PATH='/etc/dhcp/dhclient-enter-hooks.d/restrict-default-gw'
readonly STATIC_VOLUME_NAMES=( '/dev/xvdz' '/dev/nvme1n1' )

readonly DATA_DIR='/data'
readonly LOG_FILE='/var/log/ll-bootstrap.out'

INSTANCE_ID=''
REGION=''
DYNAMIC_IP=''
SUBNET_ID=''
SUBNET_CIDR_BLOCK=''
SUBNET_WITHOUT_MASK=''
SUBNET_GW=''
SUBNET_MASK=''
STATIC_IP=''
STATIC_VOLUME=''
STATIC_INTERFACE_NAME=''
DYNAMIC_INTERFACE_NAME=''
SUBNET_FULL_MASK=''

log_info() {
  echo "$(date -I'seconds')|${ME}|info| ${1}" | tee -a $LOG_FILE
}

log_err() {
  echo "$(date -I'seconds')|${ME}|error| ${1}" >&2 | tee -a $LOG_FILE
  exit 1
}

get_local_ip() {
  echo $(hostname -I | awk '{print $1}')
}

get_local_ip() {
  echo $(hostname -I | awk '{print $1}')
}

set_vars() {
  INSTANCE_ID=$(curl -s 169.254.169.254/latest/meta-data/instance-id)
  REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region)

  DYNAMIC_IP=$(get_local_ip)
  log_info "DYNAMIC_IP: ${DYNAMIC_IP}"

  SUBNET_ID=$(aws --region $REGION ec2 describe-instances \
    --instance-ids $INSTANCE_ID \
    | jq -r '.Reservations[0].Instances[0].SubnetId')
  log_info "SUBNET_ID: ${SUBNET_ID}"
  [[ -z "$SUBNET_ID" ]] && log_err "'SUBNET_ID' var could not be set"

  SUBNET_CIDR_BLOCK=$(aws --region $REGION ec2 describe-subnets --subnet-ids $SUBNET_ID | jq -r '.Subnets[0].CidrBlock')
  log_info "SUBNET_CIDR_BLOCK: ${SUBNET_CIDR_BLOCK}"
  [[ -z "$SUBNET_CIDR_BLOCK" ]] && log_err "'SUBNET_CIDR_BLOCK' var could not be set"

  SUBNET_WITHOUT_MASK=$(echo $SUBNET_CIDR_BLOCK | awk -F'/' '{print $1}')
  SUBNET_GW=$(echo $SUBNET_WITHOUT_MASK | sed 's/0$/1/')
  SUBNET_MASK=$(echo $SUBNET_CIDR_BLOCK | awk -F'/' '{print $2}')

  STATIC_IP=$(aws --region $REGION ec2 describe-instances \
    --instance-ids $INSTANCE_ID \
    | jq -r --arg local_ip "${DYNAMIC_IP}" \
    '.Reservations[0].Instances[0].NetworkInterfaces[] | select(.PrivateIpAddress!=$local_ip).PrivateIpAddress')
  log_info "STATIC_IP: ${STATIC_IP}"
  [[ -z "$STATIC_IP" ]] && log_err "'STATIC_IP' var could not be set"

  STATIC_INTERFACE_NAME="$(ip -o link show | awk '{print $2,$9}' | grep -v 'lo' | grep 'DOWN' | awk -F':' '{print $1}')"
  log_info "STATIC_INTERFACE_NAME: ${STATIC_INTERFACE_NAME}"
  [[ -z "$STATIC_INTERFACE_NAME" ]] && log_err "'STATIC_INTERFACE_NAME' var could not be set"

  DYNAMIC_INTERFACE_NAME="$(ip -o link show | awk '{print $2,$9}' | grep -v 'lo' | grep 'UP' | awk -F':' '{print $1}')"
  log_info "DYNAMIC_INTERFACE_NAME: ${DYNAMIC_INTERFACE_NAME}"
  [[ -z "$DYNAMIC_INTERFACE_NAME" ]] && log_err "'DYNAMIC_INTERFACE_NAME' var could not be set"

  SUBNET_FULL_MASK="$(ifconfig $DYNAMIC_INTERFACE_NAME | awk '/Mask:/{ print $4;} ' | awk -F':' '{print $2}')"
  log_info "SUBNET_FULL_MASK: ${SUBNET_FULL_MASK}"
  [[ -z "$SUBNET_FULL_MASK" ]] && log_err "'SUBNET_FULL_MASK' var could not be set"
}

setup_dhcp() {
  cat <<EOF > $DHCP_CONF_FILE_PATH
case \${interface} in
  eth0)
    ;;
  *)
    unset new_routers
    ;;
esac
EOF
}

setup_network() {
  cat <<EOF > $NET_CONF_FILE_PATH
auto ${STATIC_INTERFACE_NAME}
iface ${STATIC_INTERFACE_NAME} inet static
address ${STATIC_IP}
netmask ${SUBNET_FULL_MASK}

# Gateway configuration
up ip route add default via ${SUBNET_GW} dev ${STATIC_INTERFACE_NAME} table 1000
up ip route add default via ${SUBNET_GW}

# Routes and rules
up ip route add ${STATIC_IP} dev ${STATIC_INTERFACE_NAME} table 1000
up ip rule add from ${STATIC_IP} lookup 1000
EOF
  log_info "'${NET_CONF_FILE_PATH}' file generated"
  log_info "Running 'systemctl restart networking'"
  systemctl restart networking
}

setup_data_dir() {
  mkdir -p $DATA_DIR
  eval "$(blkid -o udev $STATIC_VOLUME)"
  if [[ ${ID_FS_TYPE} == "ext4" ]]; then
    log_info "Filesystem ext4 has been found on the volume"
  else
    log_info "Formating the volume"
    mkfs.ext4 $STATIC_VOLUME
  fi
  log_info "Mounting the volume"
  mount $STATIC_VOLUME $DATA_DIR
}

install_packages() {
  log_info "Running apt update ..."
  apt update
  log_info "Installing packages"
  for pkg in "${PACKAGES_INSTALL[@]}"; do
    log_info "${pkg}"
    apt install -yq $pkg
  done
}

install_packages

# init checks
# Check static volume device
TRY=0
MAX_TRIES=5
SLEEP=5

while true; do
  STATIC_VOLUME=$(ls "${STATIC_VOLUME_NAMES[@]}" 2> /dev/null)
  if [ "$(echo $STATIC_VOLUME | wc -l)" == "1" ];then
    log_info "Static volume has been found"
    break
  fi
  log_info "'${STATIC_VOLUME_NAMES[@]}' could not be found"
  log_info "Trying again in ${SLEEP} secs ..."
  TRY=$((TRY+1))
  [[ $TRY -lt $MAX_TRIES ]] || log_err "Exiting ..."
  sleep $SLEEP
done

set_vars
setup_dhcp
setup_network
setup_data_dir

log_info 'finish'
