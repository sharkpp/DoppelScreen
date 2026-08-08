#!/bin/bash
# .claude/hooks/auto-lint.sh
INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

if [ -z "$FILE_PATH" ] || [ ! -f "$FILE_PATH" ]; then
  exit 0
fi

case "${FILE_PATH##*.}" in
  js|jsx|ts|tsx)
    npx eslint --fix "$FILE_PATH" 2>/dev/null
    npx prettier --write "$FILE_PATH" 2>/dev/null
    ;;
  py)
    ruff check --fix "$FILE_PATH" 2>/dev/null
    ruff format "$FILE_PATH" 2>/dev/null
    ;;
  go)
    gofmt -w "$FILE_PATH" 2>/dev/null
    ;;
esac

exit 0
