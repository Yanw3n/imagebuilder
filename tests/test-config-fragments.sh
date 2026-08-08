#!/usr/bin/env sh
# shellcheck disable=SC1091
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
common="$root/configs/common.config"

fail() {
	printf '%s\n' "FAIL: $*" >&2
	exit 1
}

require_file() {
	test -f "$1" || fail "missing $1"
}

effective_state() {
	symbol=$1
	profile=$2
	awk -v symbol="$symbol" '
		$0 == symbol "=y" { state = "y" }
		$0 == "# " symbol " is not set" { state = "n" }
		END { print state ? state : "unset" }
	' "$common" "$root/configs/$profile.config"
}

assert_effective_y() {
	state=$(effective_state "$2" "$1")
	test "$state" = y || fail "$1 effective config does not enable $2 (got $state)"
}

assert_effective_n() {
	state=$(effective_state "$2" "$1")
	test "$state" = n || fail "$1 effective config does not disable $2 (got $state)"
}

assert_not_effective_y() {
	state=$(effective_state "$2" "$1")
	test "$state" != y || fail "$1 effective config must not enable $2"
}

assert_no_enabled_wifi() {
	file=$1
	wifi_re='^CONFIG_PACKAGE_(iw|iw-full|iwinfo|ucode-mod-nl80211|wireless-regdb|wifi-scripts|wpad([_-].*)?|hostapd([_-].*)?|wpa-(supplicant|cli)([_-].*)?|kmod-(cfg80211|mac80211)|luci-(app|i18n)-[^=]*(wifi|wireless)[^=]*|kmod-[^=]*(wifi|wireless|wlan|80211)[^=]*|(kmod-)?(adm8211|airo|atmel|b43|brcm[0-9a-z]*|carl9170|hermes|iwl[0-9a-z]*|libertas|marvell|mt76|mt7915|mt7916|mt7921|mt7922|mt7992|mt7996|mwifiex|orinoco|p54|prism54|qtnfmac|rsi91|rt[0-9a-z]*|ti-wl|wil6210|wl12|wl18|wlcore|zd1211|zydas|ath[0-9a-z]*|rtl[0-9a-z]*)[^=]*|[^=]*(adm8211|airo|atmel|b43|brcm[0-9a-z]*|carl9170|hermes|iwl[0-9a-z]*|libertas|marvell|mt76|mt7915|mt7916|mt7921|mt7922|mt7992|mt7996|mwifiex|orinoco|p54|prism54|qtnfmac|rsi91|rt[0-9a-z]*|ti-wl|wil6210|wl12|wl18|wlcore|zd1211|zydas|ath[0-9a-z]*|rtl[0-9a-z]*)[^=]*firmware[^=]*)=y$'
	matches=$(grep -E "$wifi_re" "$file" || true)
	if test -n "$matches"; then
		fail "enabled Wi-Fi package symbol in $file: $matches"
	fi
}

assert_wifi_detector_rejects() {
	name=$1
	line=$2
	fixture=$(mktemp "${TMPDIR:-/tmp}/e87n-wifi.XXXXXX")
	printf '%s\n' "$line" > "$fixture"
	if (assert_no_enabled_wifi "$fixture") >/dev/null 2>&1; then
		rm -f "$fixture"
		fail "Wi-Fi detector accepts $name fixture"
	fi
	rm -f "$fixture"
}

effective_enabled_symbols() {
	profile=$1
	awk '
		/^CONFIG_[A-Za-z0-9_-]+=y$/ {
			symbol = $0
			sub(/=y$/, "", symbol)
			state[symbol] = "y"
			if (!seen[symbol]++) order[++count] = symbol
		}
		/^# CONFIG_[A-Za-z0-9_-]+ is not set$/ {
			symbol = $0
			sub(/^# /, "", symbol)
			sub(/ is not set$/, "", symbol)
			state[symbol] = "n"
			if (!seen[symbol]++) order[++count] = symbol
		}
		END {
			for (i = 1; i <= count; i++)
				if (state[order[i]] == "y") print order[i]
		}
	' "$common" "$root/configs/$profile.config"
}

assert_resolved_y() {
	file=$1
	symbol=$2
	if ! grep -qx "$symbol=y" "$file"; then
		if test "$symbol" = CONFIG_PACKAGE_luci-app-fancontrol; then
			printf '%s\n' 'fancontrol LuCI package Kconfig diagnostic:' >&2
			grep -n -A 14 -B 2 '^config PACKAGE_luci-app-fancontrol$' \
				"$source/tmp/.config-package.in" >&2 || true
			grep -E '^(CONFIG_PACKAGE_(fancontrol|rpcd|luci-base|luci-app-fancontrol))=' \
				"$file" >&2 || true
		fi
		fail "resolved config drops $symbol"
	fi
}

assert_resolved_n() {
	file=$1
	symbol=$2
	if grep -qx "$symbol=y" "$file"; then
		fail "resolved config enables forbidden $symbol"
	fi
}

assert_effective_selections_survive() {
	profile=$1
	resolved=$2
	effective_enabled_symbols "$profile" | while IFS= read -r symbol; do
		assert_resolved_y "$resolved" "$symbol"
	done
}

assert_profile_disables_survive() {
	profile=$1
	resolved=$2
	sed -n 's/^# \(CONFIG_[A-Za-z0-9_-]*\) is not set$/\1/p' \
		"$root/configs/$profile.config" | while IFS= read -r symbol; do
		assert_resolved_n "$resolved" "$symbol"
	done
}

assert_manifest_no_wifi() {
	manifest=$1
	normalized=$(mktemp "${TMPDIR:-/tmp}/e87n-manifest.XXXXXX")
	awk 'NF && $1 !~ /^#/ { print "CONFIG_PACKAGE_" $1 "=y" }' "$manifest" > "$normalized"
	if ! (assert_no_enabled_wifi "$normalized") >/dev/null 2>&1; then
		rm -f "$normalized"
		fail "enabled Wi-Fi package in manifest $manifest"
	fi
	rm -f "$normalized"
}

assert_manifest_detector_rejects() {
	name=$1
	line=$2
	fixture=$(mktemp "${TMPDIR:-/tmp}/e87n-package-manifest.XXXXXX")
	printf '%s\n' "$line" > "$fixture"
	if (assert_manifest_no_wifi "$fixture") >/dev/null 2>&1; then
		rm -f "$fixture"
		fail "manifest Wi-Fi detector accepts $name fixture"
	fi
	rm -f "$fixture"
}

assert_manifest_package() {
	manifest=$1
	symbol=$2
	package=${symbol#CONFIG_PACKAGE_}
	grep -Eq "^${package}([[:space:]]|$)" "$manifest" || \
		fail "manifest $manifest omits $package"
}

assert_manifest_omits() {
	manifest=$1
	symbol=$2
	package=${symbol#CONFIG_PACKAGE_}
	if grep -Eq "^${package}([[:space:]]|$)" "$manifest"; then
		fail "manifest $manifest contains forbidden $package"
	fi
}

validate_manifest() {
	profile=$1
	manifest=$2
	require_file "$manifest"
	assert_manifest_no_wifi "$manifest"
	effective_enabled_symbols "$profile" | sed -n 's/^CONFIG_PACKAGE_//p' | \
		while IFS= read -r package; do
			assert_manifest_package "$manifest" "CONFIG_PACKAGE_$package"
		done
	if test "$profile" = rescue; then
		for symbol in \
			CONFIG_PACKAGE_daed CONFIG_PACKAGE_luci-app-daed \
			CONFIG_PACKAGE_luci-app-openclash CONFIG_PACKAGE_luci-app-passwall \
			CONFIG_PACKAGE_ddns-scripts-cloudflare \
			CONFIG_PACKAGE_adguardhome CONFIG_PACKAGE_tailscale CONFIG_PACKAGE_python3 \
			CONFIG_PACKAGE_bridger \
			CONFIG_PACKAGE_kmod-wireguard CONFIG_PACKAGE_wireguard-tools \
			CONFIG_PACKAGE_luci-proto-wireguard \
			CONFIG_PACKAGE_python3-pip CONFIG_PACKAGE_python3-openssl \
			CONFIG_PACKAGE_python3-sqlite3 CONFIG_PACKAGE_vlmcsd \
			CONFIG_PACKAGE_luci-app-vlmcsd; do
			assert_manifest_omits "$manifest" "$symbol"
		done
	fi
	printf '%s\n' "PASS: $profile manifest package policy"
}

find_manifest() {
	profile=$1
	explicit=$2
	if test -n "$explicit"; then
		printf '%s\n' "$explicit"
		return
	fi
	for candidate in \
		"$root/out/e87n-$profile.manifest" \
		"$root/out/$profile/manifest" \
		"$root/out/$profile/packages.manifest"; do
		if test -f "$candidate"; then
			printf '%s\n' "$candidate"
			return
		fi
	done
}

validate_resolved_configs() {
	source=${IMMORTALWRT_SOURCE:-"$root/work/immortalwrt"}
	if ! test -d "$source"; then
		printf '%s\n' "SKIP: resolved config validation: pinned source absent at $source"
		return
	fi
	if ! test -f "$source/scripts/kconfig.pl" || ! test -f "$source/Makefile" || \
		! test -d "$source/feeds/packages" || ! test -d "$source/feeds/luci" || \
		! test -d "$source/package/feeds/daed"; then
		printf '%s\n' "SKIP: resolved config validation: prepared pinned source incomplete at $source"
		return
	fi

	# The prepared source must still be the pinned base before resolving profiles.
	. "$root/versions.env"
	actual_commit=$(git -C "$source" rev-parse HEAD)
	test "$actual_commit" = "$IMMORTALWRT_COMMIT" || \
		fail "source HEAD is $actual_commit, expected $IMMORTALWRT_COMMIT"

	resolve_tmp=$(mktemp -d "${TMPDIR:-/tmp}/e87n-resolve.XXXXXX")
	source_config="$source/.config"
	source_old="$source/.config.old"
	had_config=0
	had_old=0
	if test -f "$source_config"; then
		cp "$source_config" "$resolve_tmp/original.config"
		had_config=1
	fi
	if test -f "$source_old"; then
		cp "$source_old" "$resolve_tmp/original.config.old"
		had_old=1
	fi

	cleanup_resolved_configs() {
		if test "$had_config" = 1; then
			cp "$resolve_tmp/original.config" "$source_config"
		else
			rm -f "$source_config"
		fi
		if test "$had_old" = 1; then
			cp "$resolve_tmp/original.config.old" "$source_old"
		else
			rm -f "$source_old"
		fi
		rm -rf "$resolve_tmp"
	}
	trap cleanup_resolved_configs EXIT HUP INT TERM

	for profile in full rescue; do
		cp "$common" "$source_config"
		"$source/scripts/kconfig.pl" + "$source_config" \
			"$root/configs/$profile.config" > "$resolve_tmp/$profile.merged"
		cp "$resolve_tmp/$profile.merged" "$source_config"
		make -C "$source" defconfig
		cp "$source_config" "$resolve_tmp/$profile.resolved"
		assert_effective_selections_survive "$profile" "$resolve_tmp/$profile.resolved"
		assert_profile_disables_survive "$profile" "$resolve_tmp/$profile.resolved"
		if test "$profile" = rescue; then
			for symbol in \
				CONFIG_PACKAGE_daed CONFIG_PACKAGE_luci-app-daed \
				CONFIG_PACKAGE_luci-app-openclash CONFIG_PACKAGE_luci-app-passwall \
				CONFIG_PACKAGE_ddns-scripts-cloudflare \
				CONFIG_PACKAGE_adguardhome CONFIG_PACKAGE_tailscale CONFIG_PACKAGE_python3 \
				CONFIG_PACKAGE_bridger \
				CONFIG_PACKAGE_kmod-wireguard CONFIG_PACKAGE_wireguard-tools \
				CONFIG_PACKAGE_luci-proto-wireguard \
				CONFIG_PACKAGE_python3-pip CONFIG_PACKAGE_python3-openssl \
				CONFIG_PACKAGE_python3-sqlite3 CONFIG_PACKAGE_vlmcsd \
				CONFIG_PACKAGE_luci-app-vlmcsd CONFIG_PACKAGE_ethtool \
				CONFIG_PACKAGE_ip-full CONFIG_PACKAGE_iperf3 CONFIG_PACKAGE_tcpdump \
				CONFIG_PACKAGE_usbutils CONFIG_PACKAGE_pciutils; do
				assert_resolved_n "$resolve_tmp/$profile.resolved" "$symbol"
			done
		fi
		assert_no_enabled_wifi "$resolve_tmp/$profile.resolved"
	done

	cleanup_resolved_configs
	trap - EXIT HUP INT TERM
	printf '%s\n' 'PASS: resolved full and rescue configs'
}

require_file "$common"
require_file "$root/configs/full.config"
require_file "$root/configs/rescue.config"

# Guard known false negatives in the original Wi-Fi matcher.
assert_wifi_detector_rejects iw 'CONFIG_PACKAGE_iw=y'
assert_wifi_detector_rejects kmod-cfg80211 'CONFIG_PACKAGE_kmod-cfg80211=y'
assert_wifi_detector_rejects kmod-rt2800-usb 'CONFIG_PACKAGE_kmod-rt2800-usb=y'
assert_wifi_detector_rejects kmod-mt7915e 'CONFIG_PACKAGE_kmod-mt7915e=y'
assert_wifi_detector_rejects mt7996-firmware 'CONFIG_PACKAGE_kmod-mt7996-firmware=y'
assert_wifi_detector_rejects brcmfmac-firmware 'CONFIG_PACKAGE_brcmfmac-firmware-43602a1-pcie=y'
assert_wifi_detector_rejects ucode-mod-nl80211 'CONFIG_PACKAGE_ucode-mod-nl80211=y'

# LuCI uses iwinfo as a generic hardware-information API, while this PHY
# firmware drives the E87N's wired 2.5G ports; neither enables a Wi-Fi radio.
allowed_non_wifi=$(mktemp "${TMPDIR:-/tmp}/e87n-non-wifi.XXXXXX")
printf '%s\n' \
	'CONFIG_PACKAGE_libiwinfo=y' \
	'CONFIG_PACKAGE_libiwinfo-data=y' \
	'CONFIG_PACKAGE_mt7987-2p5g-phy-firmware=y' > "$allowed_non_wifi"
assert_no_enabled_wifi "$allowed_non_wifi"
rm -f "$allowed_non_wifi"

assert_manifest_detector_rejects iw 'iw 6.9-r1'
assert_manifest_detector_rejects kmod-cfg80211 'kmod-cfg80211 6.12-r1'
assert_manifest_detector_rejects kmod-rt2800-usb 'kmod-rt2800-usb 6.12-r1'
assert_manifest_detector_rejects brcmfmac-firmware 'brcmfmac-firmware-43602a1-pcie 20250311-r1'
assert_manifest_detector_rejects ucode-mod-nl80211 'ucode-mod-nl80211 2025.06-r1'

# Removing any requested full-profile package must fail this list.
for symbol in \
	CONFIG_PACKAGE_daed \
	CONFIG_PACKAGE_luci-app-daed \
	CONFIG_PACKAGE_luci-app-openclash \
	CONFIG_PACKAGE_luci-app-passwall \
	CONFIG_PACKAGE_adguardhome \
	CONFIG_PACKAGE_kmod-wireguard \
	CONFIG_PACKAGE_wireguard-tools \
	CONFIG_PACKAGE_luci-proto-wireguard \
	CONFIG_PACKAGE_tailscale \
	CONFIG_PACKAGE_ttyd \
	CONFIG_PACKAGE_luci-app-ttyd \
	CONFIG_PACKAGE_ddns-scripts \
	CONFIG_PACKAGE_ddns-scripts-cloudflare \
	CONFIG_PACKAGE_luci-app-ddns \
	CONFIG_PACKAGE_watchcat \
	CONFIG_PACKAGE_luci-app-watchcat \
	CONFIG_PACKAGE_vlmcsd \
	CONFIG_PACKAGE_luci-app-vlmcsd \
	CONFIG_PACKAGE_python3 \
	CONFIG_PACKAGE_python3-pip \
	CONFIG_PACKAGE_python3-openssl \
	CONFIG_PACKAGE_python3-sqlite3 \
	CONFIG_PACKAGE_luci-theme-argon \
	CONFIG_PACKAGE_luci-app-argon-config \
	CONFIG_PACKAGE_luci-i18n-argon-config-zh-cn \
	CONFIG_PACKAGE_fancontrol \
	CONFIG_PACKAGE_luci-app-fancontrol \
	CONFIG_PACKAGE_luci-i18n-base-zh-cn \
	CONFIG_PACKAGE_luci-i18n-fancontrol-zh-cn \
	CONFIG_PACKAGE_luci-i18n-ttyd-zh-cn \
	CONFIG_PACKAGE_luci-i18n-ddns-zh-cn \
	CONFIG_PACKAGE_luci-i18n-watchcat-zh-cn \
	CONFIG_PACKAGE_luci-i18n-vlmcsd-zh-cn \
	CONFIG_PACKAGE_curl \
	CONFIG_PACKAGE_nano \
	CONFIG_PACKAGE_ethtool \
	CONFIG_PACKAGE_ip-full \
	CONFIG_PACKAGE_iperf3 \
	CONFIG_PACKAGE_tcpdump \
	CONFIG_PACKAGE_usbutils \
	CONFIG_PACKAGE_pciutils; do
	assert_effective_y full "$symbol"
done

assert_not_effective_y full CONFIG_PACKAGE_luci-app-daede
assert_effective_n full CONFIG_PACKAGE_wpad-openssl
assert_effective_n rescue CONFIG_PACKAGE_wpad-openssl

# Rescue retains only recovery-oriented services and its storage/display stack.
for symbol in \
	CONFIG_PACKAGE_luci \
	CONFIG_PACKAGE_luci-i18n-base-zh-cn \
	CONFIG_PACKAGE_luci-theme-argon \
	CONFIG_KERNEL_DEBUG_INFO \
	CONFIG_KERNEL_DEBUG_INFO_BTF \
	CONFIG_PACKAGE_dropbear \
	CONFIG_PACKAGE_firewall4 \
	CONFIG_PACKAGE_dnsmasq-full \
	CONFIG_PACKAGE_kmod-usb3 \
	CONFIG_PACKAGE_kmod-usb-storage \
	CONFIG_PACKAGE_kmod-usb-storage-uas \
	CONFIG_PACKAGE_kmod-nvme \
	CONFIG_PACKAGE_block-mount \
	CONFIG_PACKAGE_kmod-fb-tft \
	CONFIG_PACKAGE_fbtest \
	CONFIG_PACKAGE_fancontrol \
	CONFIG_PACKAGE_luci-app-fancontrol \
	CONFIG_PACKAGE_curl \
	CONFIG_PACKAGE_nano; do
	assert_effective_y rescue "$symbol"
done

# These common or target-default selections must be explicitly overridden by rescue.
for symbol in \
	CONFIG_KERNEL_BPF_EVENTS \
	CONFIG_KERNEL_BPF_STREAM_PARSER \
	CONFIG_KERNEL_CGROUP_BPF \
	CONFIG_KERNEL_XDP_SOCKETS \
	CONFIG_PACKAGE_kmod-sched-bpf \
	CONFIG_PACKAGE_kmod-veth \
	CONFIG_PACKAGE_kmod-xdp-sockets-diag \
	CONFIG_PACKAGE_kmod-tun \
	CONFIG_PACKAGE_kmod-wireguard \
	CONFIG_PACKAGE_wireguard-tools \
	CONFIG_PACKAGE_luci-proto-wireguard \
	CONFIG_PACKAGE_kmod-nft-socket \
	CONFIG_PACKAGE_kmod-nft-tproxy \
	CONFIG_PACKAGE_bridger \
	CONFIG_PACKAGE_nvme-cli \
	CONFIG_PACKAGE_smartmontools; do
	assert_effective_n rescue "$symbol"
done

# Rescue must not acquire the full profile's proxy, VPN, Python, KMS, or diagnostics.
for symbol in \
	CONFIG_PACKAGE_dae \
	CONFIG_PACKAGE_daed \
	CONFIG_PACKAGE_luci-app-daed \
	CONFIG_PACKAGE_luci-app-daede \
	CONFIG_PACKAGE_luci-app-openclash \
	CONFIG_PACKAGE_luci-app-passwall \
	CONFIG_PACKAGE_ddns-scripts-cloudflare \
	CONFIG_PACKAGE_adguardhome \
	CONFIG_PACKAGE_tailscale \
	CONFIG_PACKAGE_bridger \
	CONFIG_PACKAGE_kmod-wireguard \
	CONFIG_PACKAGE_wireguard-tools \
	CONFIG_PACKAGE_luci-proto-wireguard \
	CONFIG_PACKAGE_python3 \
	CONFIG_PACKAGE_python3-pip \
	CONFIG_PACKAGE_python3-openssl \
	CONFIG_PACKAGE_python3-sqlite3 \
	CONFIG_PACKAGE_vlmcsd \
	CONFIG_PACKAGE_luci-app-vlmcsd \
	CONFIG_PACKAGE_ethtool \
	CONFIG_PACKAGE_ip-full \
	CONFIG_PACKAGE_iperf3 \
	CONFIG_PACKAGE_tcpdump \
	CONFIG_PACKAGE_usbutils \
	CONFIG_PACKAGE_pciutils; do
	assert_not_effective_y rescue "$symbol"
done

# Full profile keeps daed only (no standalone dae package; no iStore).
assert_not_effective_y full CONFIG_PACKAGE_dae
assert_not_effective_y full CONFIG_PACKAGE_luci-app-store

for file in "$common" "$root/configs/full.config" "$root/configs/rescue.config"; do
	if grep -E '^#? ?CONFIG_PACKAGE_python3-(ssl|json)(=| )' "$file"; then
		fail "invented Python package symbol in $file"
	fi
	assert_no_enabled_wifi "$file"
done

printf '%s\n' 'PASS: static full and rescue config fragments'

full_manifest=$(find_manifest full "${FULL_MANIFEST:-}")
rescue_manifest=$(find_manifest rescue "${RESCUE_MANIFEST:-}")
test -z "$full_manifest" || validate_manifest full "$full_manifest"
test -z "$rescue_manifest" || validate_manifest rescue "$rescue_manifest"

validate_resolved_configs
