#!/usr/bin/env bash
# The assertions intentionally match unexpanded shell source text.
# shellcheck disable=SC2016
set -euo pipefail

source scripts/lib/common.sh

test "$(normalize_bool true)" = 1
test "$(normalize_bool false)" = 0
if normalize_bool invalid >/dev/null 2>&1; then
  exit 1
fi

if command -v bash >/dev/null 2>&1; then
  bash -n scripts/prepare-source.sh
else
  "${POSIX_SH:-sh}" -n scripts/prepare-source.sh
fi

common_line=$(grep -n 'source "$REPO_ROOT/scripts/lib/common.sh"' scripts/prepare-source.sh | cut -d: -f1)
require_line=$(grep -n 'require_file "$REPO_ROOT/versions.env"' scripts/prepare-source.sh | cut -d: -f1)
versions_line=$(grep -n 'source "$REPO_ROOT/versions.env"' scripts/prepare-source.sh | cut -d: -f1)
test "$common_line" -lt "$require_line"
test "$require_line" -lt "$versions_line"

grep -Fq 'git clone --filter=blob:none --no-tags --branch "$IMMORTALWRT_BRANCH"' scripts/prepare-source.sh
grep -Fq 'checkout --detach "$IMMORTALWRT_COMMIT"' scripts/prepare-source.sh
grep -Fq 'src-git packages https://github.com/immortalwrt/packages.git^$PACKAGES_COMMIT' scripts/prepare-source.sh
grep -Fq 'src-git luci https://github.com/immortalwrt/luci.git^$LUCI_COMMIT' scripts/prepare-source.sh
grep -Fq 'src-git passwall_packages $PASSWALL_PACKAGES_REPO^$PASSWALL_PACKAGES_COMMIT' scripts/prepare-source.sh
grep -Fq 'src-git passwall $PASSWALL_REPO^$PASSWALL_COMMIT' scripts/prepare-source.sh
if grep -Eq 'src-git (routing|telephony|video|istore)' scripts/prepare-source.sh; then
  exit 1
fi
grep -Fq 'test "$(wc -l <"$feeds_conf")" -eq 4' scripts/prepare-source.sh
grep -Fq './scripts/feeds update -a' scripts/prepare-source.sh
grep -Fq './scripts/feeds install -a' scripts/prepare-source.sh
grep -Fq 'git clone --filter=blob:none --no-tags "$DAED_REPO"' scripts/prepare-source.sh
grep -Fq 'package/feeds/daed" checkout --detach "$DAED_COMMIT"' scripts/prepare-source.sh
grep -Fq 'package/feeds/luci-app-openclash' scripts/prepare-source.sh
grep -Fq 'OPENCLASH_COMMIT' scripts/prepare-source.sh
grep -Fq 'apply_repo_overlays "$SOURCE_DIR"' scripts/prepare-source.sh
grep -Fq 'rsync -a "$REPO_ROOT/files/" "$SOURCE_DIR/files/"' scripts/prepare-source.sh
grep -Fq 'rm -rf "$SOURCE_DIR/tmp"' scripts/prepare-source.sh
grep -Fq '"$SOURCE_DIR" rev-parse HEAD)' scripts/prepare-source.sh
grep -Fq '"$SOURCE_DIR/feeds/packages" rev-parse HEAD)' scripts/prepare-source.sh
grep -Fq '"$SOURCE_DIR/feeds/luci" rev-parse HEAD)' scripts/prepare-source.sh
grep -Fq '"$SOURCE_DIR/package/feeds/daed" rev-parse HEAD)' scripts/prepare-source.sh
grep -Fq 'feeds/passwall" rev-parse HEAD)' scripts/prepare-source.sh
if grep -Fq 'feeds/istore' scripts/prepare-source.sh; then
  exit 1
fi
if grep -Eq 'DAEDE_|feeds/daede|luci-app-daede' scripts/prepare-source.sh versions.env; then
  exit 1
fi

daed_overlay="device/edgepi-e87n/source-overlay/package/feeds/daed/daed/Makefile"
test -f "$daed_overlay"
daed_extract_line=$(grep -nF '$(TAR) --strip-components=1 -C $(DAED_BUILD_DIR)' "$daed_overlay" | cut -d: -f1)
wing_cleanup_line=$(grep -nF 'rm -rf $(PKG_BUILD_DIR) ;' "$daed_overlay" | cut -d: -f1)
wing_clone_line=$(grep -nF 'git clone https://github.com/daeuniverse/dae-wing $(PKG_BUILD_DIR) ;' "$daed_overlay" | cut -d: -f1)
test -n "$daed_extract_line"
test -n "$wing_cleanup_line"
test -n "$wing_clone_line"
test "$daed_extract_line" -lt "$wing_cleanup_line"
test "$wing_cleanup_line" -lt "$wing_clone_line"
grep -Fq 'NODE_VERSION:=v24.12.0' "$daed_overlay"
grep -Fq 'PNPM_VERSION:=10.24.0' "$daed_overlay"
grep -Fq 'npm install -g pnpm@$(PNPM_VERSION)' "$daed_overlay"
grep -Fq 'pnpm --version | grep -qx "$(PNPM_VERSION)"' "$daed_overlay"
grep -Fq 'pnpm install --no-frozen-lockfile' "$daed_overlay"
grep -Fq 'pnpm build --filter daed' "$daed_overlay"
grep -Fq 'test -f $(DAED_BUILD_DIR)/apps/web/dist/index.html' "$daed_overlay"
grep -Fq 'cp -rf $(DAED_BUILD_DIR)/apps/web/dist/* $(PKG_BUILD_DIR)/webrender/web' "$daed_overlay"
grep -Fq 'test -f $(PKG_BUILD_DIR)/webrender/web/index.html' "$daed_overlay"
if grep -Eq 'WEB_FILE|Download/daed-web|releases/download/v1\.27\.0' "$daed_overlay"; then
  exit 1
fi

empty_repo=$(mktemp -d)
trap 'rm -rf "$empty_repo"' EXIT
mkdir -p "$empty_repo/source"
REPO_ROOT="$empty_repo" apply_repo_overlays "$empty_repo/source"
