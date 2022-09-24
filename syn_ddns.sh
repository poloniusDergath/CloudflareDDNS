#!/bin/sh
IPV6=$(ip -br -6 addr show dev eth0 scope global | awk '{print $3}' | sed 's/\/64//')
SCRIPT_DIR=$(dirname $(realpath $0 ))

$SCRIPT_DIR/cfddns.sh -r $CF_DOMAIN -c $SCRIPT_DIR/cloudflare.credentials -6 -i $IPV6
