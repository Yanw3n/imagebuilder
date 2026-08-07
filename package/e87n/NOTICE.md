# E87N fan-control provenance

The fan controller and dynamic LuCI UI under `package/e87n` are recovered
from the running stock E87N OpenWrt image (Hiveton / EdgePi HigoOS build)
via SSH for packaging into this ImmortalWrt firmware tree.

Recovered components:

| Path | Role |
| --- | --- |
| `fancontrol/files/usr/bin/fancontrol` | Vendor aarch64 daemon (`-M` modes) |
| `fancontrol/files/etc/init.d/fancontrol` | procd wrapper (`-M "$mode"`) |
| `fancontrol/files/etc/config/fancontrol` | UCI defaults from the live device |
| `luci-app-fancontrol/files/usr/lib/lua/luci/controller/fancontrol.lua` | LuCI controller + JSON API |
| `luci-app-fancontrol/files/usr/lib/lua/luci/view/fancontrol/main.htm` | Dynamic Fan Control Center page |
| `luci-app-fancontrol/files/www/luci-static/resources/view/fancontrol.css` | Page styles |
| `luci-i18n-fancontrol-zh-cn/files/usr/lib/lua/luci/i18n/fancontrol.zh-cn.lmo` | Prebuilt zh-cn catalogue |

Binary SHA-256 (matches design-doc vendor hash):

`DEDEA6CDB2FD7A65614501D2FB8C1FD58E3A1B16CC159EC07D775E5F78604FF8`

Upstream stock package metadata attributed the daemon to JiaY-shi and licensed
it as MIT. LuCI assets were taken from the installed `luci-app-fancontrol`
and `luci-i18n-fancontrol-zh-cn` packages on the live router.
