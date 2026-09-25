#!/bin/bash
# Bring up the egress firewall (needs CAP_NET_ADMIN/NET_RAW), then drop those
# capabilities and run the requested command. Dropping them matters: bubblewrap,
# which backs Claude Code's built-in Bash sandbox, refuses to start in a process
# that holds unexpected capabilities.
set -euo pipefail
if [ "${CLAUDE_SANDBOX_NO_FIREWALL:-0}" != "1" ]; then
  sudo /usr/local/bin/init-firewall.sh
fi
exec setpriv --ambient-caps=-all --inh-caps=-all -- "$@"
