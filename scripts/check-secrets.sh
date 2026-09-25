#!/bin/bash
# check-secrets.sh — refuse to commit anything token-shaped. Also used as the pre-commit hook:
#   ln -s ../../scripts/check-secrets.sh .git/hooks/pre-commit
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

PATTERN='ATCTT3[A-Za-z0-9_=-]{40,}|ATATT3[A-Za-z0-9_=-]{40,}|github_pat_[A-Za-z0-9_]{40,}|gh[pousr]_[A-Za-z0-9]{30,}|sk-ant-[A-Za-z0-9_-]{20,}|x-token-auth:[^@*<$ (]+@'
FORBIDDEN_PATHS='(^|/)(bb-credentials|gh-config)(/|$)|\.credentials\.json$|(^|/)\.claude\.json$|hosts\.yml$'

status=0
files=$(git ls-files -co --exclude-standard | grep -v '^scripts/check-secrets.sh$' || true)
if bad=$(grep -E "$FORBIDDEN_PATHS" <<<"$files"); then
  echo "check-secrets: credential paths in the repo:"; echo "$bad"; status=1
fi
if [ -n "$files" ] && hits=$(xargs -d '\n' grep -nIE "$PATTERN" -- <<<"$files"); then
  echo "check-secrets: token-shaped strings found:"
  sed -E 's/(ATCTT3|ATATT3|github_pat_|gh[pousr]_|sk-ant-|x-token-auth:)[^ "@]*/\1***/g' <<<"$hits"
  status=1
fi
# per-machine strings that must never be published (local/forbidden-strings, gitignored)
if [ -s local/forbidden-strings ] && [ -n "$files" ]; then
  if hits=$(xargs -d '\n' grep -nIiF -f <(grep -vE '^\s*(#|$)' local/forbidden-strings) -- <<<"$files"); then
    echo "check-secrets: strings from local/forbidden-strings found:"; echo "$hits"; status=1
  fi
fi
[ "$status" = 0 ] && echo "check-secrets: clean"
exit "$status"
