include $(TOPDIR)/rules.mk

PKG_NAME:=fancontrol
PKG_VERSION:=1
PKG_RELEASE:=4
PKG_LICENSE:=MIT
PKG_MAINTAINER:=E87N firmware maintainers

# Vendor aarch64 controller recovered from the running E87N stock image.
PKGARCH:=aarch64_cortex-a53

include $(INCLUDE_DIR)/package.mk

define Package/fancontrol
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=E87N PWM fan controller (vendor)
  DEPENDS:=@TARGET_mediatek_filogic +kmod-hwmon-pwmfan +procd
endef

define Package/fancontrol/description
Vendor aarch64 fancontrol daemon used by the stock E87N image, with the
matching procd init script and UCI defaults for pwm-fan + thermal_zone0.
endef

define Build/Compile
endef

define Package/fancontrol/conffiles
/etc/config/fancontrol
endef

define Package/fancontrol/install
	$(INSTALL_DIR) $(1)/usr/bin $(1)/etc/config $(1)/etc/init.d
	$(INSTALL_BIN) ./files/usr/bin/fancontrol $(1)/usr/bin/fancontrol
	$(INSTALL_CONF) ./files/etc/config/fancontrol $(1)/etc/config/fancontrol
	$(INSTALL_BIN) ./files/etc/init.d/fancontrol $(1)/etc/init.d/fancontrol
endef

$(eval $(call BuildPackage,fancontrol))
