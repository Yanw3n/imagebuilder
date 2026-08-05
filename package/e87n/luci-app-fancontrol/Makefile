include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-fancontrol
PKG_VERSION:=1
PKG_RELEASE:=2
PKG_LICENSE:=MIT
PKG_MAINTAINER:=E87N firmware maintainers

LUCI_TITLE:=Fan control
LUCI_DESCRIPTION:=Modern LuCI configuration and status page for fancontrol
LUCI_DEPENDS:=+fancontrol +rpcd
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
