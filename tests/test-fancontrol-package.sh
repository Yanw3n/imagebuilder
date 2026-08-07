#!/usr/bin/env sh
# shellcheck disable=SC2016
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
daemon="$root/package/e87n/fancontrol/files/usr/bin/fancontrol"
init="$root/package/e87n/fancontrol/files/etc/init.d/fancontrol"
cfg="$root/package/e87n/fancontrol/files/etc/config/fancontrol"
fan_mk="$root/package/e87n/fancontrol/Makefile"
luci_mk="$root/package/e87n/luci-app-fancontrol/Makefile"
controller="$root/package/e87n/luci-app-fancontrol/files/usr/lib/lua/luci/controller/fancontrol.lua"
view="$root/package/e87n/luci-app-fancontrol/files/usr/lib/lua/luci/view/fancontrol/main.htm"
css="$root/package/e87n/luci-app-fancontrol/files/www/luci-static/resources/view/fancontrol.css"
lmo="$root/package/e87n/luci-i18n-fancontrol-zh-cn/files/usr/lib/lua/luci/i18n/fancontrol.zh-cn.lmo"
i18n_mk="$root/package/e87n/luci-i18n-fancontrol-zh-cn/Makefile"

fail() { printf '%s\n' "$*" >&2; exit 1; }

test -f "$daemon" || fail 'missing vendor fancontrol binary'
test "$(wc -c <"$daemon")" -gt 10000 || fail 'fancontrol binary too small'
! head -c 2 "$daemon" | grep -q '#!' || fail 'fancontrol looks like a shell script, expected vendor ELF'
# Vendor controller is a real aarch64 ELF (not a shell rewrite).
elf_magic=$(mktemp)
elf_head=$(mktemp)
printf '\177ELF' >"$elf_magic"
head -c 4 "$daemon" >"$elf_head"
cmp -s "$elf_magic" "$elf_head" || { rm -f "$elf_magic" "$elf_head"; fail 'fancontrol is not an ELF binary'; }
rm -f "$elf_magic" "$elf_head"
test -f "$init" || fail 'missing fancontrol init script'
test -f "$cfg" || fail 'missing fancontrol UCI defaults'
test -f "$controller" || fail 'missing LuCI controller'
test -f "$view" || fail 'missing dynamic LuCI main.htm'
test -f "$css" || fail 'missing fancontrol.css'
test -f "$lmo" || fail 'missing zh-cn LMO'
test -f "$i18n_mk" || fail 'missing luci-i18n-fancontrol-zh-cn Makefile'
grep -q 'BuildPackage,luci-i18n-fancontrol-zh-cn' "$i18n_mk" || fail 'i18n Makefile lacks BuildPackage'

grep -q 'PROG=/usr/bin/\$NAME' "$init" || fail 'init does not run /usr/bin/fancontrol'
grep -q 'procd_append_param command -M' "$init" || fail 'init does not pass -M mode to the daemon'
grep -q "option mode '1'" "$cfg" || fail 'default UCI mode is not balanced (1)'
grep -q 'curve_balanced' "$cfg" || fail 'default UCI lacks balanced curve'
grep -q 'thermal_zone0/temp' "$cfg" || fail 'default UCI lacks thermal path'
grep -q 'pwm1' "$cfg" || fail 'default UCI lacks pwm path'

grep -q 'luci.controller.fancontrol' "$controller" || fail 'controller package name missing'
grep -q 'action_api' "$controller" || fail 'controller lacks API entry'
grep -q 'get_status' "$controller" || fail 'controller lacks get_status'
grep -q 'set_curve' "$controller" || fail 'controller lacks set_curve'
grep -q 'fancontrol_api' "$controller" || fail 'controller lacks fancontrol_api route'

grep -q 'Fan Control Center' "$view" || fail 'view lacks Fan Control Center title'
grep -q 'curveChart' "$view" || fail 'view lacks curve canvas'
grep -q 'fancontrol_api' "$view" || fail 'view does not call fancontrol_api'
grep -q 'data-mode=' "$view" || fail 'view lacks mode cards'

grep -q 'PKGARCH:=aarch64_cortex-a53' "$fan_mk" || fail 'fancontrol package is not arch-scoped'
grep -q 'files/usr/bin/fancontrol' "$fan_mk" || fail 'fancontrol Makefile does not install the vendor binary'
grep -q 'luci-lua-runtime' "$luci_mk" || fail 'LuCI app does not depend on luci-lua-runtime'
grep -q 'BuildPackage,luci-app-fancontrol' "$luci_mk" || fail 'LuCI Makefile lacks BuildPackage'
grep -q 'controller/fancontrol.lua' "$luci_mk" || fail 'LuCI Makefile does not install controller'

# No leftover modern/static-only assets that would shadow the dynamic UI.
! test -e "$root/package/e87n/luci-app-fancontrol/htdocs/luci-static/resources/view/fancontrol.js" || fail 'legacy JS view still present'
! test -e "$root/package/e87n/luci-app-fancontrol/root/usr/libexec/rpcd/fancontrol" || fail 'rpcd helper still present'
! test -e "$root/package/e87n/fancontrol/files/usr/sbin/fancontrol" || fail 'old shell daemon still present'

printf 'PASS: vendor fancontrol package and dynamic LuCI UI\n'
