#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_file() {
  test -f "$1" || die "missing file: $1"
}

normalize_bool() {
  case "$1" in
    true|1|yes) printf '1\n' ;;
    false|0|no) printf '0\n' ;;
    *) return 2 ;;
  esac
}

apply_repo_overlays() {
  local source_dir=$1
  local repo_root=${REPO_ROOT:-$PWD}
  local overlay_dir="$repo_root/device/edgepi-e87n/source-overlay"
  local package_dir="$repo_root/package/e87n"
  local patch_dir="$repo_root/patches/immortalwrt"
  local patch_file

  test -d "$source_dir" || die "missing source directory: $source_dir"

  if test -d "$overlay_dir"; then
    rsync -a "$overlay_dir/" "$source_dir/"
  fi

  if test -d "$package_dir"; then
    mkdir -p "$source_dir/package/e87n"
    rsync -a "$package_dir/" "$source_dir/package/e87n/"
  fi

  if test -d "$patch_dir"; then
    shopt -s nullglob
    for patch_file in "$patch_dir"/*.patch; do
      patch --batch --forward -d "$source_dir" -p1 < "$patch_file"
    done
    shopt -u nullglob
  fi
}
