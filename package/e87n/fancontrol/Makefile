include $(TOPDIR)/rules.mk

PKG_NAME:=fancontrol
PKG_VERSION:=1
PKG_RELEASE:=2
PKG_LICENSE:=MIT
PKG_MAINTAINER:=E87N firmware maintainers
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/fancontrol
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=E87N PWM fan controller
  DEPENDS:=+kmod-hwmon-pwmfan +uci +procd
endef

define Package/fancontrol/description
Original POSIX shell fan controller and its procd integration.
endef

define Build/Compile
endef

define Package/fancontrol/conffiles
/etc/config/fancontrol
endef

define Package/fancontrol/install
	$(INSTALL_DIR) $(1)/usr/sbin $(1)/etc/config $(1)/etc/init.d
	$(INSTALL_BIN) ./files/usr/sbin/fancontrol $(1)/usr/sbin/fancontrol
	$(INSTALL_CONF) ./files/etc/config/fancontrol $(1)/etc/config/fancontrol
	$(INSTALL_BIN) ./files/etc/init.d/fancontrol $(1)/etc/init.d/fancontrol
endef

$(eval $(call BuildPackage,fancontrol))
