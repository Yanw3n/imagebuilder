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
grep -Fq 'src-git istore $ISTORE_REPO^$ISTORE_COMMIT' scripts/prepare-source.sh
if grep -Eq 'src-git (routing|telephony|video)' scripts/prepare-source.sh; then
  exit 1
fi
grep -Fq 'test "$(wc -l <"$feeds_conf")" -eq 5' scripts/prepare-source.sh
grep -Fq './scripts/feeds update -a' scripts/prepare-source.sh
grep -Fq './scripts/feeds install -a' scripts/prepare-source.sh
grep -Fq 'git clone --filter=blob:none --no-tags "$DAEDE_REPO"' scripts/prepare-source.sh
grep -Fq 'package/feeds/daede" checkout --detach "$DAEDE_COMMIT"' scripts/prepare-source.sh
grep -Fq 'package/feeds/luci-app-openclash' scripts/prepare-source.sh
grep -Fq 'OPENCLASH_COMMIT' scripts/prepare-source.sh
grep -Fq 'apply_repo_overlays "$SOURCE_DIR"' scripts/prepare-source.sh
grep -Fq 'rsync -a "$REPO_ROOT/files/" "$SOURCE_DIR/files/"' scripts/prepare-source.sh
grep -Fq 'rm -rf "$SOURCE_DIR/tmp"' scripts/prepare-source.sh
grep -Fq '"$SOURCE_DIR" rev-parse HEAD)' scripts/prepare-source.sh
grep -Fq '"$SOURCE_DIR/feeds/packages" rev-parse HEAD)' scripts/prepare-source.sh
grep -Fq '"$SOURCE_DIR/feeds/luci" rev-parse HEAD)' scripts/prepare-source.sh
grep -Fq '"$SOURCE_DIR/package/feeds/daede" rev-parse HEAD)' scripts/prepare-source.sh
grep -Fq 'feeds/passwall" rev-parse HEAD)' scripts/prepare-source.sh
grep -Fq 'feeds/istore" rev-parse HEAD)' scripts/prepare-source.sh

empty_repo=$(mktemp -d)
trap 'rm -rf "$empty_repo"' EXIT
mkdir -p "$empty_repo/source"
REPO_ROOT="$empty_repo" apply_repo_overlays "$empty_repo/source"
