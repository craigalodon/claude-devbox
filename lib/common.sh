# shellcheck shell=bash
# lib/common.sh — shared by install-dev.sh and install-host.sh (sourced, not executed).
#
# Per-machine values live in devbox.conf (gitignored; copy devbox.conf.example). Repo files may contain
# @VAR@ placeholders for those values, in their contents and in their file names; render() fills them in.
# Optional per-machine extras live in local/ (gitignored), see local/README.md.

die() { echo "error: $*" >&2; exit 1; }

# Variables that may appear as @VAR@ in repo files.
TEMPLATE_VARS=(ADMIN_USER SANDBOX_USER GIT_NAME GIT_EMAIL)

load_conf() {
  local conf="$REPO/devbox.conf"
  [ -f "$conf" ] || die "no devbox.conf — copy devbox.conf.example to devbox.conf and edit it"
  # shellcheck source=/dev/null
  . "$conf"
  : "${SANDBOX_USER:=dev}" "${SUBID_START:=165536}" "${LAPTOP_SERVER:=0}" "${SSH_HARDENING:=1}"
  local v
  for v in ADMIN_USER SANDBOX_USER; do
    [[ "${!v:-}" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "devbox.conf: $v must be a valid user name (got '${!v:-}')"
  done
  [ "$ADMIN_USER" != "$SANDBOX_USER" ] || die "devbox.conf: ADMIN_USER and SANDBOX_USER must differ"
  [ -n "${GIT_NAME:-}" ] && [ -n "${GIT_EMAIL:-}" ] || die "devbox.conf: set GIT_NAME and GIT_EMAIL"
  [[ "$SUBID_START" =~ ^[0-9]+$ ]] || die "devbox.conf: SUBID_START must be a number"
}

# render <src> <dest>: copy a repo file, substituting @VAR@ placeholders. Fails on unknown placeholders.
render() {
  local src="$1" dest="$2" v expr=()
  for v in "${TEMPLATE_VARS[@]}"; do
    local val=${!v}
    val=${val//\\/\\\\}; val=${val//|/\\|}; val=${val//&/\\&}
    expr+=(-e "s|@$v@|$val|g")
  done
  mkdir -p "$(dirname "$dest")"
  sed "${expr[@]}" "$src" > "$dest"
  if grep -qE '@[A-Z_]+@' "$dest"; then
    die "unrendered placeholder in $src: $(grep -oE '@[A-Z_]+@' "$dest" | sort -u | tr '\n' ' ')"
  fi
}

# render_name <relative path>: substitute placeholders in a path.
render_name() {
  local p="$1" v
  for v in ADMIN_USER SANDBOX_USER; do p=${p//@$v@/${!v}}; done
  echo "$p"
}

# merge_json <base> <overlay> <dest>: deep merge; objects merge recursively, arrays are concatenated
# without duplicates, anything else in the overlay wins.
merge_json() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
base, overlay, dest = sys.argv[1:]

def merge(a, b):
    if isinstance(a, dict) and isinstance(b, dict):
        out = dict(a)
        for k, v in b.items():
            out[k] = merge(a[k], v) if k in a else v
        return out
    if isinstance(a, list) and isinstance(b, list):
        return a + [x for x in b if x not in a]
    return b

with open(base) as f:
    result = json.load(f)
try:
    with open(overlay) as f:
        result = merge(result, json.load(f))
except FileNotFoundError:
    pass
with open(dest, "w") as f:
    json.dump(result, f, indent=2)
    f.write("\n")
PY
}
