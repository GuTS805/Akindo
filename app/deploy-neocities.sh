#!/usr/bin/env bash
# Upload app/dist to https://mblp.neocities.org (run "npm run build" first).
# Reads the API key from ~/.neocities-key, outside the repo, and never prints it.
set -euo pipefail
KEYFILE="$HOME/.neocities-key"
[ -f "$KEYFILE" ] || KEYFILE="$HOME/.neocities-key.txt"
KEY=$(tr -d ' \r\n' < "$KEYFILE")
cd "$(dirname "$0")/dist"
args=()
while IFS= read -r f; do
  p="${f#./}"
  case "$p" in CNAME|200.html) continue;; esac
  args+=(-F "$p=@$p")
done < <(find . -type f)
echo "uploading $(( ${#args[@]} / 2 )) files"
curl -s -m 600 -H "Authorization: Bearer $KEY" "${args[@]}" https://neocities.org/api/upload
echo
