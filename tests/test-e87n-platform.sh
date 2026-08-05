#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

dts=device/edgepi-e87n/source-overlay/target/linux/mediatek/dts/mt7987a-edgepi-e87n.dts
platform_patch=patches/immortalwrt/0001-mediatek-filogic-add-edgepi-e87n.patch
capture_tool=tools/capture-e87n-network.sh

test -f "$platform_patch"
grep -Fq 'KERNEL_SIZE := 32768k' "$platform_patch"

test -f "$dts"
grep -Fqx '	compatible = "edgepi,e87n", "mediatek,mt7987a", "mediatek,mt7987";' "$dts"
grep -Fq 'root=PARTLABEL=rootfs rootwait rootfstype=squashfs,f2fs' "$dts"
grep -Fq 'compatible = "pwm-fan";' "$dts"
grep -Fq 'pwms = <&pwm 1 50000 0>;' "$dts"
grep -Fq 'compatible = "newvisionu,nv3007";' "$dts"
grep -Fq 'spi-max-frequency = <52000000>;' "$dts"
grep -Fq 'width = <142>;' "$dts"
grep -Fq 'height = <428>;' "$dts"
grep -Fq 'rotate = <270>;' "$dts"
grep -Fq 'fps = <100>;' "$dts"

for part in u-boot-env factory fip kernel rootfs; do
	grep -Fq "partname = \"$part\";" "$dts"
done
grep -Fq 'macaddr@24 {' "$dts"
grep -Fq 'reg = <0x24 0x6>;' "$dts"
grep -Fq 'macaddr@2a {' "$dts"
grep -Fq 'reg = <0x2a 0x6>;' "$dts"

grep -Fq 'phy-mode = "2500base-x";' "$dts"
grep -Fq 'phy0: phy@3 {' "$dts"
grep -Fq 'phy-mode = "internal";' "$dts"
grep -Fq 'phy1: phy@f {' "$dts"
grep -Fq 'gpios = <&pio 1 GPIO_ACTIVE_LOW>;' "$dts"
grep -Fq 'gpios = <&pio 0 GPIO_ACTIVE_LOW>;' "$dts"
grep -Fq 'gpios = <&pio 4 GPIO_ACTIVE_LOW>;' "$dts"
grep -Fq 'gpios = <&pio 3 GPIO_ACTIVE_LOW>;' "$dts"
grep -Fq 'groups = "pwm1_0";' "$dts"

test "$(grep -Fc '&pcie0 {' "$dts")" -eq 1
test "$(grep -Fc '&pcie1 {' "$dts")" -eq 1
for controller in pcie0 pcie1; do
	sed -n "/^&$controller {/,/^};/p" "$dts" | grep -Fq 'status = "okay";'
done
if grep -Eiq 'mt7992|mediatek,mt76' "$dts"; then
	printf '%s\n' 'unexpected Wi-Fi device in E87N DTS' >&2
	exit 1
fi
test "$(grep -Fc 'status = "okay";' "$dts")" -ge 10
grep -Fq '&ssusb {' "$dts"
grep -Fq '&tphyu3port0 {' "$dts"

test -f "$platform_patch"
grep -Fq 'define Device/edgepi_e87n' "$platform_patch"
grep -Fq 'DEVICE_DTS := mt7987a-edgepi-e87n' "$platform_patch"
grep -Fq 'IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata' "$platform_patch"
if grep -Eiq 'kmod-mt7996e|mt7992[^[:space:]]*firmware' "$platform_patch"; then
	printf '%s\n' 'unexpected Wi-Fi package in E87N profile' >&2
	exit 1
fi
grep -Fq 'CI_KERNPART="kernel"' "$platform_patch"
grep -Fq 'CI_ROOTPART="rootfs"' "$platform_patch"
grep -Fq 'target/linux/mediatek/filogic/base-files/etc/board.d/02_network' "$platform_patch"
grep -Fq 'ucidef_set_interfaces_lan_wan eth0 eth1' "$platform_patch"
test "$(grep -Fc '+	edgepi,e87n|\' "$platform_patch")" -eq 4

test -f "$capture_tool"
"${BASH:-bash}" -n "$capture_tool"
grep -Fq 'ubus call network.interface dump' "$capture_tool"
grep -Fq 'ubus call network.device status' "$capture_tool"
grep -Fq 'ip -br link' "$capture_tool"
grep -Fq 'uci -q show network' "$capture_tool"
grep -Fq '.private/e87n-network-runtime.txt' "$capture_tool"

if [[ -n "${IMMORTALWRT_SOURCE:-}" ]]; then
	test -d "$IMMORTALWRT_SOURCE/target/linux/mediatek"
	if command -v patch >/dev/null 2>&1; then
		patch --dry-run --silent -d "$IMMORTALWRT_SOURCE" -p1 < "$platform_patch"
	else
		git -C "$IMMORTALWRT_SOURCE" apply --check "$repo_root/$platform_patch"
	fi
fi
