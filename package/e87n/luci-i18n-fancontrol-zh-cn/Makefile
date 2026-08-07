include $(TOPDIR)/rules.mk

PKG_NAME:=luci-i18n-fancontrol-zh-cn
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=E87N firmware maintainers
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/luci-i18n-fancontrol-zh-cn
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=Translations
  TITLE:=luci-app-fancontrol - zh-cn
  DEPENDS:=+luci-app-fancontrol
endef

define Package/luci-i18n-fancontrol-zh-cn/description
Prebuilt Simplified Chinese catalogue for the stock E87N fan control UI.
endef

define Build/Compile
endef

define Package/luci-i18n-fancontrol-zh-cn/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/i18n
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/i18n/fancontrol.zh-cn.lmo \
		$(1)/usr/lib/lua/luci/i18n/fancontrol.zh-cn.lmo
endef

$(eval $(call BuildPackage,luci-i18n-fancontrol-zh-cn))
