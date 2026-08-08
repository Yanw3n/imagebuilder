# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2023 ImmortalWrt.org
#
# E87N overlay: keep QiuSimons wing/core pins and BTF choice, but embed the
# prebuilt daed web UI from GitHub releases. The upstream QiuSimons Build/Prepare
# builds the UI with pnpm without `set -e`, so a failed/empty frontend install
# still stamps prepare and later fails with:
#   webrender.go: pattern web: cannot embed directory web: contains no embeddable files

include $(TOPDIR)/rules.mk

PKG_NAME:=daed
PKG_VERSION:=2026.07.31
DAED_VERSION:=daed-671e65d
WING_VERSION:=wing-dc50308
CORE_VERSION:=core-caa6f5e
WING_HASH_SHORT:=$(shell echo $(WING_VERSION) | cut -d- -f2)
CORE_HASH_SHORT:=$(shell echo $(CORE_VERSION) | cut -d- -f2)
PKG_RELEASE:=2

PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.gz
PKG_SOURCE_PROTO:=git
PKG_SOURCE_VERSION:=671e65d2fdcd62fe6a3ec18ecda209c5addea898
PKG_SOURCE_URL:=https://github.com/daeuniverse/daed.git
PKG_MIRROR_HASH:=skip

PKG_LICENSE:=AGPL-3.0-only MIT
PKG_LICENSE_FILES:=LICENSE wing/LICENSE
PKG_MAINTAINER:=Tianling Shen <cnsztl@immortalwrt.org>

DAED_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)
PKG_BUILD_DIR:=$(DAED_BUILD_DIR)/wing

PKG_BUILD_DEPENDS:=golang/host bpf-headers
PKG_BUILD_PARALLEL:=1
PKG_BUILD_FLAGS:=no-mips16

GO_PKG:=github.com/daeuniverse/dae-wing

GO_PKG_LDFLAGS:= \
	-s -w -buildid= \
	-linkmode external -extldflags '-static -Wl,-s' \
	-X '$(GO_PKG)/db.AppDescription=$(PKG_NAME) is a integration solution of dae, API and UI.'
GO_PKG_LDFLAGS_X:= \
	$(GO_PKG)/db.AppName=$(PKG_NAME) \
	$(GO_PKG)/db.AppVersion=$(DAED_VERSION)_$(WING_VERSION)_$(CORE_VERSION)
GO_PKG_TAGS:=embedallowed,trace

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/bpf.mk
include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk

GO_PKG_BUILD_VARS+= \
	GOFLAGS="-trimpath -buildvcs=false -pgo=auto"

GO_PKG_TARGET_VARS+= \
	CGO_LDFLAGS="$(TARGET_LDFLAGS) -static -Wl,-s" \
	GOEXPERIMENT=newinliner,simd

define Package/daed/Default
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Web Servers/Proxies
  URL:=https://github.com/daeuniverse/daed
endef

define Package/daed
  $(call Package/daed/Default)
  TITLE:=A Modern Dashboard For dae
  DEPENDS:=$(GO_ARCH_DEPENDS) \
    +ca-bundle +kmod-sched-core +kmod-sched-bpf \
    +kmod-veth +v2ray-geoip +v2ray-geosite \
    +@KERNEL_XDP_SOCKETS \
    +DAED_USE_VMLINUX_BTF:vmlinux-btf
endef

define Package/daed/config
	choice
		prompt "BTF source for CO-RE"
		default DAED_USE_KERNEL_BTF
		depends on PACKAGE_daed

	config DAED_USE_KERNEL_BTF
		bool "Use kernel BTF (integrated)"
		depends on KERNEL_DEBUG_INFO_BTF

	config DAED_USE_VMLINUX_BTF
		bool "Use vmlinux-btf package"
	endchoice
endef

define Package/daed/description
  daed is a backend of dae, provides a method to bundle arbitrary
  frontend, dae and geodata into one binary.
endef

define Package/daed/conffiles
/etc/daed/wing.db
/etc/config/daed
endef

# Prebuilt UI from daeuniverse/daed v1.27.0 (same asset immortalwrt packages uses).
WEB_FILE:=$(PKG_NAME)-web-1.27.0.zip
define Download/daed-web
  URL:=https://github.com/daeuniverse/daed/releases/download/v1.27.0
  URL_FILE:=web.zip
  FILE:=$(WEB_FILE)
  HASH:=da8755fb2cabfab392854e807e385b12d9e9842d6c8b5e347284d1ae0e582bfc
endef

define Build/Prepare
	( set -euo pipefail ; \
		rm -rf $(DAED_BUILD_DIR) ; \
		mkdir -p $(DAED_BUILD_DIR) ; \
		$(TAR) --strip-components=1 -C $(DAED_BUILD_DIR) -xzf $(DL_DIR)/$(PKG_NAME)-$(PKG_VERSION).tar.gz ; \
		git clone https://github.com/daeuniverse/dae-wing $(PKG_BUILD_DIR) ; \
		git -C $(PKG_BUILD_DIR) checkout $(WING_HASH_SHORT) ; \
		rm -rf $(PKG_BUILD_DIR)/dae-core ; \
		git clone https://github.com/daeuniverse/dae $(PKG_BUILD_DIR)/dae-core ; \
		git -C $(PKG_BUILD_DIR)/dae-core checkout $(CORE_HASH_SHORT) ; \
		pushd $(PKG_BUILD_DIR)/dae-core ; \
			git submodule update --init ; \
			go get -u=patch ; \
			go mod tidy ; \
		popd ; \
		pushd $(PKG_BUILD_DIR) ; \
			go get -u=patch ; \
			go mod tidy ; \
			wget -qO default.pgo "https://github.com/QiuSimons/luci-app-dae/raw/refs/heads/kix/dae/pprof/default.pgo" ; \
		popd ; \
		mkdir -p $(PKG_BUILD_DIR)/webrender ; \
		unzip -q -d $(PKG_BUILD_DIR)/webrender/ $(DL_DIR)/$(WEB_FILE) ; \
		test -f $(PKG_BUILD_DIR)/webrender/web/index.html ; \
		find $(PKG_BUILD_DIR)/webrender/web -type f -size +4k ! -name "*.gz" ! -name "*.woff"  ! -name "*.woff2" -exec sh -c '\
			gzip -9 -k "{}"; \
			if [ "$$$$(stat -c %s "{}")" -lt "$$$$(stat -c %s "{}.gz")" ]; then \
				rm "{}.gz"; \
			else \
				rm "{}"; \
			fi' \
		";" ; \
	)
endef

DAE_CFLAGS:= \
	-O2 -Wall -Werror \
	-DMAX_MATCH_SET_LEN=1024 \
	-I$(BPF_HEADERS_DIR)/tools/lib \
	-I$(BPF_HEADERS_DIR)/arch/$(BPF_KARCH)/include/asm/mach-generic

define Build/Compile
	( set -euo pipefail ; \
		pushd $(PKG_BUILD_DIR) ; \
		export \
		$(GO_GENERAL_BUILD_CONFIG_VARS) \
		$(GO_PKG_BUILD_CONFIG_VARS) \
		$(GO_PKG_BUILD_VARS) ; \
		go generate ./... ; \
		cd dae-core ; \
		export \
		BPF_CLANG="$(CLANG)" \
		BPF_STRIP_FLAG="-strip=$(LLVM_STRIP)" \
		BPF_CFLAGS="$(DAE_CFLAGS)" \
		BPF_TARGET="bpfel,bpfeb" \
		BPF_TRACE_TARGET="$(GO_ARCH)" ; \
		go generate ./control/control.go ; \
		go generate ./trace/trace.go ; \
		popd ; \
	)
	$(call GoPackage/Build/Compile)
endef

define Package/daed/install
	$(call GoPackage/Package/Install/Bin,$(PKG_INSTALL_DIR))
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/dae-wing $(1)/usr/bin/daed

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) $(CURDIR)/files/daed.config $(1)/etc/config/daed

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(CURDIR)/files/daed.init $(1)/etc/init.d/daed
endef

$(eval $(call Download,daed-web))
$(eval $(call GoBinPackage,daed))
$(eval $(call BuildPackage,daed))
