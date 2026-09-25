#!/bin/bash
# init-firewall.sh — default-deny egress for the sandbox container, allowlisted by DNS name.
#
# Design:
#   * dnsmasq on 127.0.0.1 is the container's only resolver. For every allowlisted name (and its
#     subdomains) it adds each A record it hands out to the ipset "egress-allow" before answering,
#     so connections to allowlisted hosts work even when their CDN IPs rotate.
#   * iptables accepts outbound traffic only to addresses in that set (plus loopback and replies).
#     Everything else is rejected, including the LAN.
#   * Only root — i.e. dnsmasq — may talk to upstream DNS, so sandboxed code can't tunnel data out
#     through DNS queries (needs the xt_owner kernel module on the host; falls back with a warning).
#   * IPv6 is dropped entirely (the rules below are IPv4 only).
#   * GitHub's published ranges are added up front, since git traffic sometimes goes to raw IPs.
#
# Runs as root at container start (entrypoint.sh, via a sudoers rule limited to this script).
# Safe to re-run.
set -euo pipefail

# Allowlisted base names; each covers all of its subdomains.
ALLOW_DOMAINS=(
  api.anthropic.com mcp-proxy.anthropic.com statsig.anthropic.com   # Claude Code, Remote Control
  claude.ai claude.com                     # login, downloads, platform.claude.com, code.claude.com
  sentry.io statsig.com                    # Claude Code telemetry
  github.com githubusercontent.com         # git, gh, raw content, release assets
  bitbucket.org                            # git + api.bitbucket.org
  registry.npmjs.org
  pypi.org pythonhosted.org
  golang.org go.dev storage.googleapis.com # module proxy, checksum db, toolchain downloads
  astral.sh                                # uv-managed Python builds
)
# Per-machine additions baked in at build time (EXTRA_DOMAINS in devbox.conf).
EXTRA_FILE=/etc/sandbox/extra-domains
if [ -r "$EXTRA_FILE" ]; then
  while read -r d; do [ -n "$d" ] && ALLOW_DOMAINS+=("$d"); done < <(grep -vE '^\s*(#|$)' "$EXTRA_FILE" || true)
fi
# Resolved once up front so the first real connections don't race the resolver.
PREWARM=(api.anthropic.com claude.ai platform.claude.com github.com api.github.com
         objects.githubusercontent.com registry.npmjs.org pypi.org files.pythonhosted.org
         proxy.golang.org bitbucket.org api.bitbucket.org)

SET=egress-allow
UPSTREAM=/etc/resolv.upstream.conf
DNSMASQ_CONF=/etc/dnsmasq-egress.conf

say() { echo "[firewall] $*"; }
fail() { echo "[firewall] ERROR: $*" >&2; exit 1; }

open_everything() {
  # Known-good starting point: no rules, permissive policies. Also makes re-runs deterministic.
  pkill -x dnsmasq 2>/dev/null || true
  local t
  for t in filter nat mangle; do iptables -t "$t" -F; iptables -t "$t" -X; done
  iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT; iptables -P OUTPUT ACCEPT
  ipset destroy "$SET" 2>/dev/null || true
}

close_ipv6() {
  ip6tables-restore <<'RULES'
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT DROP [0:0]
-A INPUT -i lo -j ACCEPT
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -j REJECT --reject-with icmp6-adm-prohibited
COMMIT
RULES
}

add_github_ranges() {
  local meta n=0 cidr
  meta=$(curl -fsS --max-time 20 https://api.github.com/meta) || fail "could not fetch api.github.com/meta"
  while read -r cidr; do
    [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || continue   # IPv4 only
    ipset add -exist "$SET" "$cidr"; n=$((n + 1))
  done < <(jq -r '.web[]?, .api[]?, .git[]?' <<<"$meta")
  [ "$n" -gt 0 ] || fail "no IPv4 ranges in api.github.com/meta"
  say "added $n GitHub ranges"
}

start_resolver() {
  [ -s "$UPSTREAM" ] || grep -E '^(nameserver|search|options)' /etc/resolv.conf > "$UPSTREAM"
  local joined
  joined=$(IFS=/; echo "${ALLOW_DOMAINS[*]}")
  cat > "$DNSMASQ_CONF" <<CONF
user=root
listen-address=127.0.0.1
bind-interfaces
no-hosts
resolv-file=$UPSTREAM
cache-size=1000
ipset=/$joined/$SET
CONF
  dnsmasq --conf-file="$DNSMASQ_CONF"
  printf 'nameserver 127.0.0.1\noptions ndots:0\n' > /etc/resolv.conf
}

owner_match_works() {
  iptables -N owner-probe 2>/dev/null || iptables -F owner-probe
  local ok=1
  iptables -A owner-probe -m owner --uid-owner 0 -j RETURN 2>/dev/null || ok=0
  iptables -F owner-probe; iptables -X owner-probe
  [ "$ok" = 1 ]
}

lock_down() {
  local dns
  if owner_match_works; then
    dns=$'-A OUTPUT -p udp --dport 53 -m owner --uid-owner 0 -j ACCEPT\n-A OUTPUT -p tcp --dport 53 -m owner --uid-owner 0 -j ACCEPT'
    DNS_MODE="upstream DNS limited to dnsmasq"
  else
    dns=$'-A OUTPUT -p udp --dport 53 -j ACCEPT\n-A OUTPUT -p tcp --dport 53 -j ACCEPT'
    DNS_MODE="WARNING: xt_owner unavailable on host, upstream DNS open to all processes"
  fi
  iptables-restore <<RULES
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT DROP [0:0]
-A INPUT -i lo -j ACCEPT
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
$dns
-A OUTPUT -m set --match-set $SET dst -j ACCEPT
-A OUTPUT -j REJECT --reject-with icmp-admin-prohibited
COMMIT
RULES
}

prewarm() {
  local h
  for h in "${PREWARM[@]}"; do getent ahostsv4 "$h" >/dev/null 2>&1 || say "note: could not resolve $h"; done
}

self_test() {
  local fam h
  for fam in 4 6; do
    if curl -"$fam" -fsS --connect-timeout 5 -o /dev/null https://example.com 2>/dev/null; then
      fail "self-test: example.com reachable over IPv$fam"
    fi
  done
  for h in api.github.com api.anthropic.com files.pythonhosted.org; do
    curl -sS --connect-timeout 5 -o /dev/null "https://$h/" || fail "self-test: cannot reach $h"
  done
  say "self-test passed: example.com blocked; github, anthropic, pythonhosted reachable"
}

open_everything
close_ipv6
ipset create "$SET" hash:net
add_github_ranges
start_resolver
lock_down
prewarm
say "egress allowlist active ($DNS_MODE)"
self_test
