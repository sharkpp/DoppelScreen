#!/bin/bash
# .claude/hooks/block-dangerous-commands.sh
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$COMMAND" ]; then
  exit 0
fi

DANGEROUS_PATTERNS=(
  'rm -rf /'
  'rm -rf ~'
  'rm -rf \.'
  'sudo rm'
  'mkfs'
  'dd if=.* of=/dev/'
  '> /dev/sd'
  'chmod -R 777 /'
  'curl .* \| sh'
  'curl .* \| bash'
  'wget .* \| sh'
  'wget .* -O - \| bash'
  'eval \$\('
  ':\(\)\{ :\|:& \};:'
  'history -c'
  'shred'
)

for pattern in "${DANGEROUS_PATTERNS[@]}"; do
  if echo "$COMMAND" | grep -qE "$pattern"; then
    echo "BLOCKED: 危険なコマンドを検知: $COMMAND" >&2
    exit 2  # exit 2 = ブロック
  fi
done

# 本番環境への接続をブロック
if echo "$COMMAND" | grep -qE '(ssh|scp|rsync).*(prod|production|prd)'; then
  echo "BLOCKED: 本番環境への直接接続は禁止" >&2
  exit 2
fi

# .envファイルの読み取りをブロック
if echo "$COMMAND" | grep -qE 'cat.*\.env|less.*\.env|more.*\.env'; then
  echo "BLOCKED: .envファイルの読み取りは禁止" >&2
  exit 2
fi

exit 0
