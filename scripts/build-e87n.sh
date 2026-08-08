#!/usr/bin/env bash
set -euo pipefail

usage() { printf 'usage: %s full|rescue\n' "${0##*/}" >&2; exit 2; }
test "$#" -eq 1 || usage
case "$1" in full|rescue) PROFILE=$1 ;; *) usage ;; esac

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=${E87N_REPO_ROOT:-$(cd -- "$SCRIPT_DIR/.." && pwd)}
WORK_DIR=${WORK_DIR:-"$REPO_ROOT/work"}
SOURCE_DIR=${IMMORTALWRT_SOURCE:-"$WORK_DIR/immortalwrt"}
BASH_BIN=${BASH:-bash}
source "$REPO_ROOT/scripts/lib/common.sh"
require_file "$REPO_ROOT/versions.env"
# Resolved from the checked repository root at runtime.
# shellcheck disable=SC1091
source "$REPO_ROOT/versions.env"

require_file "$SOURCE_DIR/Makefile"
require_file "$SOURCE_DIR/scripts/kconfig.pl"
for dir in "$SOURCE_DIR/feeds/packages" "$SOURCE_DIR/feeds/luci" "$SOURCE_DIR/package/feeds/daed"; do
  test -d "$dir" || die "prepared pinned source incomplete: $dir"
done
test "$(git -C "$SOURCE_DIR" rev-parse HEAD)" = "$IMMORTALWRT_COMMIT" || die 'ImmortalWrt source is not pinned'
test "$(git -C "$SOURCE_DIR/feeds/packages" rev-parse HEAD)" = "$PACKAGES_COMMIT" || die 'packages feed is not pinned'
test "$(git -C "$SOURCE_DIR/feeds/luci" rev-parse HEAD)" = "$LUCI_COMMIT" || die 'LuCI feed is not pinned'
test "$(git -C "$SOURCE_DIR/package/feeds/daed" rev-parse HEAD)" = "$DAED_COMMIT" || die 'daed (QiuSimons) feed is not pinned'

policy_log=$(mktemp "${TMPDIR:-/tmp}/e87n-policy.XXXXXX")
trap 'rm -f "$policy_log"' EXIT
if ! IMMORTALWRT_SOURCE="$SOURCE_DIR" "$BASH_BIN" "$REPO_ROOT/tests/test-config-fragments.sh" >"$policy_log" 2>&1; then
  cat "$policy_log" >&2
  die 'Task 6 resolved policy checks failed'
fi
cat "$policy_log"
if grep -q '^SKIP: resolved config validation:' "$policy_log"; then
  die 'Task 6 resolved policy checks may not SKIP during a build'
fi

cp "$REPO_ROOT/configs/common.config" "$SOURCE_DIR/.config"
"$SOURCE_DIR/scripts/kconfig.pl" + "$SOURCE_DIR/.config" \
  "$REPO_ROOT/configs/$PROFILE.config" >"$SOURCE_DIR/.config.e87n-new"
mv "$SOURCE_DIR/.config.e87n-new" "$SOURCE_DIR/.config"
make -C "$SOURCE_DIR" defconfig

awk '
  /^CONFIG_[A-Za-z0-9_-]+=y$/ { s=$0; sub(/=y$/, "", s); state[s]="y"; if(!seen[s]++) order[++n]=s }
  /^# CONFIG_[A-Za-z0-9_-]+ is not set$/ { s=$0; sub(/^# /,"",s); sub(/ is not set$/,"",s); state[s]="n"; if(!seen[s]++) order[++n]=s }
  END { for(i=1;i<=n;i++) print state[order[i]], order[i] }
' "$REPO_ROOT/configs/common.config" "$REPO_ROOT/configs/$PROFILE.config" |
while read -r state symbol; do
  if test "$state" = y; then
    grep -qx "$symbol=y" "$SOURCE_DIR/.config" || die "resolved config drops $symbol"
  elif grep -Eq "^$symbol=[ym]$" "$SOURCE_DIR/.config"; then
    die "resolved config enables prohibited $symbol"
  fi
done

if ! make -C "$SOURCE_DIR" download -j8; then
  make -C "$SOURCE_DIR" download -j1 V=s || true
  die 'source download failed'
fi
jobs=$(nproc 2>/dev/null || printf '1\n')
if ! make -C "$SOURCE_DIR" "-j$jobs"; then
  make -C "$SOURCE_DIR" -j1 V=s || true
  die 'firmware build failed'
fi

IMMORTALWRT_SOURCE="$SOURCE_DIR" "$BASH_BIN" "$REPO_ROOT/scripts/collect-artifacts.sh" "$PROFILE"
