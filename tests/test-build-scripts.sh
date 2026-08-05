#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BUILD="$ROOT/scripts/build-e87n.sh"
VALIDATE="$ROOT/scripts/validate-e87n.sh"
COLLECT="$ROOT/scripts/collect-artifacts.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/e87n-build-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_failure() {
  local label=$1
  shift
  if "$@" >"$TMP/$label.stdout" 2>"$TMP/$label.stderr"; then
    cat "$TMP/$label.stdout" >&2
    cat "$TMP/$label.stderr" >&2
    fail "$label unexpectedly succeeded"
  fi
}

for script in "$BUILD" "$VALIDATE" "$COLLECT"; do
  test -f "$script" || fail "missing $script"
  "$BASH" -n "$script"
  expect_failure invalid-profile "$BASH" "$script" invalid
  grep -q 'full|rescue' "$TMP/invalid-profile.stderr" || fail "$script usage omits full|rescue"
done

MOCKBIN="$TMP/mockbin"
SOURCE="$TMP/source"
OUT="$TMP/out"
LOG="$TMP/calls.log"
mkdir -p "$MOCKBIN" "$SOURCE/scripts" "$SOURCE/feeds/packages" "$SOURCE/feeds/luci" \
  "$SOURCE/package/feeds/daede" "$SOURCE/bin/targets/mediatek/filogic" \
  "$SOURCE/build_dir/target-aarch64/linux-mediatek_filogic/linux-6.12"
touch "$SOURCE/Makefile"

cat >"$SOURCE/scripts/kconfig.pl" <<'EOF'
#!/usr/bin/env sh
test "$1" = +
cat "$3" "$2"
EOF

cat >"$MOCKBIN/git" <<'EOF'
#!/usr/bin/env sh
set -eu
. "$E87N_REPO_ROOT/versions.env"
path=
if test "${1:-}" = -C; then path=$2; shift 2; fi
test "${1:-}" = rev-parse && test "${2:-}" = HEAD
case "$path" in
  */feeds/packages) printf '%s\n' "$PACKAGES_COMMIT" ;;
  */feeds/luci) printf '%s\n' "$LUCI_COMMIT" ;;
  */package/feeds/daede) printf '%s\n' "$DAEDE_COMMIT" ;;
  *) printf '%s\n' "$IMMORTALWRT_COMMIT" ;;
esac
EOF

cat >"$MOCKBIN/make" <<'EOF'
#!/usr/bin/env sh
set -eu
printf 'make %s\n' "$*" >>"$MOCK_LOG"
source_dir=
if test "${1:-}" = -C; then source_dir=$2; shift 2; fi
if test "${1:-}" = defconfig; then
  awk -v drop="${MOCK_DROP_SYMBOL:-}" '
    /^[#] CONFIG_[A-Za-z0-9_-]+ is not set$/ { s=$0; sub(/^# /,"",s); sub(/ is not set$/,"",s); state[s]="n"; if(!seen[s]++) order[++n]=s; next }
    /^CONFIG_[A-Za-z0-9_-]+=/ { s=$0; sub(/=.*/,"",s); state[s]=$0; if(!seen[s]++) order[++n]=s; next }
    { other[++m]=$0 }
    END { for(i=1;i<=m;i++) print other[i]; for(i=1;i<=n;i++) if(order[i]!=drop) { if(state[order[i]]=="n") print "# " order[i] " is not set"; else print state[order[i]] } }
  ' "$source_dir/.config" >"$source_dir/.config.new"
  if test -n "${MOCK_FORCE_MODULE:-}"; then
    sed -i "/^# $MOCK_FORCE_MODULE is not set$/c\\$MOCK_FORCE_MODULE=m" "$source_dir/.config.new"
  fi
  mv "$source_dir/.config.new" "$source_dir/.config"
  exit 0
fi
if test "${1:-}" = download; then
  test "${MOCK_DOWNLOAD_FAIL:-0}" != 1
  exit
fi
if test "${MOCK_BUILD_FAIL:-0}" = 1; then exit 1; fi
exit 0
EOF

cat >"$MOCKBIN/nproc" <<'EOF'
#!/usr/bin/env sh
printf '4\n'
EOF
cat >"$MOCKBIN/tar" <<'EOF'
#!/usr/bin/env sh
set -eu
case "$1" in
  -tf) printf '%s\n' 'sysupgrade-edgepi,e87n/CONTROL' 'sysupgrade-edgepi,e87n/kernel' 'sysupgrade-edgepi,e87n/root' ;;
  -xOf)
    case "$3" in
      */CONTROL)
        board=${MOCK_BOARD:-edgepi,e87n}
        case "$2" in *override-good*) board=edgepi,e87n ;; esac
        printf 'BOARD=%s\n' "$board" ;;
      */kernel)
        if test "${MOCK_OVERSIZE_KERNEL:-0}" = 1; then
          awk 'BEGIN { for (i=0; i<33554432; i++) printf "x" }'
        else
          printf 'small-fit-kernel'
        fi ;;
      *) exit 1 ;;
    esac ;;
  *) exit 1 ;;
esac
EOF
cat >"$MOCKBIN/dumpimage" <<'EOF'
#!/usr/bin/env sh
case "${MOCK_FIT_MODE:-good}" in
  nonfit) printf '%s\n' 'not an image' ;;
  wrong-arch) printf '%s\n' 'FIT description: E87N' 'Architecture: x86' ;;
  *) printf '%s\n' 'FIT description: E87N' 'Architecture: ARM64' ;;
esac
EOF
cat >"$MOCKBIN/dtc" <<'EOF'
#!/usr/bin/env sh
if test "${MOCK_NESTED_LEAK:-0}" = 1; then
cat <<'DTS'
/ {
  compatible = "edgepi,e87n";
  ethernet@15100000 {
    compatible = "mediatek,mt7987-eth";
    mac@0 {
      reg = <7>;
      status = "disabled";
      child@0 { reg = <0>; phy-mode = "2500base-x"; phy-handle = <0x11>; status = "okay"; };
    };
    mac@1 {
      reg = <1>; phy-mode = "internal"; phy-handle = <0x12>; status = "okay";
    };
  };
  mdio {
    phy@3 {
      reg = <3>; phandle = <0x11>;
    };
    phy@f {
      reg = <15>; phandle = <0x12>;
    };
  };
};
DTS
exit
fi
if test "${MOCK_FALSE_CONTROLLER:-0}" = 1; then
cat <<'DTS'
/ {
  compatible = "edgepi,e87n";
  container@0 {
    identity@0 { compatible = "mediatek,mt7987-eth"; };
    mac@0 {
      reg = <0>; phy-mode = "2500base-x"; phy-handle = <0x11>; status = "okay";
    };
    mac@1 {
      reg = <1>; phy-mode = "internal"; phy-handle = <0x12>; status = "okay";
    };
  };
  mdio {
    phy@3 {
      reg = <3>; phandle = <0x11>;
    };
    phy@f {
      reg = <15>; phandle = <0x12>;
    };
  };
};
DTS
exit
fi
if test "${MOCK_DECOY_CONTROLLER:-0}" = 1; then
cat <<'DTS'
/ {
  compatible = "edgepi,e87n";
  soc {
    ethernet@15100000 {
      compatible = "mediatek,mt7987-eth";
      mac@0 {
        reg = <7>;
        phy-mode = "2500base-x";
        phy-handle = <0x21>;
        status = "okay";
      };
      mac@1 {
        reg = <1>;
        phy-mode = "internal";
        phy-handle = <0x22>;
        status = "okay";
      };
      mdio-bus {
        phy@3 {
          reg = <3>;
          phandle = <0x21>;
          status = "okay";
        };
        phy@f {
          reg = <15>;
          phandle = <0x22>;
          status = "okay";
        };
      };
    };
  };
  decoy {
    ethernet@deadbeef {
      compatible = "mediatek,mt7987-eth";
      mac@0 {
        reg = <0>;
        phy-mode = "2500base-x";
        phy-handle = <0x11>;
        status = "okay";
      };
      mac@1 {
        reg = <1>;
        phy-mode = "internal";
        phy-handle = <0x12>;
        status = "okay";
      };
      mdio-bus {
        phy@3 {
          reg = <3>;
          phandle = <0x11>;
          status = "okay";
        };
        phy@f {
          reg = <15>;
          phandle = <0x12>;
          status = "okay";
        };
      };
    };
  };
};
DTS
exit
fi
if test "${MOCK_OFFPATH_PHYS:-0}" = 1; then
cat <<'DTS'
/ {
  compatible = "edgepi,e87n";
  soc {
    ethernet@15100000 {
      compatible = "mediatek,mt7987-eth";
      mac@0 {
        reg = <0>;
        phy-mode = "2500base-x";
        phy-handle = <0x11>;
        status = "okay";
      };
      mac@1 {
        reg = <1>;
        phy-mode = "internal";
        phy-handle = <0x12>;
        status = "okay";
      };
      mdio-bus {
        phy@3 {
          reg = <4>;
          phandle = <0x31>;
          status = "okay";
        };
        phy@f {
          reg = <14>;
          phandle = <0x32>;
          status = "okay";
        };
      };
    };
  };
  mdio-bus {
    phy@3 {
      reg = <3>;
      phandle = <0x11>;
      status = "okay";
    };
    phy@f {
      reg = <15>;
      phandle = <0x12>;
      status = "okay";
    };
  };
};
DTS
exit
fi
if test "${*##*override-good*}" != "$*"; then
  dtb_bad=0
else
  dtb_bad=${MOCK_ACTUAL_DTB_BAD:-0}
fi
if test -n "${MOCK_DTB_PHY15+x}"; then
  phy15_node=$MOCK_DTB_PHY15
else
  phy15_node="phy@f {
          reg = <${MOCK_PHY15_REG:-15}>;
          phandle = <0x12>;
          status = \"okay\";
        };"
fi
cat <<DTS
/ {
  compatible = "edgepi,e87n", "mediatek,mt7987a";
  soc {
    ethernet@15100000 {
      compatible = "mediatek,mt7987-eth";
      ${MOCK_MAC0_NODE:-mac@0} {
        reg = <${MOCK_MAC0_REG:-0}>;
        phy-mode = "2500base-x";
        phy-handle = <${MOCK_GMAC0_HANDLE:-0x11}>;
        status = "${MOCK_MAC0_STATUS:-okay}";
      };
      mac@1 {
        reg = <1>;
        phy-mode = "internal";
        phy-handle = <${MOCK_GMAC1_HANDLE:-0x12}>;
        status = "okay";
      };
      mdio-bus {
        ${MOCK_PHY3_NODE:-phy@3} {
          reg = <3>;
          phandle = <0x11>;
          status = "${MOCK_PHY3_STATUS:-okay}";
        };
        ${phy15_node}
      };
    };
  };
  $(test "$dtb_bad" = 1 && printf '%s' 'wifi@bad { status = "okay"; };')
  ${MOCK_WIFI_NODE:-}
};
DTS
EOF
cat >"$MOCKBIN/readelf" <<'EOF'
#!/usr/bin/env sh
case "$*" in *override-good*) printf '%s\n' '  [42] .BTF PROGBITS' ;; *) test "${MOCK_MISSING_BTF:-0}" = 1 || printf '%s\n' '  [42] .BTF PROGBITS' ;; esac
EOF
if ! command -v sha256sum >/dev/null 2>&1; then
cat >"$MOCKBIN/sha256sum" <<'EOF'
#!/usr/bin/env sh
set -eu
digest() { certutil.exe -hashfile "$1" SHA256 | sed -n '2{s/[[:space:]]//g;p;}'; }
if test "${1:-}" = -c; then
  while read -r expected file; do
    test "$(digest "$file")" = "$expected" || { printf '%s: FAILED\n' "$file"; exit 1; }
    printf '%s: OK\n' "$file"
  done <"$2"
else
  for file in "$@"; do printf '%s  %s\n' "$(digest "$file")" "${file##*/}"; done
fi
EOF
fi
cat >"$MOCKBIN/mv" <<'EOF'
#!/usr/bin/env sh
source_path=$1
dest_path=$2
if test "$source_path" = -T; then source_path=$2; dest_path=$3; fi
if test "${MOCK_STALE_FINAL_TARGET:-0}" = 1 && test "${source_path##*/}" = staging; then
  mkdir -p "$dest_path"
  printf 'concurrent\n' >"$dest_path/concurrent.marker"
  exit 1
fi
if test "${MOCK_FINAL_MOVE_FAIL:-0}" = 1 && test "${source_path##*/}" = staging; then exit 1; fi
if test "${MOCK_ROLLBACK_FAIL:-0}" = 1 && test "${source_path##*/}" = previous; then exit 1; fi
if test "${MOCK_SIGNAL_AFTER_SAVE:-0}" = 1 && test "${dest_path##*/}" = previous; then
  /usr/bin/mv "$@"
  kill -TERM "$PPID"
  exit 0
fi
/usr/bin/mv "$@"
if test "${MOCK_POST_PUBLISH_EXTRA:-0}" = 1 && test "${source_path##*/}" = staging; then
  printf 'invalid\n' >"$dest_path/unexpected.file"
fi
if test "${MOCK_POST_PUBLISH_DIRECTORY:-0}" = 1 && test "${source_path##*/}" = staging; then
  mkdir "$dest_path/unexpected.directory"
fi
if test "${MOCK_POST_PUBLISH_EXPECTED_DIRECTORY:-0}" = 1 && test "${source_path##*/}" = staging; then
  /usr/bin/rm -f "$dest_path/VALIDATION.txt"
  mkdir "$dest_path/VALIDATION.txt"
fi
if test -n "${MOCK_SIGNAL_AFTER_FINAL_RENAME:-}" && test "${source_path##*/}" = staging; then
  case "$MOCK_SIGNAL_AFTER_FINAL_RENAME" in
    regular) printf 'invalid\n' >"$dest_path/unexpected.file" ;;
    directory) mkdir "$dest_path/unexpected.directory" ;;
    *) exit 2 ;;
  esac
  kill -TERM "$PPID"
  exit 0
fi
EOF
cat >"$MOCKBIN/flock" <<'EOF'
#!/usr/bin/env sh
printf 'flock %s\n' "$*" >>"$MOCK_LOG"
exit 0
EOF

chmod 0755 "$SOURCE/scripts/kconfig.pl" "$MOCKBIN"/*

IMAGE="$SOURCE/bin/targets/mediatek/filogic/immortalwrt-mediatek-filogic-edgepi_e87n-squashfs-sysupgrade.bin"
MANIFEST="$SOURCE/bin/targets/mediatek/filogic/immortalwrt-mediatek-filogic-edgepi_e87n.manifest"
DTB="$SOURCE/build_dir/target-aarch64/linux-mediatek_filogic/linux-6.12/mt7987a-edgepi-e87n.dtb"
VMLINUX="$SOURCE/build_dir/target-aarch64/linux-mediatek_filogic/linux-6.12/vmlinux"
printf 'image-bytes\n' >"$IMAGE"
touch "$DTB" "$VMLINUX"

write_manifest() {
  local profile=$1
  awk '
    /^CONFIG_PACKAGE_[A-Za-z0-9_-]+=y$/ { s=$0; sub(/^CONFIG_PACKAGE_/,"",s); sub(/=y$/,"",s); state[s]="y"; if(!seen[s]++) order[++n]=s }
    /^# CONFIG_PACKAGE_[A-Za-z0-9_-]+ is not set$/ { s=$0; sub(/^# CONFIG_PACKAGE_/,"",s); sub(/ is not set$/,"",s); state[s]="n"; if(!seen[s]++) order[++n]=s }
    END { for(i=1;i<=n;i++) if(state[order[i]]=="y") print order[i], "1.0-r1" }
  ' "$ROOT/configs/common.config" "$ROOT/configs/$profile.config" >"$MANIFEST"
}

export E87N_REPO_ROOT="$ROOT" IMMORTALWRT_SOURCE="$SOURCE" OUT_DIR="$OUT"
export MOCK_LOG="$LOG" PATH="$MOCKBIN:/usr/bin:/bin:$PATH"
unset E87N_IMAGE E87N_MANIFEST E87N_DTB E87N_VMLINUX

expect_failure invalid-build-profile "$BASH" "$BUILD" invalid
grep -q 'full|rescue' "$TMP/invalid-build-profile.stderr"

write_manifest full
: >"$LOG"
export MOCK_DROP_SYMBOL=CONFIG_PACKAGE_dae
expect_failure disappearing-kconfig "$BASH" "$BUILD" full
unset MOCK_DROP_SYMBOL
test ! -e "$OUT/full" || fail 'disappearing Kconfig selection published artifacts'

write_manifest rescue
export MOCK_FORCE_MODULE=CONFIG_PACKAGE_nvme-cli
expect_failure forbidden-module "$BASH" "$BUILD" rescue
unset MOCK_FORCE_MODULE
test ! -e "$OUT/rescue" || fail 'forbidden =m Kconfig selection published artifacts'
write_manifest full

export MOCK_DOWNLOAD_FAIL=1
: >"$LOG"
expect_failure failed-download "$BASH" "$BUILD" full
unset MOCK_DOWNLOAD_FAIL
if ! grep -q 'download -j8' "$LOG"; then
  cat "$TMP/failed-download.stderr" >&2
  cat "$LOG" >&2
  fail 'parallel download was not attempted'
fi
grep -q 'download -j1 V=s' "$LOG" || fail 'failed download did not receive verbose serial retry'
test ! -e "$OUT/full" || fail 'failed download published artifacts'

: >"$LOG"
export MOCK_BUILD_FAIL=1
expect_failure failed-build "$BASH" "$BUILD" full
unset MOCK_BUILD_FAIL
if ! grep -q 'make -C .* -j1 V=s' "$LOG"; then
  cat "$TMP/failed-build.stderr" >&2
  cat "$LOG" >&2
  fail 'failed build did not receive verbose serial retry'
fi
test ! -e "$OUT/full" || fail 'failed build published artifacts'

rm -f "$IMAGE"
expect_failure zero-images "$BASH" "$VALIDATE" full
printf 'image-one\n' >"$IMAGE"
printf 'image-two\n' >"${IMAGE%.bin}-duplicate.bin"
expect_failure two-images "$BASH" "$VALIDATE" full
rm -f "${IMAGE%.bin}-duplicate.bin"

export MOCK_OVERSIZE_KERNEL=1
expect_failure oversized-kernel "$BASH" "$VALIDATE" full
unset MOCK_OVERSIZE_KERNEL
export MOCK_FIT_MODE=nonfit
expect_failure non-fit-kernel "$BASH" "$VALIDATE" full
export MOCK_FIT_MODE=wrong-arch
expect_failure wrong-fit-arch "$BASH" "$VALIDATE" full
unset MOCK_FIT_MODE
export MOCK_MISSING_BTF=1
expect_failure missing-btf "$BASH" "$VALIDATE" full
unset MOCK_MISSING_BTF
export MOCK_GMAC0_HANDLE=0x12 MOCK_GMAC1_HANDLE=0x11
expect_failure swapped-ports "$BASH" "$VALIDATE" full
unset MOCK_GMAC0_HANDLE MOCK_GMAC1_HANDLE
export MOCK_MAC0_NODE=unrelated@0
expect_failure wrong-mac-node "$BASH" "$VALIDATE" full
unset MOCK_MAC0_NODE
export MOCK_MAC0_REG=7
expect_failure wrong-mac-reg "$BASH" "$VALIDATE" full
unset MOCK_MAC0_REG
export MOCK_MAC0_STATUS=disabled
expect_failure disabled-mac "$BASH" "$VALIDATE" full
unset MOCK_MAC0_STATUS
export MOCK_PHY15_REG=14
expect_failure wrong-phy-reg "$BASH" "$VALIDATE" full
unset MOCK_PHY15_REG
export MOCK_PHY3_STATUS=disabled
expect_failure disabled-phy "$BASH" "$VALIDATE" full
unset MOCK_PHY3_STATUS
export MOCK_PHY3_STATUS=reserved
expect_failure reserved-phy "$BASH" "$VALIDATE" full
unset MOCK_PHY3_STATUS
export MOCK_NESTED_LEAK=1
expect_failure nested-property-leak "$BASH" "$VALIDATE" full
unset MOCK_NESTED_LEAK
export MOCK_FALSE_CONTROLLER=1
expect_failure false-controller-parent "$BASH" "$VALIDATE" full
unset MOCK_FALSE_CONTROLLER
export MOCK_DECOY_CONTROLLER=1
expect_failure decoy-compatible-controller "$BASH" "$VALIDATE" full
unset MOCK_DECOY_CONTROLLER
export MOCK_OFFPATH_PHYS=1
expect_failure off-path-phys "$BASH" "$VALIDATE" full
unset MOCK_OFFPATH_PHYS
export MOCK_DTB_PHY15='# missing phy@f'
expect_failure missing-port "$BASH" "$VALIDATE" full
unset MOCK_DTB_PHY15
export MOCK_WIFI_NODE='wifi@0 { compatible = "vendor,wifi"; status = "okay"; };'
expect_failure wifi-child "$BASH" "$VALIDATE" full
unset MOCK_WIFI_NODE

cp "$MANIFEST" "$TMP/good-full.manifest"
sed -i 's/^dae /dae-malformed /' "$MANIFEST"
expect_failure malformed-manifest "$BASH" "$VALIDATE" full
cp "$TMP/good-full.manifest" "$MANIFEST"

rm -rf "$OUT"
export MOCK_BOARD=wrong,board
expect_failure validation-failure "$BASH" "$COLLECT" full
unset MOCK_BOARD
test ! -e "$OUT/full" || fail 'validation failure left artifacts'

printf 'override-good\n' >"$TMP/override-good.bin"
export E87N_IMAGE="$TMP/override-good.bin" MOCK_BOARD=wrong,board
expect_failure override-bypass "$BASH" "$COLLECT" full
unset E87N_IMAGE MOCK_BOARD
test ! -e "$OUT/full" || fail 'override/discovery mismatch published artifacts'

touch "$TMP/override-good.dtb" "$TMP/override-good.vmlinux"
export E87N_DTB="$TMP/override-good.dtb" MOCK_ACTUAL_DTB_BAD=1
expect_failure dtb-override-bypass "$BASH" "$COLLECT" full
unset E87N_DTB MOCK_ACTUAL_DTB_BAD
export E87N_VMLINUX="$TMP/override-good.vmlinux" MOCK_MISSING_BTF=1
expect_failure vmlinux-override-bypass "$BASH" "$COLLECT" full
unset E87N_VMLINUX MOCK_MISSING_BTF

mkdir -p "$OUT/full"
printf 'old-danger\n' >"$OUT/full/fip.bin"
printf 'source-danger\n' >"$SOURCE/bin/targets/mediatek/filogic/preloader-edgepi-e87n.bin"
: >"$LOG"
"$BASH" "$BUILD" full >"$TMP/full.validation"
grep -q '^flock ' "$LOG" || fail 'collector did not serialize publication with flock'
test -f "$SOURCE/bin/targets/mediatek/filogic/preloader-edgepi-e87n.bin" || fail 'collector modified source bin'
FINAL="$OUT/full/edgepi-e87n-immortalwrt-25.12-full-sysupgrade.bin"
test -f "$FINAL" || fail 'renamed full sysupgrade missing'
mapfile -t files < <(find "$OUT/full" -maxdepth 1 -type f -printf '%f\n' | sort)
expected=(BUILD-MANIFEST.txt SHA256SUMS VALIDATION.txt edgepi-e87n-immortalwrt-25.12-full-sysupgrade.bin edgepi-e87n-immortalwrt-25.12-full.config edgepi-e87n-immortalwrt-25.12-full.manifest)
test "${files[*]}" = "${expected[*]}" || fail "unexpected collected files: ${files[*]}"
mapfile -t checksummed < <(awk '{print $2}' "$OUT/full/SHA256SUMS" | sort)
mapfile -t delivered < <(find "$OUT/full" -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\n' | sort)
test "${checksummed[*]}" = "${delivered[*]}" || fail 'SHA256SUMS does not cover every delivered payload'
(cd "$OUT/full" && sha256sum -c SHA256SUMS) >"$TMP/checksums.out"
test "$(grep -c ': OK$' "$TMP/checksums.out")" -eq 5 || fail 'not all five delivered files passed checksum verification'
grep -qx 'VALIDATION=PASS' "$OUT/full/VALIDATION.txt"
grep -qx 'PROFILE=full' "$OUT/full/BUILD-MANIFEST.txt"

write_manifest rescue
cp "$MANIFEST" "$TMP/good-rescue.manifest"
for forbidden in \
  dae adguardhome tailscale python3 vlmcsd ttyd ddns-scripts \
  watchcat luci-app-argon-config luci-i18n-ttyd-zh-cn iw; do
  cp "$TMP/good-rescue.manifest" "$MANIFEST"
  printf '%s 9.9-r9\n' "$forbidden" >>"$MANIFEST"
  expect_failure "rescue-forbidden-${forbidden//[^A-Za-z0-9]/_}" "$BASH" "$VALIDATE" rescue
done
cp "$TMP/good-rescue.manifest" "$MANIFEST"
"$BASH" "$VALIDATE" rescue >"$TMP/rescue.validation"
grep -qx 'PACKAGE_POLICY=PASS' "$TMP/rescue.validation"

printf 'previous-good\n' >"$OUT/full/previous.marker"
export MOCK_FINAL_MOVE_FAIL=1
expect_failure publish-rollback "$BASH" "$COLLECT" rescue
unset MOCK_FINAL_MOVE_FAIL
test ! -e "$OUT/rescue" || fail 'failed first publication left a partial output'

mkdir -p "$OUT/rescue"
printf 'previous-good\n' >"$OUT/rescue/previous.marker"
export MOCK_FINAL_MOVE_FAIL=1
expect_failure publish-rollback-existing "$BASH" "$COLLECT" rescue
unset MOCK_FINAL_MOVE_FAIL
grep -qx 'previous-good' "$OUT/rescue/previous.marker" || fail 'failed publication did not preserve prior validated output'

export MOCK_STALE_FINAL_TARGET=1
expect_failure stale-final-target "$BASH" "$COLLECT" rescue
unset MOCK_STALE_FINAL_TARGET
grep -qx 'previous-good' "$OUT/rescue/previous.marker" || fail 'stale destination race lost prior output'
test ! -e "$OUT/rescue/staging" || fail 'publication nested staging below the profile output'

export MOCK_STALE_FINAL_TARGET=1 MOCK_ROLLBACK_FAIL=1
expect_failure rollback-failure "$BASH" "$COLLECT" rescue
unset MOCK_STALE_FINAL_TARGET MOCK_ROLLBACK_FAIL
recovery=$(find "$OUT" -path '*/previous' -type d -print -quit)
test -n "$recovery" || fail 'rollback failure deleted the only recovery copy'
grep -q 'manual recovery' "$TMP/rollback-failure.stderr" || fail 'rollback failure did not report recovery path'

rm -rf "$OUT/rescue"
export MOCK_POST_PUBLISH_EXTRA=1
expect_failure first-post-publish-verification "$BASH" "$COLLECT" rescue
unset MOCK_POST_PUBLISH_EXTRA
test ! -e "$OUT/rescue" || fail 'invalid first publication remained published'

for injected_entry in regular directory; do
  rm -rf "$OUT/rescue"
  export MOCK_SIGNAL_AFTER_FINAL_RENAME=$injected_entry
  expect_failure "signal-after-final-rename-$injected_entry" "$BASH" "$COLLECT" rescue
  unset MOCK_SIGNAL_AFTER_FINAL_RENAME
  test ! -e "$OUT/rescue" || fail "signal after final rename left unverified $injected_entry first publication public"
done

mkdir -p "$OUT/rescue"
printf 'previous-good\n' >"$OUT/rescue/previous.marker"
export MOCK_POST_PUBLISH_DIRECTORY=1
expect_failure post-publish-directory "$BASH" "$COLLECT" rescue
unset MOCK_POST_PUBLISH_DIRECTORY
grep -qx 'previous-good' "$OUT/rescue/previous.marker" || fail 'non-regular extra entry did not restore prior output'
test ! -e "$OUT/rescue/unexpected.directory" || fail 'invalid directory publication was not quarantined'

export MOCK_POST_PUBLISH_EXPECTED_DIRECTORY=1
expect_failure post-publish-expected-directory "$BASH" "$COLLECT" rescue
unset MOCK_POST_PUBLISH_EXPECTED_DIRECTORY
grep -qx 'previous-good' "$OUT/rescue/previous.marker" || fail 'non-regular expected entry did not restore prior output'

rm -rf "$OUT/rescue"
mkdir -p "$OUT/rescue"
printf 'previous-good\n' >"$OUT/rescue/previous.marker"
export MOCK_SIGNAL_AFTER_SAVE=1
expect_failure signal-after-save "$BASH" "$COLLECT" rescue
unset MOCK_SIGNAL_AFTER_SAVE
if test -f "$OUT/rescue/previous.marker"; then
  grep -qx 'previous-good' "$OUT/rescue/previous.marker"
else
  recovery=$(find "$OUT" -path '*/previous/previous.marker' -type f -print -quit)
  test -n "$recovery" || fail 'signal after save deleted the sole previous output'
fi

rm -rf "$OUT/rescue"
mkdir -p "$OUT/rescue"
printf 'previous-good\n' >"$OUT/rescue/previous.marker"
export MOCK_POST_PUBLISH_EXTRA=1
expect_failure post-publish-verification "$BASH" "$COLLECT" rescue
unset MOCK_POST_PUBLISH_EXTRA
grep -qx 'previous-good' "$OUT/rescue/previous.marker" || fail 'post-publication verification failure did not restore prior output'
test ! -e "$OUT/rescue/unexpected.file" || fail 'invalid new publication was not quarantined'

printf 'PASS: E87N build, validation, and artifact pipeline\n'
