#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

cfg=configs/common.config
dts=device/edgepi-e87n/source-overlay/target/linux/mediatek/dts/mt7987a-edgepi-e87n.dts
driver_patch=device/edgepi-e87n/source-overlay/target/linux/mediatek/patches-6.12/950-fbdev-fbtft-add-nv3007.patch
package_patch=patches/immortalwrt/0002-kernel-package-nv3007-fbtft-driver.patch
display_patch=patches/immortalwrt/0003-mediatek-filogic-enable-display.patch

test -f "$cfg"
test -f "$dts"
test -f "$driver_patch"
test -f "$package_patch"
test -f "$display_patch"

required_symbols=(
	CONFIG_TARGET_mediatek=y
	CONFIG_TARGET_mediatek_filogic=y
	CONFIG_TARGET_mediatek_filogic_DEVICE_edgepi_e87n=y
	CONFIG_KERNEL_DEBUG_INFO=y
	CONFIG_KERNEL_DEBUG_INFO_BTF=y
	CONFIG_KERNEL_BPF_EVENTS=y
	CONFIG_KERNEL_BPF_STREAM_PARSER=y
	CONFIG_KERNEL_CGROUP_BPF=y
	CONFIG_KERNEL_XDP_SOCKETS=y
	CONFIG_PACKAGE_kmod-sched-core=y
	CONFIG_PACKAGE_kmod-sched-bpf=y
	CONFIG_PACKAGE_kmod-veth=y
	CONFIG_PACKAGE_kmod-xdp-sockets-diag=y
	CONFIG_PACKAGE_kmod-nft-socket=y
	CONFIG_PACKAGE_kmod-nft-tproxy=y
	CONFIG_PACKAGE_kmod-wireguard=y
	CONFIG_PACKAGE_kmod-tun=y
	CONFIG_PACKAGE_kmod-hwmon-pwmfan=y
	CONFIG_PACKAGE_kmod-nvme=y
	CONFIG_PACKAGE_kmod-usb3=y
	CONFIG_PACKAGE_kmod-usb-storage=y
	CONFIG_PACKAGE_kmod-usb-storage-uas=y
	CONFIG_PACKAGE_kmod-fs-ext4=y
	CONFIG_PACKAGE_kmod-fs-f2fs=y
	CONFIG_PACKAGE_kmod-fs-btrfs=y
	CONFIG_PACKAGE_kmod-fb-tft=y
	CONFIG_PACKAGE_luci=y
	CONFIG_PACKAGE_luci-i18n-base-zh-cn=y
	CONFIG_PACKAGE_luci-theme-argon=y
	CONFIG_PACKAGE_fancontrol=y
	CONFIG_PACKAGE_luci-app-fancontrol=y
	CONFIG_PACKAGE_luci-i18n-fancontrol-zh-cn=y
)

for symbol in "${required_symbols[@]}"; do
	grep -Fqx "$symbol" "$cfg"
done
grep -Fqx '# CONFIG_KERNEL_DEBUG_INFO_REDUCED is not set' "$cfg"

if grep -Eiq 'mt7992|mt7996' "$cfg"; then
	printf '%s\n' 'unexpected Wi-Fi package in common config' >&2
	exit 1
fi

grep -Fq 'reset-gpios = <&pio 10 GPIO_ACTIVE_LOW>;' "$dts"
grep -Fq 'dc-gpios = <&pio 11 GPIO_ACTIVE_HIGH>;' "$dts"

# These are fixed kernel symbols in the locked 6.12 generic config, not
# selectable CONFIG_KERNEL_* buildroot symbols.
if grep -Eq '^CONFIG_KERNEL_BPF_(SYSCALL|JIT)=' "$cfg"; then
	printf '%s\n' 'invalid buildroot BPF syscall/JIT symbol in common config' >&2
	exit 1
fi

grep -Fq 'config FB_TFT_NV3007' "$driver_patch"
grep -Eq 'obj-\$\(CONFIG_FB_TFT_NV3007\)[[:space:]]+\+= fb_nv3007\.o' "$driver_patch"
grep -Fq 'drivers/staging/fbtft/fb_nv3007.c' "$driver_patch"
grep -Fq '#define DRVNAME "fb_nv3007"' "$driver_patch"
grep -Fq 'FBTFT_REGISTER_DRIVER(DRVNAME, "newvisionu,nv3007", &display);' "$driver_patch"
grep -Fq '.width = 428' "$driver_patch"
grep -Fq '.height = 142' "$driver_patch"
grep -Fq 'mdelay(5);' "$driver_patch"
grep -Fq 'mdelay(200);' "$driver_patch"
grep -Fq 'mdelay(150);' "$driver_patch"
grep -Fq 'mdelay(20);' "$driver_patch"
grep -Fq 'write_reg(par, 0x2A, 0x00, 0x0C, 0x00, 0x99);' "$driver_patch"
grep -Fq 'write_reg(par, 0x2B, 0x00, 0x00, 0x01, 0xAB);' "$driver_patch"
grep -Fq 'write_reg(par, 0xFF, 0xA5);' "$driver_patch"
test "$(sed -n '/^+static int init_display/,/^+static void set_addr_win/p' "$driver_patch" |
	grep -Ec '^\+[[:space:]]*write_reg\(par,')" -eq 84
test "$(grep -Fc '00 02 04 07 05 02 21 23 3A 08 13 13 29 31 0F' "$driver_patch")" -eq 2
grep -Fq 'xs += 14;' "$driver_patch"
grep -Fq 'ys += 14;' "$driver_patch"
grep -Fq 'xs += 12;' "$driver_patch"
grep -Fq 'ys += 12;' "$driver_patch"
grep -Fq '0xC0 | (par->bgr << 3)' "$driver_patch"
grep -Fq '0x60 | (par->bgr << 3)' "$driver_patch"
grep -Fq '0x00 | (par->bgr << 3)' "$driver_patch"
grep -Fq '0xA0 | (par->bgr << 3)' "$driver_patch"

grep -Fq 'CONFIG_FB_TFT_NV3007' "$package_patch"
grep -Fq '$(LINUX_DIR)/drivers/staging/fbtft/fb_nv3007.ko' "$package_patch"
grep -Fq 'AUTOLOAD:=$(call AutoLoad,08,fbtft fb_nv3007)' "$package_patch"
grep -Fq 'FEATURES+=display' "$display_patch"

if [[ -n "${IMMORTALWRT_SOURCE:-}" ]]; then
	test -f "$IMMORTALWRT_SOURCE/target/linux/generic/config-6.12"
	grep -Fqx 'CONFIG_BPF_SYSCALL=y' "$IMMORTALWRT_SOURCE/target/linux/generic/config-6.12"
	grep -Fqx 'CONFIG_BPF_JIT=y' "$IMMORTALWRT_SOURCE/target/linux/generic/config-6.12"
	git -C "$IMMORTALWRT_SOURCE" apply --check "$repo_root/$package_patch"
	git -C "$IMMORTALWRT_SOURCE" apply --check "$repo_root/$display_patch"
fi
