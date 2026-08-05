include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=kmod-fb-tft-nv3007
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define KernelPackage/fb-tft-nv3007
  SUBMENU:=Video Support
  TITLE:=FB driver for the NV3007 LCD controller
  DEPENDS:=@GPIO_SUPPORT +kmod-fb-tft
  KCONFIG:=CONFIG_FB_TFT_NV3007
  FILES:=$(LINUX_DIR)/drivers/staging/fbtft/fb_nv3007.ko
  AUTOLOAD:=$(call AutoLoad,09,fb_nv3007)
endef

define KernelPackage/fb-tft-nv3007/description
  Framebuffer driver for the New Vision NV3007 LCD controller.
endef

$(eval $(call KernelPackage,fb-tft-nv3007))
