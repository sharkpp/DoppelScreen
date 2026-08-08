#!/bin/bash
# .claude/hooks/scan-secrets.sh
INPUT=$(cat)
CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // .tool_input.new_string // empty')

if [ -z "$CONTENT" ]; then
  exit 0
fi

PATTERNS=(
  'AKIA[0-9A-Z]{16}'                                  # AWS Access Key
  'sk-[a-zA-Z0-9]{48}'                                # OpenAI API Key
  'sk-ant-[a-zA-Z0-9-]{95}'                           # Anthropic API Key
  'ghp_[a-zA-Z0-9]{20,}'                              # GitHub Token
  'gho_[a-zA-Z0-9]{20,}'                              # GitHub OAuth Token
  'glpat-[a-zA-Z0-9-]{20}'                            # GitLab Token
  'xoxb-[0-9]{10,13}-[0-9]{10,13}-[a-zA-Z0-9]{24}'   # Slack Bot Token
  '-----BEGIN (RSA |EC |DSA )?PRIVATE KEY-----'        # Private Key
)

for pattern in "${PATTERNS[@]}"; do
  if echo "$CONTENT" | grep -qE -- "$pattern"; then
    echo "BLOCKED: シークレット情報の書き込みを検知" >&2
    exit 2
  fi
done

exit 0
