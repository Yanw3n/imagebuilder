#!/bin/sh
set -eu

repo_root=$(cd -- "$(dirname -- "$0")/.." && pwd)
patch_file=patches/immortalwrt/0004-rust-disable-ci-llvm-download.patch

cd "$repo_root"
test -f "$patch_file"

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT HUP INT TERM
mkdir -p "$fixture/feeds/packages/lang/rust"
rust_makefile="$fixture/feeds/packages/lang/rust/Makefile"
: >"$rust_makefile"
line=1
while test "$line" -lt 79; do
	printf '# fixture line %s\n' "$line" >>"$rust_makefile"
	line=$((line + 1))
done
printf '\t--set=llvm.download-ci-llvm=true \\\n' >>"$rust_makefile"

sed 's/\r$//' "$patch_file" >"$fixture/rust-toolchain.patch"

(
	cd "$fixture"
	git apply --unidiff-zero rust-toolchain.patch
)

grep -Fq -- '--set=llvm.download-ci-llvm=false' "$rust_makefile"
if grep -Fq -- '--set=llvm.download-ci-llvm=true' "$rust_makefile"; then
	printf '%s\n' 'CI LLVM download remains enabled after applying policy patch' >&2
	exit 1
fi
printf '%s\n' 'PASS: Rust host build does not depend on ephemeral CI LLVM artifacts'
