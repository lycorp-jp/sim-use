#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# One-shot helper: prepend an SPDX license identifier to every source file that
# does not already carry one. Idempotent — safe to re-run. Run from repo root.
set -euo pipefail

cd "$(dirname "$0")/.."

ID="SPDX-License-Identifier: Apache-2.0"
added=0
skipped=0

prepend_line_comment() {  # // style, header on line 1
  local f="$1"
  printf '// %s\n%s' "$ID" "$(cat "$f")" >"$f.tmp" && mv "$f.tmp" "$f"
}

prepend_block_comment() { # /* */ style (CSS)
  local f="$1"
  printf '/* %s */\n%s' "$ID" "$(cat "$f")" >"$f.tmp" && mv "$f.tmp" "$f"
}

insert_after_shebang() {  # # style, after a leading #! line if present
  local f="$1"
  if head -1 "$f" | grep -q '^#!'; then
    { head -1 "$f"; printf '# %s\n' "$ID"; tail -n +2 "$f"; } >"$f.tmp" && mv "$f.tmp" "$f"
  else
    printf '# %s\n%s' "$ID" "$(cat "$f")" >"$f.tmp" && mv "$f.tmp" "$f"
  fi
}

while IFS= read -r -d '' f; do
  if grep -q "$ID" "$f"; then skipped=$((skipped+1)); continue; fi
  case "$f" in
    ./Package.swift) skipped=$((skipped+1)); continue ;;  # tools-version must stay line 1
    *.swift|*.kt|*.ts) prepend_line_comment "$f"; added=$((added+1)) ;;
    *.css)             prepend_block_comment "$f"; added=$((added+1)) ;;
    *.sh)              insert_after_shebang "$f"; added=$((added+1)) ;;
  esac
done < <(find . -path ./.git -prune -o \
  \( -name '*.swift' -o -name '*.kt' -o -name '*.ts' -o -name '*.css' -o -name '*.sh' \) \
  -type f -print0)

echo "SPDX headers added: $added, skipped (already had / excluded): $skipped"
