#!/usr/bin/env bash
set -Eeuo pipefail

[[ "${1:-}" == "rpc" ]] || exit 64
while IFS= read -r request; do
  id="$(printf '%s\n' "$request" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
  [[ -n "$id" ]] || id="unknown"
  case "$id" in
    force-wrong-id)
      printf '{"jsonrpc":"2.0","id":"wrong-id","result":{"ok":true}}\n'
      continue
      ;;
    oversize)
      dd if=/dev/zero bs=1048576 count=5 2>/dev/null | tr '\0' x
      printf '\n'
      continue
      ;;
    timeout)
      sleep 5
      ;;
  esac
  if [[ "$id" == read ]] &&
    [[ "$request" != *'"attachments":false'* ||
       "$request" != *'"convert_attachments":false'* ||
       "$request" != *'"include_reactions":false'* ]]; then
    printf '{"jsonrpc":"2.0","id":"read","error":{"code":-32602,"message":"unsafe read params"}}\n'
    continue
  fi
  if [[ "$id" == send || "$id" == sipgate-sms ]] && [[ "$request" != *'"transport":"applescript"'* ]]; then
    printf '{"jsonrpc":"2.0","id":"%s","error":{"code":-32602,"message":"unsafe send transport"}}\n' "$id"
    continue
  fi
  printf '{"jsonrpc":"2.0","id":"%s","result":{"ok":true,"chats":[],"messages":[]}}\n' "$id"
done
