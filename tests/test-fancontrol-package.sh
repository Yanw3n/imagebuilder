#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
daemon="$root/package/e87n/fancontrol/files/usr/sbin/fancontrol"
init="$root/package/e87n/fancontrol/files/etc/init.d/fancontrol"
luci_mk="$root/package/e87n/luci-app-fancontrol/Makefile"
luci_js="$root/package/e87n/luci-app-fancontrol/htdocs/luci-static/resources/view/fancontrol.js"
acl="$root/package/e87n/luci-app-fancontrol/root/usr/share/rpcd/acl.d/luci-app-fancontrol.json"
menu="$root/package/e87n/luci-app-fancontrol/root/usr/share/luci/menu.d/luci-app-fancontrol.json"
po="$root/package/e87n/luci-app-fancontrol/po/zh_Hans/fancontrol.po"

fail() { printf '%s\n' "$*" >&2; exit 1; }
test -x "$daemon" || fail 'missing executable original fancontrol daemon'
test -f "$root/package/e87n/fancontrol/Makefile" || fail 'missing fancontrol Makefile'
grep -q '^define Build/Compile$' "$root/package/e87n/fancontrol/Makefile" || fail 'file-only fancontrol package lacks explicit Build/Compile'
grep -q '^include \$(TOPDIR)/feeds/luci/luci.mk$' "$luci_mk" || fail 'LuCI package does not use luci.mk'
test -f "$luci_js" || fail 'missing modern LuCI JavaScript view'
test -f "$acl" || fail 'missing rpcd ACL'
test -f "$menu" || fail 'missing LuCI menu registration'
test -f "$po" || fail 'missing Chinese PO source'
grep -q '"Language: zh_Hans\\n"' "$po" || fail 'Chinese PO does not register zh_Hans'
grep -q 'msgid "Fan Control"' "$po" || fail 'Chinese PO lacks fan-control strings'
! test -e "$root/package/e87n/fancontrol/files/usr/bin/fancontrol" || fail 'vendor ELF remains'
! find "$root/package/e87n" -type f -name '*.lmo' | grep -q . || fail 'precompiled LMO remains'
! find "$root/package/e87n/luci-app-fancontrol" -type f \( -path '*/luci/controller/*' -o -path '*/luci/view/*' \) | grep -q . || fail 'legacy Lua LuCI assets remain'
! grep -R -E 'luci\.controller|module\("luci|write_json|formvalue' "$root/package/e87n/luci-app-fancontrol" >/dev/null 2>&1 || fail 'legacy GET mutation API remains'
grep -q 'rpc.declare' "$luci_js" || fail 'LuCI view does not use RPC'
grep -q 'handleSaveApply' "$luci_js" || fail 'LuCI view lacks UCI apply lifecycle'
grep -q 'catch' "$luci_js" || fail 'LuCI view does not report RPC failures'
grep -q "'require uci';" "$luci_js" || fail 'LuCI view does not declare the uci module'
grep -q "method: 'restart'" "$luci_js" || fail 'LuCI view does not use the scoped restart RPC'
! grep -q "object: 'service'" "$luci_js" || fail 'LuCI view still calls service.set'
grep -q '"restart":{}' "$root/package/e87n/luci-app-fancontrol/root/usr/libexec/rpcd/fancontrol" || fail 'rpcd fancontrol plugin does not publish restart'
grep -q '"fancontrol": \[ "restart" \]' "$acl" || fail 'ACL does not grant scoped fancontrol restart'
! grep -q '"service": \[ "set" \]' "$acl" || fail 'ACL still grants broad service.set'
awk '/"read"/,/"write"/' "$acl" | grep -q '"uci": \[ "fancontrol" \]' || fail 'ACL lacks read access to fancontrol UCI'
test "$(grep -c 'BuildPackage' "$luci_mk")" = 0 || fail 'luci.mk package has duplicate BuildPackage registration'
grep -q 'config_load' "$init" || fail 'reload service does not load UCI configuration'
grep -q 'procd_kill' "$init" || fail 'init service does not remove the procd instance'
grep -q 'rc_procd start_service' "$init" || fail 'reload service does not use the rc.common procd registration wrapper'
! awk '/^restart_service\(\)/,/^}/ { print } /^reload_service\(\)/,/^}/ { print }' "$init" | grep -q '^[[:space:]]*start_service' || fail 'reload lifecycle calls start_service directly'
! grep -q '^stop_service()' "$init" || fail 'init duplicates rc.common generic procd stop hook'
grep -q 'pwmfan' "$daemon" || fail 'daemon does not resolve pwmfan hwmon by name'
grep -q 'safe_stop' "$daemon" || fail 'daemon lacks safe stop strategy'
grep -q 'thermal_zone' "$daemon" || fail 'daemon does not resolve CPU thermal zones'

init_log=$(mktemp)
MOCK_ENABLE=1
config_load() { printf 'config_load:%s\n' "$1" >> "$init_log"; }
config_get_bool() { eval "$1=$MOCK_ENABLE"; }
logger() { printf 'logger:%s\n' "$*" >> "$init_log"; }
procd_kill() { printf 'procd_kill:%s\n' "$1" >> "$init_log"; }
procd_open_instance() { printf 'open_instance\n' >> "$init_log"; }
procd_set_param() { printf 'set_param:%s\n' "$1" >> "$init_log"; }
procd_close_instance() { printf 'close_instance\n' >> "$init_log"; }
rc_procd() { printf 'rc_procd:%s\n' "$1" >> "$init_log"; "$1"; }
. "$init"

reload_service
grep -q '^procd_kill:fancontrol$' "$init_log" || fail 'enabled reload did not delete the old procd service'
grep -q '^rc_procd:start_service$' "$init_log" || fail 'enabled reload did not register a fresh procd service'
grep -q '^open_instance$' "$init_log" || fail 'enabled reload did not create a service instance'

: > "$init_log"
MOCK_ENABLE=0
reload_service
grep -q '^procd_kill:fancontrol$' "$init_log" || fail 'disabled reload did not delete the procd service'
! grep -q '^rc_procd:start_service$' "$init_log" || fail 'disabled reload registered a new procd service'

tmp=$(mktemp -d)
trap 'rm -f "$init_log"; rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/hwmon/hwmon7" "$tmp/thermal/thermal_zone3"
printf 'pwmfan\n' > "$tmp/hwmon/hwmon7/name"
printf '0\n' > "$tmp/hwmon/hwmon7/pwm1"
printf 'cpu-thermal\n' > "$tmp/thermal/thermal_zone3/type"
printf '50000\n' > "$tmp/thermal/thermal_zone3/temp"

FANCONTROL_LIBRARY=1 \
HWMON_ROOT="$tmp/hwmon" THERMAL_ROOT="$tmp/thermal" \
STATUS_FILE="$tmp/status" FANCONTROL_LOG="$tmp/log" \
. "$daemon"

enable=1 mode=1 manual_speed=40 interval=1
curve_silent='30:0,70:40'
curve_balanced='30:20,70:80'
curve_performance='30:60,70:100'
curve_custom='30:10,70:90'
validate_config || fail 'valid configuration rejected'
resolve_hardware || fail 'pwmfan and cpu thermal hardware not resolved'
test "$fan_file" = "$tmp/hwmon/hwmon7/pwm1" || fail 'wrong pwm file resolved'
test "$thermal_file" = "$tmp/thermal/thermal_zone3/temp" || fail 'wrong thermal file resolved'
test "$(interpolate_curve "$curve_balanced" 50)" = 50 || fail 'curve interpolation is wrong'
test "$(percent_to_pwm 50)" = 128 || fail 'PWM conversion is wrong'
apply_once || fail 'valid thermal control cycle failed'
test "$(cat "$tmp/hwmon/hwmon7/pwm1")" = 128 || fail 'control cycle wrote wrong PWM'
safe_stop
test "$(cat "$tmp/hwmon/hwmon7/pwm1")" = 255 || fail 'safe stop did not set full PWM'

fan_file=/stale/pwm1
printf '0\n' > "$tmp/hwmon/hwmon7/pwm1"
HWMON_ROOT="$tmp/empty-hwmon"
mkdir -p "$HWMON_ROOT"
if resolve_hardware; then fail 'no-hwmon condition unexpectedly resolved'; fi
test -z "$fan_file" || fail 'no-hwmon condition retained stale PWM path'
test "$(cat "$tmp/hwmon/hwmon7/pwm1")" = 255 || fail 'no-hwmon failure did not invoke safe full PWM'
grep -q 'pwmfan pwm1 not found' "$tmp/log" || fail 'no-hwmon condition was not logged clearly'
grep -q '"error":"pwmfan pwm1 not found"' "$tmp/status" || fail 'no-hwmon condition did not expose an error status'

HWMON_ROOT="$tmp/hwmon"
THERMAL_ROOT="$tmp/empty-thermal"
mkdir -p "$THERMAL_ROOT"
if resolve_hardware; then fail 'missing CPU thermal zone unexpectedly resolved'; fi
grep -q '"error":"CPU thermal zone not found"' "$tmp/status" || fail 'thermal discovery reason was overwritten by safe-stop status'
grep -q "safe_stop 'invalid configuration after reload'" "$daemon" || fail 'reload validation does not preserve an explicit fault reason'

printf 'PASS: fancontrol package\n'
