# EdgePi E87N daede Firmware Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Build reproducible ImmortalWrt 25.12 sysupgrade images for EdgePi E87N with Linux 6.12, built-in BTF, dae/daed, Python 3, requested LuCI applications, and the recovered fan controller.

**Architecture:** A public fork of kenzok8/imagebuilder becomes a full-source builder instead of an ImageBuilder wrapper. A pinned ImmortalWrt checkout receives an E87N platform patch, source overlays, a local package feed, deterministic full/rescue configs, and artifact validators; GitHub Actions builds and publishes only validated sysupgrade images.

**Tech Stack:** GitHub Actions, Bash, GNU Make/Kconfig, ImmortalWrt/OpenWrt, Linux DTS/DTC, Python 3, ARM64 FIT/sysupgrade TAR, nftables/eBPF/BTF, LuCI.

## Global Constraints

- ImmortalWrt branch openwrt-25.12 at 3dacd2fb6a48c5963b1026c6a343ec7e67cbf810.
- packages feed at a5b67070eae7adf66e9c2285357272caad1c433b.
- LuCI feed at 3608386a77a41c167c8ee7a4221d787d4702d3c2.
- openwrt-daede at f2a451aee92e24efd5e0e953f09e8c43be457840.
- Fork baseline kenzok8/imagebuilder at 3ae519c988d88d4533c7a6f1b23c71fe82743c2a.
- Target mediatek/filogic; profile edgepi_e87n; board ID edgepi,e87n; ARM64 Cortex-A53.
- Flashable output updates only kernel and rootfs. Never package boot0/boot1, u-boot-env, factory, or fip.
- FIT kernel must remain below the existing 32 MiB kernel partition.
- Public Git must exclude the supplied firmware, backups, MAC addresses, serials, credentials, and router configuration.
- LAN defaults to 192.168.1.1; no password or external-service secret is embedded.
- Full and rescue builds are independently reproducible and independently validated.

---

## Repository Map

~~~text
.github/workflows/build-e87n.yml
configs/common.config
configs/full.config
configs/rescue.config
device/edgepi-e87n/source-overlay/
package/e87n/fancontrol/
package/e87n/luci-app-fancontrol/
patches/immortalwrt/
scripts/lib/common.sh
scripts/prepare-source.sh
scripts/build-e87n.sh
scripts/validate-e87n.sh
scripts/collect-artifacts.sh
tests/
tools/e87n-backup.sh
docs/e87n-build.md
docs/e87n-flash-and-recovery.md
versions.env
~~~

### Task 1: Establish the Fork Baseline and Repository Safety

**Files:**
- Create: .gitignore
- Create: versions.env
- Create: tests/test-repository-safety.sh
- Modify: README.md
- Remove: .github/workflows/build-image.yml
- Remove: scripts/build-image.sh

**Interfaces:**
- Consumes: environment variable FORK_URL containing the user's public fork HTTPS URL.
- Produces: fork checkout e87n-imagebuilder and immutable source variables in versions.env.

- [ ] **Step 1: Clone and verify the fork**

~~~bash
test -n "$FORK_URL"
git clone "$FORK_URL" e87n-imagebuilder
cd e87n-imagebuilder
git remote add upstream https://github.com/kenzok8/imagebuilder.git
git fetch upstream main
git merge-base --is-ancestor 3ae519c988d88d4533c7a6f1b23c71fe82743c2a HEAD
~~~

Expected: exit 0.

- [ ] **Step 2: Write the failing safety test**

~~~bash
#!/usr/bin/env bash
set -euo pipefail
test -f versions.env
grep -qx 'IMMORTALWRT_COMMIT=3dacd2fb6a48c5963b1026c6a343ec7e67cbf810' versions.env
for pattern in '*.img' '*.img.gz' '*factory*' '*boot0*' '*boot1*' '*fip*'; do
  test -z "$(git ls-files "$pattern")"
done
! git grep -IE '(BEGIN .*PRIVATE KEY|authkey-|tailscale.*key|password=)'
~~~

- [ ] **Step 3: Run it and confirm failure**

Run: bash tests/test-repository-safety.sh

Expected: FAIL because versions.env is absent.

- [ ] **Step 4: Add locked inputs and ignore rules**

versions.env:

~~~bash
IMMORTALWRT_REPO=https://github.com/immortalwrt/immortalwrt.git
IMMORTALWRT_BRANCH=openwrt-25.12
IMMORTALWRT_COMMIT=3dacd2fb6a48c5963b1026c6a343ec7e67cbf810
PACKAGES_COMMIT=a5b67070eae7adf66e9c2285357272caad1c433b
LUCI_COMMIT=3608386a77a41c167c8ee7a4221d787d4702d3c2
DAEDE_REPO=https://github.com/kenzok8/openwrt-daede.git
DAEDE_COMMIT=f2a451aee92e24efd5e0e953f09e8c43be457840
~~~

.gitignore:

~~~gitignore
/work/
/out/
/dl/
/.private/
/.config
*.bin
*.img
*.img.gz
*.itb
*.tar.gz
!package/e87n/fancontrol/files/usr/bin/fancontrol
~~~

Rewrite the README opening for E87N and delete the x86-only workflow/script.

- [ ] **Step 5: Verify and commit**

~~~bash
bash tests/test-repository-safety.sh
git add -A
git commit -m "build: establish E87N source-build baseline"
~~~

### Task 2: Prepare Exact ImmortalWrt Sources

**Files:**
- Create: scripts/lib/common.sh
- Create: scripts/prepare-source.sh
- Create: tests/test-prepare-source.sh

**Interfaces:**
- Consumes: versions.env, device overlays, local packages, patches.
- Produces: prepared source tree at WORK_DIR/immortalwrt and function apply_repo_overlays.

- [ ] **Step 1: Write the failing contract test**

~~~bash
#!/usr/bin/env bash
set -euo pipefail
source scripts/lib/common.sh
test "$(normalize_bool true)" = 1
test "$(normalize_bool false)" = 0
if normalize_bool invalid >/dev/null 2>&1; then exit 1; fi
bash -n scripts/prepare-source.sh
~~~

- [ ] **Step 2: Run it and confirm failure**

Run: bash tests/test-prepare-source.sh

Expected: FAIL because common.sh is absent.

- [ ] **Step 3: Implement common helpers**

~~~bash
#!/usr/bin/env bash
set -euo pipefail
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
require_file() { test -f "$1" || die "missing file: $1"; }
normalize_bool() {
  case "$1" in true|1|yes) printf '1\n';; false|0|no) printf '0\n';; *) return 2;; esac
}
apply_repo_overlays() {
  local source_dir=$1
  rsync -a device/edgepi-e87n/source-overlay/ "$source_dir/"
  rsync -a package/e87n/ "$source_dir/package/e87n/"
  for p in patches/immortalwrt/*.patch; do patch -d "$source_dir" -p1 < "$p"; done
}
~~~

- [ ] **Step 4: Implement pinned checkout**

prepare-source.sh must clone with --filter=blob:none --no-tags, detach at IMMORTALWRT_COMMIT, change packages and LuCI feed revisions to caret-pinned commits, run feeds update/install, clone openwrt-daede at DAEDE_COMMIT under package/feeds/daede, apply overlays, and assert all four HEAD values.

Core assertions:

~~~bash
test "$(git -C "$SOURCE_DIR" rev-parse HEAD)" = "$IMMORTALWRT_COMMIT"
grep -q "\^$PACKAGES_COMMIT" "$SOURCE_DIR/feeds.conf.default"
grep -q "\^$LUCI_COMMIT" "$SOURCE_DIR/feeds.conf.default"
test "$(git -C "$SOURCE_DIR/package/feeds/daede" rev-parse HEAD)" = "$DAEDE_COMMIT"
~~~

- [ ] **Step 5: Test and commit**

~~~bash
bash tests/test-prepare-source.sh
WORK_DIR="$PWD/work-test" bash scripts/prepare-source.sh
git add scripts/lib/common.sh scripts/prepare-source.sh tests/test-prepare-source.sh
git commit -m "build: prepare pinned ImmortalWrt sources"
~~~

Expected: exact commits are checked out and preparation exits 0.

### Task 3: Add the E87N DTS, Profile, Network, and Upgrade Path

**Files:**
- Create: device/edgepi-e87n/source-overlay/target/linux/mediatek/dts/mt7987a-edgepi-e87n.dts
- Create: patches/immortalwrt/0001-mediatek-filogic-add-edgepi-e87n.patch
- Create: tools/capture-e87n-network.sh
- Create: tests/test-e87n-platform.sh

**Interfaces:**
- Consumes: approved hardware inventory and current firmware DTB.
- Produces: target symbol CONFIG_TARGET_mediatek_filogic_DEVICE_edgepi_e87n; board ID edgepi,e87n; emmc_do_upgrade for kernel/rootfs.

- [ ] **Step 1: Write the failing platform test**

~~~bash
#!/usr/bin/env bash
set -euo pipefail
dts=device/edgepi-e87n/source-overlay/target/linux/mediatek/dts/mt7987a-edgepi-e87n.dts
test -f "$dts"
grep -q 'compatible = "edgepi,e87n", "mediatek,mt7987a", "mediatek,mt7987";' "$dts"
grep -q 'compatible = "pwm-fan";' "$dts"
grep -q 'compatible = "newvisionu,nv3007";' "$dts"
grep -q 'root=PARTLABEL=rootfs' "$dts"
grep -q 'define Device/edgepi_e87n' patches/immortalwrt/0001-mediatek-filogic-add-edgepi-e87n.patch
grep -q 'CI_KERNPART="kernel"' patches/immortalwrt/0001-mediatek-filogic-add-edgepi-e87n.patch
grep -q 'CI_ROOTPART="rootfs"' patches/immortalwrt/0001-mediatek-filogic-add-edgepi-e87n.patch
~~~

- [ ] **Step 2: Run it and confirm failure**

Run: bash tests/test-e87n-platform.sh

Expected: FAIL because the DTS is absent.

- [ ] **Step 3: Author the DTS**

Use mt7987a.dtsi and retain these exact behavioral anchors:

~~~dts
/ {
    model = "EdgePi E87N";
    compatible = "edgepi,e87n", "mediatek,mt7987a", "mediatek,mt7987";
    chosen {
        bootargs = "console=ttyS0,115200n1 fbcon=map:off fbcon=disable root=PARTLABEL=rootfs rootwait rootfstype=squashfs,f2fs";
    };
    fan: pwm-fan {
        compatible = "pwm-fan";
        pwms = <&pwm 1 50000 0>;
        status = "okay";
    };
};
&spi2 {
    status = "okay";
    display@0 {
        compatible = "newvisionu,nv3007";
        reg = <0>;
        spi-max-frequency = <52000000>;
        width = <142>;
        height = <428>;
        rotate = <270>;
        fps = <100>;
        status = "okay";
    };
};
~~~

Also preserve eMMC fixed block partitions; factory NVMEM MAC offsets 0x24 and 0x2a; both PCIe controllers; USB; GMAC0 2500base-x external PHY address 3; GMAC1 internal PHY address 15; Reset/WPS GPIO 1/0; LEDs GPIO 4/3; PWM1 pinmux.

- [ ] **Step 4: Add OpenWrt integration**

filogic.mk patch content:

~~~make
define Device/edgepi_e87n
  DEVICE_VENDOR := EdgePi
  DEVICE_MODEL := E87N
  DEVICE_DTS := mt7987a-edgepi-e87n
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-hwmon-pwmfan kmod-usb3 kmod-nvme \
    mt7987-2p5g-phy-firmware f2fsck mkf2fs automount
  KERNEL_LOADADDR := 0x40000000
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += edgepi_e87n
~~~

Add edgepi,e87n beside hiveton,h5000m in platform_do_upgrade, platform_check_image, and platform_copy_config.

Create tools/capture-e87n-network.sh to run the following read-only commands through SSH and write the output below .private/, which is already ignored by Git:

~~~bash
mkdir -p .private
ssh root@"${E87N_IP:-192.168.1.1}" \
  'ubus call network.interface dump; ubus call network.device status; ip -br link; uci -q show network' \
  > .private/e87n-network-runtime.txt
~~~

Use the original firmware's network.interface LAN/WAN device values and their matching link-layer addresses to set the exact 02_network mapping. Add those resolved device names as literal assertions in tests/test-e87n-platform.sh before committing; do not commit the captured runtime file.

- [ ] **Step 5: Compile target metadata and commit**

~~~bash
bash tests/test-e87n-platform.sh
WORK_DIR="$PWD/work" bash scripts/prepare-source.sh
make -C work/immortalwrt target/linux/compile -j2 V=s
make -C work/immortalwrt info | grep -A8 edgepi_e87n
git add device/edgepi-e87n patches/immortalwrt tools/capture-e87n-network.sh \
  tests/test-e87n-platform.sh
git commit -m "feat: add EdgePi E87N platform support"
~~~

Expected: DTS compiles and profile metadata lists edgepi,e87n.

### Task 4: Port NV3007 and Enable BTF/eBPF

**Files:**
- Create: device/edgepi-e87n/source-overlay/target/linux/mediatek/filogic/patches-6.12/950-fbdev-fbtft-add-nv3007.patch
- Create: configs/common.config
- Create: tests/test-kernel-requirements.sh

**Interfaces:**
- Consumes: compatible newvisionu,nv3007 and prepared kernel.
- Produces: fb_nv3007.ko, built-in .BTF section, dae/daed kernel modules.

- [ ] **Step 1: Write the failing requirements test**

~~~bash
#!/usr/bin/env bash
set -euo pipefail
cfg=configs/common.config
for symbol in CONFIG_KERNEL_DEBUG_INFO_BTF=y CONFIG_KERNEL_BPF_SYSCALL=y \
 CONFIG_KERNEL_BPF_JIT=y CONFIG_PACKAGE_kmod-sched-bpf=y \
 CONFIG_PACKAGE_kmod-veth=y CONFIG_PACKAGE_kmod-nft-tproxy=y \
 CONFIG_PACKAGE_kmod-hwmon-pwmfan=y; do grep -qx "$symbol" "$cfg"; done
grep -q nv3007 device/edgepi-e87n/source-overlay/target/linux/mediatek/filogic/patches-6.12/950-fbdev-fbtft-add-nv3007.patch
~~~

- [ ] **Step 2: Run it and confirm failure**

Run: bash tests/test-kernel-requirements.sh

Expected: FAIL because common.config is absent.

- [ ] **Step 3: Port the working driver**

Add fb_nv3007.c plus Kconfig and Makefile entries. Preserve the 6.6 init sequence, compatible, geometry, rotation, reset GPIO, and SPI settings; adapt only APIs required by 6.12. Select it as a module for E87N.

- [ ] **Step 4: Add common config**

Include target/device, BTF, BPF syscall/JIT, sched BPF, veth, XDP diagnostics, nft socket/TPROXY, WireGuard/TUN, PWM/HWMON, NVMe, USB, F2FS/ext4/Btrfs, framebuffer, LuCI, Chinese locale, Argon, and fan packages.

- [ ] **Step 5: Compile, inspect, and commit**

~~~bash
bash tests/test-kernel-requirements.sh
make -C work/immortalwrt target/linux/clean
make -C work/immortalwrt target/linux/compile -j2 V=s
grep -E 'CONFIG_DEBUG_INFO_BTF=y|CONFIG_BPF_SYSCALL=y|CONFIG_BPF_JIT=y' \
  work/immortalwrt/build_dir/target-*/linux-mediatek_filogic/linux-6.12*/.config
find work/immortalwrt/build_dir -name fb_nv3007.ko -print -quit | grep .
git add device/edgepi-e87n configs/common.config tests/test-kernel-requirements.sh
git commit -m "feat: enable E87N display and BTF kernel support"
~~~

### Task 5: Package the Recovered Fan Controller

**Files:**
- Create: package/e87n/fancontrol/Makefile and files/
- Create: package/e87n/luci-app-fancontrol/Makefile and files/
- Create: package/e87n/NOTICE.md
- Create: tests/test-fancontrol-package.sh

**Interfaces:**
- Consumes: recovered fan archive outside public Git.
- Produces: fancontrol, luci-app-fancontrol, Chinese translation; daemon SHA-256 dedea6cdb2fd7a65614501d2fb8c1fd58e3a1b16cc159ec07d775e5f78604ff8.

- [ ] **Step 1: Write the failing package test**

~~~bash
#!/usr/bin/env bash
set -euo pipefail
bin=package/e87n/fancontrol/files/usr/bin/fancontrol
test -x "$bin"
echo "dedea6cdb2fd7a65614501d2fb8c1fd58e3a1b16cc159ec07d775e5f78604ff8  $bin" | sha256sum -c -
grep -q 'kmod-hwmon-pwmfan' package/e87n/fancontrol/Makefile
grep -q '/sys/devices/platform/pwm-fan' <(strings "$bin")
grep -q "mode '1'" package/e87n/fancontrol/files/etc/config/fancontrol
~~~

- [ ] **Step 2: Run it and confirm failure**

Run: bash tests/test-fancontrol-package.sh

Expected: FAIL because package files are absent.

- [ ] **Step 3: Reconstruct packages and provenance**

Use standard OpenWrt Makefiles. Install daemon, UCI config, procd init script, LuCI controller/view/CSS/translation. NOTICE.md records declared MIT license, source path feeds/base/otherapp/luci-app-fancontrol, maintainer metadata, recovery date, and binary checksum.

- [ ] **Step 4: Resolve HWMON by name**

Before daemon start:

~~~sh
for h in /sys/class/hwmon/hwmon*; do
    [ "$(cat "$h/name" 2>/dev/null)" = pwmfan ] || continue
    uci_set fancontrol settings fan_file "$h/pwm1"
    uci_commit fancontrol
    break
done
~~~

The package must not depend solely on hwmon2.

- [ ] **Step 5: Build and commit**

~~~bash
bash tests/test-fancontrol-package.sh
make -C work/immortalwrt package/e87n/fancontrol/compile -j2 V=s
make -C work/immortalwrt package/e87n/luci-app-fancontrol/compile -j2 V=s
find work/immortalwrt/bin/packages -iname '*fancontrol*' -print
git add package/e87n tests/test-fancontrol-package.sh
git commit -m "feat: package E87N fan controller"
~~~

### Task 6: Define Full and Rescue Package Sets

**Files:**
- Create: configs/full.config
- Create: configs/rescue.config
- Create: tests/test-config-fragments.sh

**Interfaces:**
- Consumes: common.config and packages from prior tasks.
- Produces: profiles full and rescue.

- [ ] **Step 1: Write the failing config test**

~~~bash
#!/usr/bin/env bash
set -euo pipefail
for s in CONFIG_PACKAGE_dae=y CONFIG_PACKAGE_daed=y CONFIG_PACKAGE_luci-app-daede=y \
 CONFIG_PACKAGE_adguardhome=y CONFIG_PACKAGE_tailscale=y CONFIG_PACKAGE_python3=y \
 CONFIG_PACKAGE_python3-pip=y CONFIG_PACKAGE_luci-app-ttyd=y \
 CONFIG_PACKAGE_luci-app-vlmcsd=y CONFIG_PACKAGE_luci-app-ddns=y \
 CONFIG_PACKAGE_luci-app-watchcat=y; do grep -qx "$s" configs/full.config; done
for s in CONFIG_PACKAGE_daed=y CONFIG_PACKAGE_adguardhome=y \
 CONFIG_PACKAGE_tailscale=y CONFIG_PACKAGE_python3-pip=y; do
  ! grep -qx "$s" configs/rescue.config
done
grep -qx CONFIG_PACKAGE_luci=y configs/rescue.config
grep -qx CONFIG_PACKAGE_luci-app-fancontrol=y configs/rescue.config
~~~

- [ ] **Step 2: Run it and confirm failure**

Run: bash tests/test-config-fragments.sh

Expected: FAIL because fragments are absent.

- [ ] **Step 3: Create full and rescue fragments**

Full contains dae/daed/daede, AdGuard Home, WireGuard/LuCI protocol, Tailscale, ttyd, DDNS, Watchcat, vlmcsd, Python 3/pip/SSL/JSON/SQLite, Argon, fan control, translations, and approved tools.

Rescue contains LuCI, Chinese locale, Bootstrap, dropbear, firewall, dnsmasq, USB/NVMe/storage, fan control, framebuffer, curl, and nano. It excludes proxy, AdGuard Home, Tailscale, Python/pip, KMS, and optional diagnostics.

- [ ] **Step 4: Resolve both fragments and commit**

~~~bash
bash tests/test-config-fragments.sh
for profile in full rescue; do
  cp configs/common.config work/immortalwrt/.config
  work/immortalwrt/scripts/kconfig.pl + configs/$profile.config \
    work/immortalwrt/.config > work/immortalwrt/.config.new
  mv work/immortalwrt/.config.new work/immortalwrt/.config
  make -C work/immortalwrt defconfig
  cp work/immortalwrt/.config out/e87n-$profile.config
done
git add configs/full.config configs/rescue.config tests/test-config-fragments.sh
git commit -m "build: define E87N full and rescue profiles"
~~~

Expected: both defconfigs resolve and requested full packages remain =y.

### Task 7: Implement Build, Validation, and Artifact Collection

**Files:**
- Create: scripts/build-e87n.sh
- Create: scripts/validate-e87n.sh
- Create: scripts/collect-artifacts.sh
- Create: tests/test-build-scripts.sh

**Interfaces:**
- Consumes: argument full or rescue, prepared source, config fragments.
- Produces: out/PROFILE with exactly one sysupgrade, manifest, config, SHA-256, validation report.

- [ ] **Step 1: Write the failing CLI test**

~~~bash
#!/usr/bin/env bash
set -euo pipefail
bash -n scripts/build-e87n.sh
bash -n scripts/validate-e87n.sh
bash -n scripts/collect-artifacts.sh
if scripts/build-e87n.sh invalid >/dev/null 2>&1; then exit 1; fi
scripts/build-e87n.sh invalid 2>&1 | grep -q 'full|rescue'
~~~

- [ ] **Step 2: Run it and confirm failure**

Run: bash tests/test-build-scripts.sh

Expected: FAIL because scripts are absent.

- [ ] **Step 3: Implement build entry point**

Accept exactly full or rescue. Merge fragments, run make defconfig, make download -j8, then make -j$(nproc). On failure rerun make -j1 V=s and exit nonzero. Never collect artifacts after failure.

- [ ] **Step 4: Implement validator**

Required checks:

~~~bash
tar -xOf "$image" 'sysupgrade-edgepi,e87n/CONTROL' | grep -qx BOARD=edgepi,e87n
kernel_size=$(tar -xOf "$image" 'sysupgrade-edgepi,e87n/kernel' | wc -c)
test "$kernel_size" -lt $((32 * 1024 * 1024))
tar -xOf "$image" 'sysupgrade-edgepi,e87n/kernel' > "$tmp/kernel.fit"
dumpimage -l "$tmp/kernel.fit" | grep -q ARM64
dtc -I dtb -O dts "$compiled_dtb" | grep -q edgepi,e87n
readelf -S "$vmlinux" | grep -q '\.BTF'
if [ "$profile" = full ]; then
  grep -q '^dae ' "$manifest"
  grep -q '^daed ' "$manifest"
else
  ! grep -q '^dae ' "$manifest"
  ! grep -q '^daed ' "$manifest"
fi
~~~

Full asserts all requested packages. Rescue asserts dae, daed, AdGuard Home, Tailscale, and Python are absent. Pass profile into the validator as its first positional argument and reject any value other than full or rescue.

- [ ] **Step 5: Collect deterministic artifacts**

Rename validated output to edgepi-e87n-immortalwrt-25.12-PROFILE-sysupgrade.bin. Generate sha256sums, BUILD-MANIFEST.txt, resolved config, and VALIDATION.txt. Delete any preloader, FIP, factory, disk image, qcow2, or vmdk from out.

- [ ] **Step 6: Test and commit**

~~~bash
bash tests/test-build-scripts.sh
git add scripts/build-e87n.sh scripts/validate-e87n.sh \
  scripts/collect-artifacts.sh tests/test-build-scripts.sh
git commit -m "build: add E87N build and validation pipeline"
~~~

### Task 8: Add GitHub Actions Full-Source Builds

**Files:**
- Create: .github/workflows/build-e87n.yml
- Create: tests/test-workflow.sh

**Interfaces:**
- Consumes: workflow inputs profiles, publish_release, make_jobs; repository GITHUB_TOKEN only.
- Produces: full and rescue artifacts; optional validated release.

- [ ] **Step 1: Write the failing workflow test**

~~~bash
#!/usr/bin/env bash
set -euo pipefail
wf=.github/workflows/build-e87n.yml
test -f "$wf"
grep -q workflow_dispatch: "$wf"
grep -q 'runs-on: ubuntu-24.04' "$wf"
grep -q 'timeout-minutes: 350' "$wf"
grep -q scripts/build-e87n.sh "$wf"
grep -q scripts/validate-e87n.sh "$wf"
! grep -Eq 'x86_64|combined-efi|qcow2|vmdk' "$wf"
~~~

- [ ] **Step 2: Run it and confirm failure**

Run: bash tests/test-workflow.sh

Expected: FAIL because workflow is absent.

- [ ] **Step 3: Implement workflow**

Use matrix full/rescue, ubuntu-24.04, 350-minute timeout, per-branch concurrency cancellation. Install OpenWrt dependencies, shellcheck, device-tree-compiler, u-boot-tools, and actionlint. Remove Android SDK, CodeQL, Haskell, and unused .NET caches; print df -h before/after. Cache only work/immortalwrt/dl with a key containing IMMORTALWRT_COMMIT. Run every static test before compilation.

Build jobs use contents: read. A release job requires both matrix artifacts, verifies SHA-256, runs only when publish_release is true, and alone receives contents: write.

- [ ] **Step 4: Validate, commit, push**

~~~bash
bash tests/test-workflow.sh
actionlint .github/workflows/build-e87n.yml
shellcheck scripts/*.sh scripts/lib/*.sh tests/*.sh
git add .github/workflows/build-e87n.yml tests/test-workflow.sh
git commit -m "ci: build validated E87N firmware online"
git push origin HEAD:main
~~~

### Task 9: Add Safe Backup, Build, Flash, and Recovery Documentation

**Files:**
- Create: tools/e87n-backup.sh
- Create: docs/e87n-build.md
- Create: docs/e87n-flash-and-recovery.md
- Create: tests/test-backup-tool.sh

**Interfaces:**
- Consumes: running E87N root shell and PC-side SSH redirection.
- Produces: read-only streams for GPT, boot0/1, env, factory, FIP, kernel, optional rootfs; instructions for U-Boot Web recovery.

- [ ] **Step 1: Write the failing safety test**

~~~bash
#!/usr/bin/env bash
set -euo pipefail
tool=tools/e87n-backup.sh
test -f "$tool"
bash -n "$tool"
! grep -Eq '(^|[[:space:]])(of=|flash_erase|mmc write|ubiformat|mtd write|fw_setenv)' "$tool"
grep -q /dev/mmcblk0boot0 "$tool"
grep -q /dev/mmcblk0p2 "$tool"
grep -q sha256sum "$tool"
~~~

- [ ] **Step 2: Run it and confirm failure**

Run: bash tests/test-backup-tool.sh

Expected: FAIL because tool is absent.

- [ ] **Step 3: Implement restricted read-only streaming**

Support --manifest and --stream NAME. Map fixed names to fixed device paths in a case statement and reject arbitrary paths. Use dd if="$device" bs=4M status=progress with no of=. PC example:

~~~bash
ssh root@192.168.1.1 'sh -s -- --stream factory' \
  < tools/e87n-backup.sh > e87n-factory.img
sha256sum e87n-factory.img
~~~

Include boot0, boot1, p1-p4, GPT, and optional compressed p5. Do not document Linux-side writes to boot/calibration partitions without TTL.

- [ ] **Step 4: Document CI, preflight, flash, rollback**

Include Actions dispatch/download, checksum verification, sysupgrade -T, Reset-on-power, PC static address, http://192.168.1.1, upload of validated sysupgrade, first password setup, and rollback to original firmware hash 054C31B71B24A1924B810B5CE1CE7480460871C134E58BB24907C3BEB1EE5AFA.

- [ ] **Step 5: Test and commit**

~~~bash
bash tests/test-backup-tool.sh
git add tools/e87n-backup.sh docs/e87n-build.md \
  docs/e87n-flash-and-recovery.md tests/test-backup-tool.sh
git commit -m "docs: add E87N backup and recovery workflow"
~~~

### Task 10: Build Online and Validate Hardware

**Files:**
- Modify on test-first failures: DTS, platform patch, kernel patch, configs, scripts.
- Create: docs/e87n-hardware-validation.md

**Interfaces:**
- Consumes: successful Actions artifacts and a backed-up E87N.
- Produces: build URL, commit/hash record, sysupgrade preflight, hardware acceptance record.

- [ ] **Step 1: Run rescue build first**

Trigger Actions with profiles=rescue and publish_release=false.

Expected: static tests, locked revisions, compilation, and validators pass; artifact contains no bootloader/factory file.

- [ ] **Step 2: Run full build**

Trigger profiles=full and publish_release=false.

Expected: manifest contains dae, daed, daede, AdGuard Home, Tailscale, Python 3/pip, WireGuard, ttyd, DDNS, Watchcat, vlmcsd, Argon, and fan control.

- [ ] **Step 3: Preflight on current router**

~~~bash
sha256sum -c sha256sums
scp edgepi-e87n-immortalwrt-25.12-rescue-sysupgrade.bin root@192.168.1.1:/tmp/e87n.bin
ssh root@192.168.1.1 'sysupgrade -T /tmp/e87n.bin'
~~~

Expected: checksum passes and sysupgrade -T exits 0 for edgepi,e87n.

- [ ] **Step 4: Flash rescue through U-Boot Web**

Record PASS/FAIL and command output for both Ethernet ports, DHCP/LAN, SSH, LuCI, eMMC overlay, CPU thermal, pwmfan/pwm1, NVMe, USB, /dev/fb0, /sys/kernel/btf/vmlinux, reboot, and cold boot.

- [ ] **Step 5: Flash full only after rescue passes**

Test dae and daed separately, then AdGuard Home, WireGuard, Tailscale, DDNS, ttyd, KMS, Watchcat, Argon, and Python. Keep proxy and DNS services non-conflicting during each test.

- [ ] **Step 6: Record results and publish only after acceptance**

docs/e87n-hardware-validation.md records Actions run URL, exact commit, image SHA-256, date, commands, results, and rollback. Each correction gets a failing regression test and a focused commit. Publish a release only after every completion criterion in the approved design passes.
