#!/bin/sh
# Copyright 2016-2017 Dan Luedtke <mail@danrl.com>
# Licensed to the public under the Apache License 2.0.


WG=/usr/bin/wg
if [ ! -x $WG ]; then
  logger -t "wireguard" "error: missing wireguard-tools (${WG})"
  exit 0
fi


[ -n "$INCLUDE_ONLY" ] || {
  . /lib/functions.sh
  . ../netifd-proto.sh
  init_proto "$@"
}


proto_wireguard_init_config() {
  proto_config_add_string "private_key"
  proto_config_add_int    "listen_port"
  proto_config_add_int    "mtu"
  proto_config_add_string "preshared_key"
  available=1
  no_proto_task=1
}


proto_wireguard_setup_peer() {
  local peer_config="$1"

  local public_key
  local allowed_ips
  local route_allowed_ips
  local endpoint_host
  local endpoint_port
  local persistent_keepalive

  config_get      public_key           "${peer_config}" "public_key"
  config_get      allowed_ips          "${peer_config}" "allowed_ips"
  config_get_bool route_allowed_ips    "${peer_config}" "route_allowed_ips" 0
  config_get      endpoint_host        "${peer_config}" "endpoint_host"
  config_get      endpoint_port        "${peer_config}" "endpoint_port"
  config_get      persistent_keepalive "${peer_config}" "persistent_keepalive"

  # peer configuration
  echo "[Peer]"                                         >> "${wg_cfg}"
  echo "PublicKey=${public_key}"                        >> "${wg_cfg}"
  for allowed_ip in $allowed_ips; do
    echo "AllowedIPs=${allowed_ip}"                     >> "${wg_cfg}"
  done
  if [ "${endpoint_host}" ]; then
    case "${endpoint_host}" in
      *:*)
        endpoint="[${endpoint_host}]"
      ;;
      *)
        endpoint="${endpoint_host}"
      ;;
    esac
    if [ "${endpoint_port}" ]; then
      endpoint="${endpoint}:${endpoint_port}"
    else
      endpoint="${endpoint}:51820"
    fi
    echo "Endpoint=${endpoint}"                         >> "${wg_cfg}"
  fi
  if [ "${persistent_keepalive}" ]; then
    echo "PersistentKeepalive=${persistent_keepalive}"  >> "${wg_cfg}"
  fi

  # add routes for allowed ips
  if [ ${route_allowed_ips} -ne 0 ]; then
    for allowed_ip in ${allowed_ips}; do
      case "${allowed_ip}" in
        *:*/*)
          proto_add_ipv6_route "${allowed_ip%%/*}" "${allowed_ip##*/}"
        ;;
        */*)
          proto_add_ipv4_route "${allowed_ip%%/*}" "${allowed_ip##*/}"
        ;;
      esac
    done
  fi
}


proto_wireguard_setup() {
  local config="$1"
  local wg_dir="/tmp/wireguard"
  local wg_cfg="${wg_dir}/${config}"

  local private_key
  local listen_port
  local mtu
  local preshared_key

  # load configuration
  config_load network
  config_get private_key   "${config}" "private_key"
  config_get listen_port   "${config}" "listen_port"
  config_get addresses     "${config}" "addresses"
  config_get mtu           "${config}" "mtu"
  config_get preshared_key "${config}" "preshared_key"

  # create interface
  ip link del dev "${config}" 2>/dev/null
  ip link add dev "${config}" type wireguard

  if [ "${mtu}" ]; then
    ip link set mtu "${mtu}" dev "${config}"
  fi

  proto_init_update "${config}" 1

  # generate configuration file
  umask 077
  mkdir -p "${wg_dir}"
  echo "[Interface]"                     >  "${wg_cfg}"
  echo "PrivateKey=${private_key}"       >> "${wg_cfg}"
  if [ "${listen_port}" ]; then
    echo "ListenPort=${listen_port}"     >> "${wg_cfg}"
  fi
  if [ "${preshared_key}" ]; then
    echo "PresharedKey=${preshared_key}" >> "${wg_cfg}"
  fi
  config_foreach proto_wireguard_setup_peer "wireguard_${config}"

  # apply configuration file
  ${WG} setconf ${config} "${wg_cfg}"
  WG_RETURN=$?

  # delete configuration file
  rm -f "${wg_cfg}"

  # check status
  if [ ${WG_RETURN} -ne 0 ]; then
    sleep 5
    proto_setup_failed "${config}"
    exit 1
  fi

  # add ip addresses
  for address in ${addresses}; do
    case "${address}" in
      *:*/*)
        proto_add_ipv6_address "${address%%/*}" "${address##*/}"
      ;;
      *.*/*)
        proto_add_ipv4_address "${address%%/*}" "${address##*/}"
      ;;
      *:*)
        proto_add_ipv6_address "${address%%/*}" "128"
      ;;
      *.*)
        proto_add_ipv4_address "${address%%/*}" "32"
      ;;
    esac
  done

  # endpoint dependency
  wg show "${config}" endpoints | \
    sed -E 's/\[?([0-9.:a-f]+)\]?:([0-9]+)/\1 \2/' | \
    while IFS=$'\t ' read -r key address port; do
    [ -n "${port}" ] || continue
    echo "adding host depedency for ${address} at ${config}"
    proto_add_host_dependency "${config}" "${address}"
  done

  proto_send_update "${config}"
}


proto_wireguard_teardown() {
  local config="$1"
  ip link del dev "${config}" >/dev/null 2>&1
}


[ -n "$INCLUDE_ONLY" ] || {
  add_protocol wireguard
}
