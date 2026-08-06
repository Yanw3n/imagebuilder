#!/usr/bin/env bash
set -euo pipefail

usage() { printf 'usage: %s full|rescue\n' "${0##*/}" >&2; exit 2; }
test "$#" -eq 1 || usage
case "$1" in full|rescue) PROFILE=$1 ;; *) usage ;; esac

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=${E87N_REPO_ROOT:-$(cd -- "$SCRIPT_DIR/.." && pwd)}
SOURCE_DIR=${IMMORTALWRT_SOURCE:-"${WORK_DIR:-$REPO_ROOT/work}/immortalwrt"}
OUT_DIR=${OUT_DIR:-"$REPO_ROOT/out"}
BASH_BIN=${BASH:-bash}
source "$REPO_ROOT/scripts/lib/common.sh"
mkdir -p "$OUT_DIR"
lock_file="$OUT_DIR/.$PROFILE.lock"
exec {lock_fd}>"$lock_file"
flock -x "$lock_fd"

# Discover once. Caller-supplied validator overrides must never select bytes
# different from those that this collector will publish.
mapfile -d '' -t candidates < <(find "$SOURCE_DIR/bin/targets" -type f -name '*sysupgrade*.bin' -print0 2>/dev/null)
images=()
for candidate in "${candidates[@]}"; do
  if tar -tf "$candidate" 2>/dev/null | grep -qx 'sysupgrade-edgepi_e87n/CONTROL' &&
     tar -tf "$candidate" 2>/dev/null | grep -qx 'sysupgrade-edgepi_e87n/kernel'; then
    images+=("$candidate")
  fi
done
test "${#images[@]}" -eq 1 || die "expected exactly one E87N sysupgrade image, found ${#images[@]}"
IMAGE=${images[0]}
mapfile -d '' -t manifests < <(find "$SOURCE_DIR/bin/targets" -type f -iname '*edgepi_e87n*.manifest' -print0 2>/dev/null)
test "${#manifests[@]}" -eq 1 || die "expected exactly one E87N package manifest, found ${#manifests[@]}"
MANIFEST=${manifests[0]}
require_file "$SOURCE_DIR/.config"

image_hash_before=$(sha256sum "$IMAGE" | awk '{print $1}')
manifest_hash_before=$(sha256sum "$MANIFEST" | awk '{print $1}')
config_hash_before=$(sha256sum "$SOURCE_DIR/.config" | awk '{print $1}')
validation_tmp=$(mktemp "${TMPDIR:-/tmp}/e87n-validation.XXXXXX")
trap 'rm -f "$validation_tmp"' EXIT
if ! E87N_IMAGE="$IMAGE" E87N_MANIFEST="$MANIFEST" E87N_DTB='' E87N_VMLINUX='' \
  IMMORTALWRT_SOURCE="$SOURCE_DIR" \
  "$BASH_BIN" "$REPO_ROOT/scripts/validate-e87n.sh" "$PROFILE" >"$validation_tmp"; then
  die 'artifact validation failed; nothing was published'
fi

transaction=$(mktemp -d "$OUT_DIR/.$PROFILE.publish.XXXXXX")
staging="$transaction/staging"
previous="$transaction/previous"
mkdir "$staging"
profile_out="$OUT_DIR/$PROFILE"
previous_moved=0
rollback_failed=0
publication_cleanup_failed=0
publication_state=preparing
rollback_previous() {
  local conflict="$transaction/conflict"
  if test -e "$profile_out"; then
    mv -T "$profile_out" "$conflict" || return 1
  fi
  mv -T "$previous" "$profile_out" || return 1
  previous_moved=0
  publication_state=rolled_back
  rm -rf "$conflict"
}
quarantine_unverified() {
  local unverified="$transaction/unverified"
  if test -e "$profile_out" && ! mv -T "$profile_out" "$unverified"; then
    rm -rf "$profile_out"
  fi
  test ! -e "$profile_out"
}
cleanup() {
  local status=$?
  rm -f "$validation_tmp"
  if test -e "$previous"; then previous_moved=1; fi
  if test "$publication_state" != verified && test "$previous_moved" = 1 && test "$rollback_failed" = 0 && test -e "$previous"; then
    if ! rollback_previous; then rollback_failed=1; fi
  fi
  if test "$publication_state" = pending && test ! -e "$staging" && test -e "$profile_out"; then
    if ! quarantine_unverified; then publication_cleanup_failed=1; fi
  fi
  if test "$rollback_failed" = 1; then
    printf 'error: rollback failed; manual recovery retained at %s\n' "$previous" >&2
  elif test "$publication_cleanup_failed" = 1; then
    printf 'error: unverified publication cleanup failed at %s\n' "$profile_out" >&2
  else
    rm -rf "$transaction"
  fi
  return "$status"
}
on_signal() {
  local code=$1
  trap - HUP INT TERM
  exit "$code"
}
trap cleanup EXIT
trap 'on_signal 129' HUP
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

base="edgepi-e87n-immortalwrt-25.12-$PROFILE"
cp "$IMAGE" "$staging/$base-sysupgrade.bin"
cp "$MANIFEST" "$staging/$base.manifest"
cp "$SOURCE_DIR/.config" "$staging/$base.config"
cp "$validation_tmp" "$staging/VALIDATION.txt"
test "$(sha256sum "$staging/$base-sysupgrade.bin" | awk '{print $1}')" = "$image_hash_before" || die 'sysupgrade changed during validation/copy'
test "$(sha256sum "$staging/$base.manifest" | awk '{print $1}')" = "$manifest_hash_before" || die 'manifest changed during validation/copy'
test "$(sha256sum "$staging/$base.config" | awk '{print $1}')" = "$config_hash_before" || die 'resolved config changed during validation/copy'

# Resolved from the checked repository root at runtime.
# shellcheck disable=SC1091
source "$REPO_ROOT/versions.env"
cat >"$staging/BUILD-MANIFEST.txt" <<EOF
PROFILE=$PROFILE
BOARD=edgepi,e87n
TARGET=mediatek/filogic
IMMORTALWRT_COMMIT=$IMMORTALWRT_COMMIT
PACKAGES_COMMIT=$PACKAGES_COMMIT
LUCI_COMMIT=$LUCI_COMMIT
DAEDE_COMMIT=$DAEDE_COMMIT
IMAGE=$base-sysupgrade.bin
PACKAGES=$base.manifest
RESOLVED_CONFIG=$base.config
EOF

find "$staging" -maxdepth 1 -type f \( -iname '*preloader*' -o -iname '*fip*' -o -iname '*factory*' -o -iname '*disk*' -o -iname '*.img' -o -iname '*.img.gz' -o -iname '*.qcow*' -o -iname '*.vmdk' \) -delete
expected_files=$(printf '%s\n' BUILD-MANIFEST.txt VALIDATION.txt "$base-sysupgrade.bin" "$base.config" "$base.manifest" | sort)
actual_files=$(find "$staging" -maxdepth 1 -type f -printf '%f\n' | sort)
test "$actual_files" = "$expected_files" || die 'staging contains missing or stale files'
(
  cd "$staging"
  sha256sum BUILD-MANIFEST.txt VALIDATION.txt "$base-sysupgrade.bin" "$base.config" "$base.manifest" >SHA256SUMS
  sha256sum -c SHA256SUMS >/dev/null
)
expected_published=$(printf '%s\n' BUILD-MANIFEST.txt SHA256SUMS VALIDATION.txt "$base-sysupgrade.bin" "$base.config" "$base.manifest" | sort)
verify_published() {
  local entry published_entries
  test -d "$profile_out" && test ! -L "$profile_out" || return 1
  published_entries=$(find "$profile_out" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort) || return 1
  test "$published_entries" = "$expected_published" || return 1
  while IFS= read -r entry; do
    test -f "$profile_out/$entry" && test ! -L "$profile_out/$entry" || return 1
  done <<<"$expected_published"
  publication_state=verified
}

if test -e "$profile_out"; then
  previous_moved=1
  mv -T "$profile_out" "$previous"
  if test ! -e "$previous"; then previous_moved=0; die 'failed to save prior validated output'; fi
fi
publication_state=pending
if ! mv -T "$staging" "$profile_out"; then
  if test "$previous_moved" = 1; then
    if ! rollback_previous; then
      rollback_failed=1
      die "publication and rollback failed; manual recovery retained at $previous"
    fi
  fi
  die 'final artifact publication failed'
fi
if ! verify_published; then
  if test "$previous_moved" = 1; then
    if ! rollback_previous; then
      rollback_failed=1
      die "published output verification and rollback failed; manual recovery retained at $previous"
    fi
    die 'published output verification failed; prior output restored'
  else
    invalid="$transaction/invalid"
    if test -e "$profile_out" && ! mv -T "$profile_out" "$invalid"; then
      rm -rf "$profile_out"
    fi
    test ! -e "$profile_out" || die 'published output verification failed; invalid first publication could not be removed'
    die 'published output verification failed; invalid first publication removed'
  fi
fi
if test "$previous_moved" = 1; then
  rm -rf "$previous"
  previous_moved=0
fi
rm -rf "$transaction"
trap - EXIT HUP INT TERM
rm -f "$validation_tmp"
cat "$profile_out/VALIDATION.txt"
