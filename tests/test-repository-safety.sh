#!/usr/bin/env bash
set -euo pipefail

test -f versions.env
grep -qx 'IMMORTALWRT_COMMIT=3dacd2fb6a48c5963b1026c6a343ec7e67cbf810' versions.env

for pattern in '*.img' '*.img.gz' '*factory*' '*boot0*' '*boot1*' '*fip*'; do
  test -z "$(git ls-files "$pattern")"
done

credential_pattern='BEGIN '
credential_pattern+='.*'
credential_pattern+='PRIVATE KEY|auth'
credential_pattern+='key-|tailscale'
credential_pattern+='.*'
credential_pattern+='key|pass'
credential_pattern+='word'
credential_pattern+='='
documented_match="! git grep -IE '($credential_pattern)'"
allowlisted_credential_match="docs/superpowers/plans/2026-08-04-e87n-daede-firmware.md:87:$documented_match"

filter_credential_matches() {
  while IFS= read -r match; do
    case "$match" in
      "$allowlisted_credential_match") ;;
      *) test -z "$match" || printf '%s\n' "$match" ;;
    esac
  done
}

test -z "$(printf '%s\n' "$allowlisted_credential_match" | filter_credential_matches)"
unexpected_document_match="docs/superpowers/plans/2026-08-04-e87n-daede-firmware.md:88:$documented_match"
test "$(printf '%s\n' "$unexpected_document_match" | filter_credential_matches)" = "$unexpected_document_match"

credential_matches="$(git grep -n -IE "$credential_pattern" || true)"
credential_matches="$(printf '%s\n' "$credential_matches" | filter_credential_matches)"
test -z "$credential_matches"

network_defaults=files/etc/uci-defaults/99-daed-test-network
test -f "$network_defaults"
grep -qx "uci set network.lan.ipaddr='192.168.1.1'" "$network_defaults"
! grep -Eq 'network\.lan\.(gateway|dns)' "$network_defaults"

# These paths represent supplied firmware, router-specific captures, and
# backups. They must stay ignored, including when a broad `git add -A` is used.
for private_path in \
  'HiGoROS-E87N-1-26-05-09-02.bin' \
  'e87n-info.txt' \
  'e87n-fan-info.txt' \
  'work-test/' \
  '.private/e87n-network-runtime.txt' \
  'backup/router-config.tar' \
  'backups/router-config.tar' \
  'router-config.bak' \
  'router-config.backup'; do
  git check-ignore -q -- "$private_path"
done

dry_run="$(git add -A -n)"
for private_path in \
  'HiGoROS-E87N-1-26-05-09-02.bin' \
  'e87n-info.txt' \
  'e87n-fan-info.txt' \
  'work-test/'; do
  ! grep -F -- "$private_path" <<<"$dry_run"
done
