#!/bin/bash
# install-host.sh — deploy host/ to / and ensure the host-level state the sandbox relies on.
# Needs root; run from your own terminal (sudo prompts for a password):
#
#   sudo ./install-host.sh --check          report only; exit 1 on drift
#   sudo ./install-host.sh                  apply
#   ./install-host.sh --render <dir>        write the rendered files to <dir> and exit (no root needed)
#
# Idempotent. sshd and sudoers changes are validated before they can take effect.
set -euo pipefail
REPO=$(cd "$(dirname "$0")" && pwd)
. "$REPO/lib/common.sh"
MODE="${1:---install}"
case "$MODE" in
  --install|--check) [ "$(id -u)" = 0 ] || die "run with sudo" ;;
  --render) [ -n "${2:-}" ] || die "--render needs a directory" ;;
  *) sed -n '2,9p' "$0"; exit 2 ;;
esac
CHECK=0; [ "$MODE" = --check ] && CHECK=1
load_conf

# --- render the file set for this machine into a staging dir that mirrors /
STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT
declare -A MODES
add() {  # add <path under host/> <mode>
  local dest; dest=$(render_name "$1")
  render "$REPO/host/$1" "$STAGE/$dest"; MODES[$dest]=$2
}
add "etc/sudoers.d/@ADMIN_USER@-as-@SANDBOX_USER@" 440
add "etc/modules-load.d/claude-sandbox.conf" 644
[ "$SSH_HARDENING" = 1 ] && add "etc/ssh/sshd_config.d/60-hardening.conf" 644
[ "$LAPTOP_SERVER" = 1 ] && add "etc/systemd/logind.conf.d/10-lid-ignore.conf" 644

if [ "$MODE" = --render ]; then
  mkdir -p "$2"; cp -a "$STAGE/." "$2/"; echo "rendered into $2"; exit 0
fi

SLEEP_TARGETS=(sleep.target suspend.target hibernate.target hybrid-sleep.target)
PACKAGES=(podman tmux uidmap python3)

drift=0 changed=()
note() { drift=1; echo "$*"; }

# --- packages
for p in "${PACKAGES[@]}"; do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' && continue
  note "package missing: $p"
  [ "$CHECK" = 1 ] || apt-get install -y "$p"
done

# --- users
id "$ADMIN_USER" >/dev/null 2>&1 || die "ADMIN_USER '$ADMIN_USER' does not exist"
if ! id "$SANDBOX_USER" >/dev/null 2>&1; then
  note "user $SANDBOX_USER missing"
  [ "$CHECK" = 1 ] || adduser --disabled-password --gecos "" "$SANDBOX_USER"
fi
if id "$SANDBOX_USER" >/dev/null 2>&1; then
  if id -nG "$SANDBOX_USER" | tr ' ' '\n' | grep -qxE 'sudo|admin|wheel|docker|lxd'; then
    note "WARNING: $SANDBOX_USER is in a privileged group ($(id -nG "$SANDBOX_USER")) — remove it by hand"
  fi
  for f in /etc/subuid /etc/subgid; do
    grep -q "^$SANDBOX_USER:" "$f" && continue
    note "no $SANDBOX_USER entry in $f (rootless podman needs one)"
    [ "$CHECK" = 1 ] || usermod --add-subuids "$SUBID_START-$((SUBID_START + 65535))" \
                                --add-subgids "$SUBID_START-$((SUBID_START + 65535))" "$SANDBOX_USER"
  done
  if [ ! -e "/var/lib/systemd/linger/$SANDBOX_USER" ]; then
    note "linger disabled for $SANDBOX_USER (tmux/podman would die at logout)"
    [ "$CHECK" = 1 ] || loginctl enable-linger "$SANDBOX_USER"
  fi
fi

# --- config files
for dest in $(printf '%s\n' "${!MODES[@]}" | sort); do
  mode=${MODES[$dest]} src="$STAGE/$dest" dst="/$dest"
  lmode=$(stat -c %a "$dst" 2>/dev/null || echo missing)
  cmp -s "$src" "$dst" && [ "$lmode" = "$mode" ] && continue
  note "=== $dst"
  cmp -s "$src" "$dst" || diff -u --label live --label repo <(cat "$dst" 2>/dev/null || true) "$src" || true
  [ "$lmode" = "$mode" ] || echo "mode: live $lmode, repo $mode"
  [ "$CHECK" = 1 ] && continue

  case "$dest" in
    etc/sudoers.d/*)
      visudo -cf "$src" >/dev/null || die "$dest fails visudo -c; not installed" ;;
  esac
  backup=""
  [ -e "$dst" ] && { backup=$(mktemp); cp -p "$dst" "$backup"; }
  install -D -o root -g root -m "$mode" "$src" "$dst"
  case "$dest" in
    etc/ssh/*)
      if ! sshd -t; then
        echo "ERROR: sshd -t failed; restoring previous $dst"
        if [ -n "$backup" ]; then cp -p "$backup" "$dst"; else rm -f "$dst"; fi
        exit 1
      fi ;;
  esac
  [ -n "$backup" ] && rm -f "$backup"
  changed+=("$dest"); echo "installed $dst"
done

# --- laptop used as a server: never suspend
if [ "$LAPTOP_SERVER" = 1 ]; then
  for t in "${SLEEP_TARGETS[@]}"; do
    [ "$(systemctl is-enabled "$t" 2>/dev/null || true)" = masked ] && continue
    note "$t not masked"
    [ "$CHECK" = 1 ] || systemctl mask "$t"
  done
fi

# --- follow-ups for changed files
for dest in "${changed[@]}"; do
  case "$dest" in
    etc/ssh/*) systemctl reload ssh && echo "reloaded ssh" ;;
    etc/modules-load.d/*)
      grep -vE '^\s*(#|$)' "/$dest" | while read -r m; do modprobe "$m" || echo "WARN: modprobe $m failed"; done ;;
    etc/systemd/logind.conf.d/*)
      echo "NOTE: logind change takes effect after 'systemctl restart systemd-logind' or a reboot" ;;
  esac
done

# --- report
echo "=== state"
sshd -t && echo "sshd config: OK"
visudo -c >/dev/null && echo "sudoers: OK"
if [ "$LAPTOP_SERVER" = 1 ]; then
  for t in "${SLEEP_TARGETS[@]}"; do echo "$t: $(systemctl is-enabled "$t" 2>/dev/null || true)"; done
fi
echo "linger $SANDBOX_USER: $([ -e "/var/lib/systemd/linger/$SANDBOX_USER" ] && echo yes || echo no)"
for m in $(grep -vE '^\s*(#|$)' "$STAGE/etc/modules-load.d/claude-sandbox.conf"); do
  printf '%s: %s\n' "$m" "$(lsmod | awk -v m="$m" '$1==m{f=1} END{print f?"loaded":"not loaded (may be built in)"}')"
done

if [ "$CHECK" = 1 ]; then
  [ "$drift" = 0 ] && echo "host: live matches repo" || { echo "host: DRIFT (see above)"; exit 1; }
else
  echo "host: done"
fi
