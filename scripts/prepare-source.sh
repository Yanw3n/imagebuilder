#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
WORK_DIR=${WORK_DIR:-"$REPO_ROOT/work"}
SOURCE_DIR="$WORK_DIR/immortalwrt"

source "$REPO_ROOT/scripts/lib/common.sh"
require_file "$REPO_ROOT/versions.env"
# Resolved from the checked repository root at runtime.
# shellcheck disable=SC1091
source "$REPO_ROOT/versions.env"
test ! -e "$SOURCE_DIR" || die "source directory already exists: $SOURCE_DIR"

mkdir -p "$WORK_DIR"

git clone --filter=blob:none --no-tags --branch "$IMMORTALWRT_BRANCH" \
  "$IMMORTALWRT_REPO" "$SOURCE_DIR"
git -C "$SOURCE_DIR" fetch --filter=blob:none --no-tags origin "$IMMORTALWRT_BRANCH"
git -C "$SOURCE_DIR" checkout --detach "$IMMORTALWRT_COMMIT"

feeds_conf="$SOURCE_DIR/feeds.conf.default"
require_file "$feeds_conf"
sed -i -E \
  -e "s#^(src-git(-full)? packages [^^[:space:]]+)(\\^[^[:space:]]+)?#\\1^$PACKAGES_COMMIT#" \
  -e "s#^(src-git(-full)? luci [^^[:space:]]+)(\\^[^[:space:]]+)?#\\1^$LUCI_COMMIT#" \
  "$feeds_conf"

grep -q "^src-git.* packages .*\\^$PACKAGES_COMMIT" "$feeds_conf" || die "packages feed is not pinned"
grep -q "^src-git.* luci .*\\^$LUCI_COMMIT" "$feeds_conf" || die "luci feed is not pinned"

(
  cd "$SOURCE_DIR"
  ./scripts/feeds update -a
  ./scripts/feeds install -a
)

mkdir -p "$SOURCE_DIR/package/feeds"
git clone --filter=blob:none --no-tags "$DAEDE_REPO" "$SOURCE_DIR/package/feeds/daede"
git -C "$SOURCE_DIR/package/feeds/daede" checkout --detach "$DAEDE_COMMIT"

apply_repo_overlays "$SOURCE_DIR"

test "$(git -C "$SOURCE_DIR" rev-parse HEAD)" = "$IMMORTALWRT_COMMIT" || die "ImmortalWrt HEAD is not pinned"
test "$(git -C "$SOURCE_DIR/feeds/packages" rev-parse HEAD)" = "$PACKAGES_COMMIT" || die "packages HEAD is not pinned"
test "$(git -C "$SOURCE_DIR/feeds/luci" rev-parse HEAD)" = "$LUCI_COMMIT" || die "LuCI HEAD is not pinned"
test "$(git -C "$SOURCE_DIR/package/feeds/daede" rev-parse HEAD)" = "$DAEDE_COMMIT" || die "daede HEAD is not pinned"

printf 'prepared pinned ImmortalWrt sources at %s\n' "$SOURCE_DIR"
