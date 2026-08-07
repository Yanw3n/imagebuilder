#!/usr/bin/env bash
set -euo pipefail

usage() { printf 'usage: %s full|rescue\n' "${0##*/}" >&2; exit 2; }
test "$#" -eq 1 || usage
case "$1" in full|rescue) PROFILE=$1 ;; *) usage ;; esac

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=${E87N_REPO_ROOT:-$(cd -- "$SCRIPT_DIR/.." && pwd)}
SOURCE_DIR=${IMMORTALWRT_SOURCE:-"${WORK_DIR:-$REPO_ROOT/work}/immortalwrt"}
source "$REPO_ROOT/scripts/lib/common.sh"

find_e87n_images() {
  local candidate
  while IFS= read -r -d '' candidate; do
    if tar -tf "$candidate" 2>/dev/null | grep -qx 'sysupgrade-edgepi_e87n/CONTROL' &&
       tar -tf "$candidate" 2>/dev/null | grep -qx 'sysupgrade-edgepi_e87n/kernel'; then
      printf '%s\0' "$candidate"
    fi
  done < <(find "$SOURCE_DIR/bin/targets" -type f -name '*sysupgrade*.bin' -print0 2>/dev/null)
}

if test -n "${E87N_IMAGE:-}"; then
  images=("$E87N_IMAGE")
else
  mapfile -d '' -t images < <(find_e87n_images)
fi
test "${#images[@]}" -eq 1 || die "expected exactly one E87N sysupgrade image, found ${#images[@]}"
IMAGE=${images[0]}
image_dir=$(dirname -- "$IMAGE")

if test -n "${E87N_MANIFEST:-}"; then
  manifests=("$E87N_MANIFEST")
else
  mapfile -d '' -t manifests < <(find "$image_dir" -maxdepth 1 -type f -name '*.manifest' -print0 2>/dev/null)
fi
test "${#manifests[@]}" -eq 1 || die "expected exactly one E87N package manifest, found ${#manifests[@]}"
MANIFEST=${manifests[0]}

if test -n "${E87N_DTB:-}"; then
  dtbs=("$E87N_DTB")
else
  mapfile -d '' -t dtbs < <(find "$SOURCE_DIR/build_dir" -type f -name '*edgepi-e87n*.dtb' -print0 2>/dev/null)
fi
test "${#dtbs[@]}" -eq 1 || die "expected exactly one compiled E87N DTB, found ${#dtbs[@]}"
DTB=${dtbs[0]}

if test -n "${E87N_VMLINUX:-}"; then
  vmlinuxes=("$E87N_VMLINUX")
else
  mapfile -d '' -t vmlinuxes < <(find "$SOURCE_DIR/build_dir" -type f -path '*/linux-mediatek_filogic/linux-*/vmlinux' -print0 2>/dev/null)
fi
test "${#vmlinuxes[@]}" -eq 1 || die "expected exactly one target vmlinux, found ${#vmlinuxes[@]}"
VMLINUX=${vmlinuxes[0]}
require_file "$SOURCE_DIR/.config"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/e87n-validate.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
tar -xOf "$IMAGE" 'sysupgrade-edgepi_e87n/CONTROL' >"$tmp/CONTROL"
grep -qx 'BOARD=edgepi_e87n' "$tmp/CONTROL" || die 'sysupgrade BOARD is not edgepi_e87n'
tar -xOf "$IMAGE" 'sysupgrade-edgepi_e87n/kernel' >"$tmp/kernel.fit"
kernel_size=$(wc -c <"$tmp/kernel.fit")
test "$kernel_size" -lt $((32 * 1024 * 1024)) || die 'FIT kernel exceeds the 32 MiB partition'
dumpimage -l "$tmp/kernel.fit" >"$tmp/fit.txt"
grep -Eqi 'FIT|Image Type|description' "$tmp/fit.txt" || die 'kernel is not a readable FIT image'
grep -Eqi 'ARM64|AArch64' "$tmp/fit.txt" || die 'FIT kernel is not ARM64'

# Prefer the compiled board DTB bytes first; host dtc decompile formatting can vary.
grep -aFq 'edgepi,e87n' "$DTB" || {
  printf 'error: compiled DTB binary lacks edgepi,e87n (path=%s)\n' "$DTB" >&2
  exit 1
}
if ! dtc -I dtb -O dts -o "$tmp/compiled.dts" "$DTB" 2>"$tmp/dtc.err"; then
  printf 'error: dtc failed to decompile DTB (path=%s)\n' "$DTB" >&2
  sed -n '1,80p' "$tmp/dtc.err" >&2 || true
  exit 1
fi
if ! grep -Fq 'edgepi,e87n' "$tmp/compiled.dts"; then
  printf 'error: compiled DTB lacks edgepi,e87n compatibility (path=%s)\n' "$DTB" >&2
  sed -n '1,40p' "$tmp/dtc.err" >&2 || true
  grep -n 'compatible' "$tmp/compiled.dts" | sed -n '1,40p' >&2 || true
  exit 1
fi
grep -q 'mediatek,mt7987-eth' "$tmp/compiled.dts" || die 'compiled DTB lacks the Ethernet controller'
if grep -Eqi '(^|[[:space:]])(wifi|wireless|wlan|80211)[^[:space:]]*@[0-9a-f]+' "$tmp/compiled.dts"; then
  die 'compiled DTB contains a Wi-Fi child node'
fi
awk '
  function trim(value) {
    sub(/^[[:space:]]+/, "", value); sub(/[[:space:]]+$/, "", value)
    return value
  }
  function property(props, name, parts, count, i, value) {
    count=split(props, parts, ";")
    for (i=1; i<=count; i++) {
      value=trim(parts[i])
      if (value ~ ("^" name "[[:space:]]*=")) {
        sub("^" name "[[:space:]]*=[[:space:]]*", "", value)
        return trim(value)
      }
    }
    return missing
  }
  function enabled(props, status) {
    status=property(props, "status")
    return status == missing || status == "\"okay\"" || status == "\"ok\""
  }
  function cell(props, name, value) {
    value=property(props, name)
    if (value !~ /^<[[:space:]]*(0x[0-9a-fA-F]+|[0-9]+)[[:space:]]*>$/) return missing
    sub(/^<[[:space:]]*/, "", value); sub(/[[:space:]]*>$/, "", value)
    return value
  }
  function basename(path, value) {
    value=path; sub(/^.*\//, "", value); return value
  }
  function controller_path(path) {
    return path == "/ethernet@15100000" || path == "/soc/ethernet@15100000"
  }
  function controller_child(path, suffix) {
    return path == "/ethernet@15100000/" suffix || path == "/soc/ethernet@15100000/" suffix
  }
  function inspect(path, props, name, value, handle, phyreg) {
    name=basename(path)
    value=property(props, "compatible")
    if (value ~ /(^|,)[[:space:]]*"mediatek,mt7987-eth"([[:space:]]*,|$)/) {
      compatible_controllers++
      if (!controller_path(path)) bad=1
    }
    if (name == "ethernet@15100000") {
      controller_nodes++
      if (!controller_path(path) || value !~ /(^|,)[[:space:]]*"mediatek,mt7987-eth"([[:space:]]*,|$)/ || !enabled(props)) bad=1
    }
    if (name == "mac@0") {
      mac0_nodes++
      if (!controller_child(path, "mac@0") || property(props, "reg") !~ /^<[[:space:]]*(0|0x0+)[[:space:]]*>$/ ||
          property(props, "phy-mode") != "\"2500base-x\"" || !enabled(props) || (handle=cell(props, "phy-handle")) == missing) bad=1
      else gmac0=handle
    }
    if (name == "mac@1") {
      mac1_nodes++
      if (!controller_child(path, "mac@1") || property(props, "reg") !~ /^<[[:space:]]*(1|0x0*1)[[:space:]]*>$/ ||
          property(props, "phy-mode") != "\"internal\"" || !enabled(props) || (handle=cell(props, "phy-handle")) == missing) bad=1
      else gmac1=handle
    }
    if (name == "phy@3") {
      phy3_nodes++
      if (!controller_child(path, "mdio-bus/phy@3") || property(props, "reg") !~ /^<[[:space:]]*(3|0x0*3)[[:space:]]*>$/ ||
          !enabled(props) || (handle=cell(props, "phandle")) == missing) bad=1
      else phy3=handle
    }
    if (name ~ /^phy@(f|0*f)$/) {
      phy15_nodes++
      phyreg=property(props, "reg"); handle=cell(props, "phandle")
      if (!controller_child(path, "mdio-bus/phy@f") || phyreg !~ /^<[[:space:]]*(15|0x0*f)[[:space:]]*>$/ ||
          !enabled(props) || handle == missing) bad=1
      else phy15=handle
    }
  }
  BEGIN { missing="\034" }
  {
    if ($0 ~ /\{[[:space:]]*$/) {
      node=$0; sub(/[[:space:]]*\{[[:space:]]*$/, "", node); node=trim(node)
      depth++
      if (node == "/") path[depth]="/"
      else if (path[depth-1] == "/") path[depth]="/" node
      else path[depth]=path[depth-1] "/" node
      props[depth]=""
      next
    }
    if ($0 ~ /\{/) next
    if ($0 ~ /^[[:space:]]*};?[[:space:]]*$/) {
      inspect(path[depth], props[depth])
      delete path[depth]; delete props[depth]; depth--; next
    }
    if (depth > 0) props[depth]=props[depth] " " $0
  }
  END {
    if (bad || controller_nodes != 1 || compatible_controllers != 1 || mac0_nodes != 1 || mac1_nodes != 1 ||
        phy3_nodes != 1 || phy15_nodes != 1 || gmac0 == missing || gmac1 == missing ||
        phy3 == missing || phy15 == missing || gmac0 != phy3 || gmac1 != phy15) {
      printf "DTB topology mismatch: bad=%d controller=%d compatible=%d mac0=%d mac1=%d phy3=%d phy15=%d handles=%s/%s:%s/%s\n", bad, controller_nodes, compatible_controllers, mac0_nodes, mac1_nodes, phy3_nodes, phy15_nodes, gmac0, phy3, gmac1, phy15 > "/dev/stderr"
      exit 1
    }
  }
' "$tmp/compiled.dts" || die 'compiled DTB does not preserve the E87N two-port PHY topology'
readelf -S "$VMLINUX" >"$tmp/sections.txt"
grep -Eq '(^|[[:space:]])\.BTF([[:space:]]|$)' "$tmp/sections.txt" || die 'vmlinux lacks built-in .BTF'

manifest_has() { awk -v want="$1" 'NF && $1 == want { found=1 } END { exit !found }' "$MANIFEST"; }
required_packages() {
  local requested_profile=${1:-$PROFILE}
  awk '
    /^CONFIG_PACKAGE_[A-Za-z0-9_-]+=y$/ { s=$0; sub(/^CONFIG_PACKAGE_/,"",s); sub(/=y$/,"",s); state[s]="y"; if(!seen[s]++) order[++n]=s }
    /^# CONFIG_PACKAGE_[A-Za-z0-9_-]+ is not set$/ { s=$0; sub(/^# CONFIG_PACKAGE_/,"",s); sub(/ is not set$/,"",s); state[s]="n"; if(!seen[s]++) order[++n]=s }
    END { for(i=1;i<=n;i++) if(state[order[i]]=="y") print order[i] }
  ' "$REPO_ROOT/configs/common.config" "$REPO_ROOT/configs/$requested_profile.config"
}
while IFS= read -r package; do
  manifest_has "$package" || die "$PROFILE manifest omits required package $package"
done < <(required_packages)

if test "$PROFILE" = rescue; then
  while IFS= read -r package; do
    if manifest_has "$package"; then
      die "rescue manifest contains full-only package $package"
    fi
  done < <(comm -23 <(required_packages full | sort) <(required_packages rescue | sort))
fi

while read -r package _; do
  case "$package" in
    iw|iw-full|iwinfo|ucode-mod-nl80211|wireless-regdb|wifi-scripts|wpad*|hostapd*|wpa-supplicant*|wpa-cli*|kmod-cfg80211|kmod-mac80211|*wifi*|*wireless*|kmod-mt76*|kmod-mt7915*|kmod-mt7916*|kmod-mt7921*|kmod-mt7922*|kmod-mt7992*|kmod-mt7996*|kmod-ath*|kmod-rtl*|brcmfmac-firmware*)
      die "$PROFILE manifest contains forbidden Wi-Fi package $package" ;;
  esac
  if test "$PROFILE" = rescue; then
    case "$package" in
      dae|daed|luci-app-daede|luci-app-openclash|luci-app-passwall|luci-app-store|adguardhome|tailscale|tailscaled|python3|python3-*|vlmcsd|luci-app-vlmcsd|bridger|kmod-wireguard|wireguard-tools|luci-proto-wireguard|kmod-sched-bpf|kmod-veth|kmod-xdp-sockets-diag|kmod-tun|kmod-nft-socket|kmod-nft-tproxy|nvme-cli|smartmontools|ethtool|ip-full|iperf3|tcpdump|usbutils|pciutils|ddns-scripts-cloudflare)
        die "rescue manifest contains forbidden package $package" ;;
    esac
  fi
done <"$MANIFEST"

printf '%s\n' \
  'VALIDATION=PASS' \
  "PROFILE=$PROFILE" \
  'BOARD=edgepi,e87n' \
  "KERNEL_BYTES=$kernel_size" \
  'FIT_ARCH=ARM64' \
  'DTB_COMPATIBLE=edgepi,e87n' \
  'DTB_NETWORK=PASS' \
  'DTB_WIFI_CHILDREN=ABSENT' \
  'VMLINUX_BTF=PASS' \
  'PACKAGE_POLICY=PASS'
