#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

umask 077
mkdir -p .private
ssh root@"${E87N_IP:-192.168.1.1}" \
	'ubus call network.interface dump; ubus call network.device status; ip -br link; uci -q show network' \
	> .private/e87n-network-runtime.txt
