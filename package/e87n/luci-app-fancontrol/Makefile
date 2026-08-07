include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-fancontrol
PKG_VERSION:=1.0
PKG_RELEASE:=2
PKG_LICENSE:=MIT
PKG_MAINTAINER:=E87N firmware maintainers
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-fancontrol
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI Fan Control Center (dynamic UI)
  DEPENDS:=+luci-base +luci-lua-runtime +fancontrol
endef

define Package/luci-app-fancontrol/description
Stock E87N dynamic fan control LuCI page: live temperature/duty display,
mode cards, draggable temperature curve, and manual duty control.
endef

define Build/Compile
endef

define Package/luci-app-fancontrol/install
	$(INSTALL_DIR) \
		$(1)/usr/lib/lua/luci/controller \
		$(1)/usr/lib/lua/luci/view/fancontrol \
		$(1)/www/luci-static/resources/view
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/controller/fancontrol.lua \
		$(1)/usr/lib/lua/luci/controller/fancontrol.lua
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/view/fancontrol/main.htm \
		$(1)/usr/lib/lua/luci/view/fancontrol/main.htm
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/fancontrol.css \
		$(1)/www/luci-static/resources/view/fancontrol.css
endef

$(eval $(call BuildPackage,luci-app-fancontrol))
