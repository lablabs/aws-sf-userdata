#!/bin/bash

ME=$(basename "$0")
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

readonly PACKAGES_INSTALL=("jq" "awscli")
readonly AWS_INSTANCE_METADATA_API_VER="2019-10-01"
readonly NET_CONF_FILE_PATH='/etc/netplan/51-ens6.yaml'
readonly SYSTEM_VOLUME_NAMES=( '/dev/xvdz' '/dev/nvme1n1' '/dev/nvme0n1' )

readonly DATA_DIR='/data'
readonly LOG_FILE='/var/log/ll-bootstrap.out'
readonly INIT_SCRIPTS_DIR="${DATA_DIR}/init/scripts"

INSTANCE_ID=''
REGION=''
DYNAMIC_IP=''
SUBNET_ID=''
SUBNET_CIDR_BLOCK=''
SUBNET_WITHOUT_MASK=''
SUBNET_GW=''
SUBNET_MASK=''
STATIC_IP=''
SYSTEM_VOLUMES=''
STATIC_INTERFACE_NAME=''
STATIC_VOLUME=''

log_info() {
  echo "$(date -I'seconds')|${ME}|info| ${1}" | tee -a $LOG_FILE
}

log_err() {
  echo "$(date -I'seconds')|${ME}|error| ${1}" >&2 | tee -a $LOG_FILE
  exit 1
}

set_vars() {
  local instance_identity_document=$(curl -s http://169.254.169.254/${AWS_INSTANCE_METADATA_API_VER}/dynamic/instance-identity/document)
  local instance_mac=$(curl -s http://169.254.169.254/${AWS_INSTANCE_METADATA_API_VER}/meta-data/mac)

  INSTANCE_ID=$(echo $instance_identity_document | jq -r .instanceId)
  REGION=$(echo $instance_identity_document | jq -r .region)

  DYNAMIC_IP=$(echo $instance_identity_document | jq -r .privateIp)
  log_info "DYNAMIC_IP: ${DYNAMIC_IP}"

  SUBNET_ID=$(curl -s "http://169.254.169.254/${AWS_INSTANCE_METADATA_API_VER}/meta-data/network/interfaces/macs/${instance_mac}/subnet-id")
  log_info "SUBNET_ID: ${SUBNET_ID}"
  [[ -z "$SUBNET_ID" ]] && log_err "'SUBNET_ID' var could not be set"

  SUBNET_CIDR_BLOCK=$(curl -s "http://169.254.169.254/${AWS_INSTANCE_METADATA_API_VER}/meta-data/network/interfaces/macs/${instance_mac}/subnet-ipv4-cidr-block")
  log_info "SUBNET_CIDR_BLOCK: ${SUBNET_CIDR_BLOCK}"
  [[ -z "$SUBNET_CIDR_BLOCK" ]] && log_err "'SUBNET_CIDR_BLOCK' var could not be set"

  SUBNET_WITHOUT_MASK=$(echo $SUBNET_CIDR_BLOCK | awk -F'/' '{print $1}')
  SUBNET_GW=$(echo $SUBNET_WITHOUT_MASK | sed 's/0$/1/')
  SUBNET_MASK=$(echo $SUBNET_CIDR_BLOCK | awk -F'/' '{print $2}')

  STATIC_INTERFACE_MAC=$(aws --region $REGION ec2 describe-instances \
    --instance-ids $INSTANCE_ID \
    | jq -r --arg local_ip "${DYNAMIC_IP}" \
    '.Reservations[0].Instances[0].NetworkInterfaces[] | select(.PrivateIpAddress!=$local_ip).MacAddress')
  log_info "STATIC_INTERFACE_MAC: ${STATIC_INTERFACE_MAC}"
  [[ -z "$STATIC_INTERFACE_MAC" ]] && log_err "'STATIC_INTERFACE_MAC' var could not be set"

  STATIC_IP=$(curl -s "http://169.254.169.254/${AWS_INSTANCE_METADATA_API_VER}/meta-data/network/interfaces/macs/${STATIC_INTERFACE_MAC}/local-ipv4s")
  [[ -z "$STATIC_IP" ]] && log_err "'STATIC_IP' var could not be set"

  STATIC_INTERFACE_NAME="$(ip -br -o link | grep "$STATIC_INTERFACE_MAC" | awk '{print $1}')"
  log_info "STATIC_INTERFACE_NAME: ${STATIC_INTERFACE_NAME}"
  [[ -z "$STATIC_INTERFACE_NAME" ]] && log_err "'STATIC_INTERFACE_NAME' var could not be set"
}

setup_network() {
  cat <<EOF > $NET_CONF_FILE_PATH
network:
  version: 2
  renderer: networkd
  ethernets:
    ${STATIC_INTERFACE_NAME}:
      addresses:
       - ${STATIC_IP}/${SUBNET_MASK}
      dhcp4: no
      routes:
       - to: 0.0.0.0/0
         via: ${SUBNET_GW}
         table: 1000
       - to: ${STATIC_IP}
         via: 0.0.0.0
         scope: link
         table: 1000
      routing-policy:
        - from: ${STATIC_IP}
          table: 1000
EOF
  log_info "'${NET_CONF_FILE_PATH}' file generated"
  log_info "Running 'netplan --debug apply'"
  netplan --debug apply
  # We need to restart the interface to fix the order of routes in the default routing table.
  # If we don't do it, the system can't to packets received on DYNAMIC_INTERFACE in the local subnet. Instead of using DYNAMIC_INTERFACE where it received the packets, it uses STATIC_INTERFACE which causes assymetric routing.
  # Example:
  # Wrong order:
  # 172.20.32.0/19 dev ens6 proto kernel scope link src 172.20.48.46
  # 172.20.32.0/19 dev ens5 proto kernel scope link src 172.20.55.60
  # Correct order:
  # 172.20.32.0/19 dev ens5 proto kernel scope link src 172.20.48.46
  # 172.20.32.0/19 dev ens6 proto kernel scope link src 172.20.55.60
  log_info "Restarting '${STATIC_INTERFACE_NAME}' interface"
  sleep 5
  ip link set $STATIC_INTERFACE_NAME down
  sleep 1
  ip link set $STATIC_INTERFACE_NAME up
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

run_init_scripts() {
  log_info "Looking for init scripts ..."
  # Check if scripts directory exists and is not empty
  script_count=`ls -1 "$INIT_SCRIPTS_DIR"/*.sh 2>/dev/null | wc -l`
  if [ $script_count != 0 ]; then
    # Execute every script in directory
    for f in "${INIT_SCRIPTS_DIR}"/*.sh; do
      log_info "Executing ${f} ..."
      bash "$f"
    done
  else
    log_info "No init scripts found ..."
  fi
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
  SYSTEM_VOLUMES=$(ls "${SYSTEM_VOLUME_NAMES[@]}" 2> /dev/null)

  for volume in $(echo $SYSTEM_VOLUMES); do
    eval "$(blkid -o udev $volume)"
    if [[ -z $ID_PART_TABLE_TYPE ]]; then
      STATIC_VOLUME=$volume
    fi
    ID_PART_TABLE_TYPE=""
  done

  if ! [[ -z $STATIC_VOLUME ]]; then
    log_info "Static volume has been found"
    break
  else
    log_info "Static volume could not be found"
    log_info "Trying again in ${SLEEP} secs ..."
    TRY=$((TRY+1))
    [[ $TRY -lt $MAX_TRIES ]] || log_err "Exiting ..."
    sleep $SLEEP
  fi
done

set_vars
setup_network
setup_data_dir
run_init_scripts

log_info 'finish'
