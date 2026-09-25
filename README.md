# claude-devbox

Run [Claude Code](https://code.claude.com) on an always-on Linux box and drive it from anywhere with
**Remote Control** (claude.ai/code or the mobile app). It can work semi-unsupervised because a mistake, or a
prompt-injected instruction, can only reach a small, well-defined part of the machine.

Each session runs as an unprivileged user, inside a rootless container. Outbound traffic is default-deny with a
DNS-name allowlist, and Claude Code's own bubblewrap sandbox runs inside that. Everything is installed and
drift-checked by two idempotent scripts, so this repo is the source of truth for the machine.

Built and used on Ubuntu 24.04 (a spare laptop running lid-closed as an SSH-only server). Other systemd distros
with rootless podman should work with small changes.

## Layers

From the outside in:

1. **Unprivileged sandbox user** (`SANDBOX_USER`, default `dev`).
   - Not in `sudo`, `docker` or any other privileged group. `install-host.sh` warns if it is.
   - Your own login (`ADMIN_USER`) can act as it without a password, via `host/etc/sudoers.d/`. The reverse is
     not possible.
   - Optional SSH hardening: key-only login, no root, and only these two users allowed.
2. **Rootless podman container** (`dev/sandbox/Containerfile`).
   - The only host paths it sees are the project (`/workspace`) and a few persistent dirs under
     `~SANDBOX_USER/sandbox/`: Claude's config, shell history, `gh` login, build caches and Bitbucket tokens.
3. **Egress firewall inside the container** (`dev/sandbox/init-firewall.sh`):
   - Outbound traffic is default-deny.
   - A local dnsmasq is the only resolver. For every allowlisted name, it adds the IPs it returns to an ipset.
     iptables allows only that set, so CDN IP rotation doesn't break anything.
   - Only dnsmasq may reach upstream DNS, which blocks DNS tunnelling.
   - IPv6 is dropped entirely and the LAN is unreachable.
   - It runs a self-test on every start. `entrypoint.sh` then drops `NET_ADMIN`/`NET_RAW` before starting your
     command, so nothing inside can undo the rules.
4. **Claude Code's own sandbox** (`dev/sandbox/claude-home/settings.json` → `sandbox.*`).
   - Bash commands run in bubblewrap with a second, strict domain allowlist, limited write paths, and Claude's
     own credentials file unreadable.
   - Unsandboxed commands are disabled.

`claude-dev up` starts a Remote Control server with `--permission-mode acceptEdits --spawn=worktree --sandbox`.
File edits are auto-accepted, anything else still asks, and each remote session gets its own git worktree.

## Threat model and known limitations

Read this before relying on it. **What it protects against:** a Claude session (or something that
prompt-injected it) doing damage outside its project, including:
- reading your other files, SSH keys or other credentials
- touching the host or LAN
- installing persistent software on the host
- sending data to arbitrary servers

**What it does not protect against:**
- **Exfiltration through allowlisted services.** github.com, npm, PyPI and friends accept uploads, and the sandbox
  can push to any repo its token allows. Use fine-grained, single-repo tokens, and add domains sparingly.
- **The sandbox's own credentials.** The sandboxed Claude can read its GitHub token (`gh-config`) and Bitbucket
  tokens. That's inherent, since it needs them to push. Scope them to the repos you run in the sandbox.
- **Your claude.ai account.** Remote Control means anyone who controls your claude.ai account can run code in
  the sandbox. Protect that account accordingly.
- **Damage inside the project.** With `acceptEdits`, Claude edits the mounted project directly (in worktrees). Keep
  it under version control and review before merging.
- **Container escapes and kernel bugs.** Rootless podman plus an unprivileged user limit the blast radius, but
  this is not a VM.
- **The admin user.** `ADMIN_USER` can become the sandbox user without a password, so protect the admin account.
  The reverse is not possible.
- **DNS tunnelling on some hosts.** The DNS restriction needs the host's `xt_owner` kernel module, which
  `install-host.sh` loads at boot. Without it, the firewall still works but upstream DNS is open to all
  processes, and the self-test log says so.

## Quick start

```bash
git clone https://github.com/craigalodon/claude-devbox && cd claude-devbox
cp devbox.conf.example devbox.conf && $EDITOR devbox.conf     # users, git identity, options
ln -s ../../scripts/check-secrets.sh .git/hooks/pre-commit    # if you'll commit to your copy

sudo ./install-host.sh --check    # see what would change
sudo ./install-host.sh            # packages, sandbox user, sudoers, sshd, modules
./install-dev.sh                  # deploy the sandbox user's files and build the image

cd / && sudo -u dev -H ~dev/.local/bin/claude-dev login       # one-time claude.ai login
cd / && sudo -u dev -H ~dev/.local/bin/claude-dev up /home/dev/myproject
```

The session appears at claude.ai/code within a few seconds. The first `up` for a project asks you to accept
the workspace trust dialog once.

## Commands

`claude-dev` runs as the sandbox user:

```bash
claude-dev build                       # (re)build the image
claude-dev login                       # one-time claude.ai login
claude-dev up <project-dir> [name]     # Remote Control session in a tmux session
claude-dev shell <project-dir>         # interactive shell in the sandbox
claude-dev ls | attach <name> | down <name>
```

From your admin login: `cd /` first (the sandbox user can't enter your home), then `sudo -u dev -H …`.
`CLAUDE_DEV_MODE` and `CLAUDE_DEV_SPAWN` override the permission mode and spawn mode for `up`.

## Configuration

| Where | What |
|---|---|
| `devbox.conf` | Per-machine settings (gitignored). See `devbox.conf.example`. |
| `local/` | Optional per-machine extras (gitignored): a settings overlay, CLAUDE.md additions, extra forbidden strings. See `local/README.md`. |
| `dev/` | Deployed to the sandbox user's home by `install-dev.sh`. `@VAR@` placeholders come from `devbox.conf`. |
| `host/` | Deployed to `/` by `install-host.sh`, including file names such as `sudoers.d/@ADMIN_USER@-as-@SANDBOX_USER@`. |

These live only on the box and are **never** in the repo. `.gitignore` and `scripts/check-secrets.sh` guard
against it:

| Path under `~SANDBOX_USER/sandbox/` | What it holds |
|---|---|
| `bb-credentials/credentials` | Bitbucket repo tokens |
| `gh-config/` | the `gh` login |
| `claude-home/.credentials.json` | the claude.ai login |
| `claude-home/.claude.json` | Claude Code state |
| `history/`, `cache/`, `uv-share/`, `go/` | shell history and persistent caches |

## Changing things

Edit the repo (or `devbox.conf` / `local/`), then deploy:

```bash
./install-dev.sh --check && ./install-dev.sh      # rebuilds the image when its inputs change
sudo ./install-host.sh --check && sudo ./install-host.sh
```

- **`--check` exits 1 on drift.** Use it to spot changes made in place. For example, Claude Code rewrites its
  `settings.json` when you use `/plugin` or `/config`. Port such changes into the repo or `local/claude-settings.json`.
- **`--render <dir>`** writes the rendered files to `<dir>` without touching anything live.
- **`install-host.sh` checks before it installs.** Sudoers must pass `visudo -c` before it's installed. The sshd
  config is rolled back if `sshd -t` fails, so a bad edit can't lock you out.
- **Running sandboxes pick up changes only on restart:** `claude-dev down <name>`, then `claude-dev up …`.

### Allowing a new domain

A domain must be allowed in **both** layers:
- the image firewall: `ALLOW_DOMAINS` in `dev/sandbox/init-firewall.sh`, or `EXTRA_DOMAINS` in `devbox.conf`
- Claude's sandbox: `sandbox.network.allowedDomains` in `settings.json`, or in `local/claude-settings.json`

Then run `./install-dev.sh`, which rebuilds the image.

## Git hosting from the sandbox

### GitHub

Run `gh auth login` inside `claude-dev shell` with a **fine-grained PAT** limited to the repos you'll work on.
The login persists in `gh-config/`, and git uses `gh auth git-credential`. Clone over HTTPS.

Deploy keys don't fit this setup: GitHub lets a given deploy key be used on only one repo.

### Bitbucket

Bitbucket has no `gh`. This setup uses per-repo **repository access tokens** and a small REST helper, `bb`.

1. **Create the token** in the repo under Repository settings → Security → **Access tokens**. Give it
   Repositories Read+Write, plus Pull requests Read+Write if you want PRs.
   - Repository access tokens start with `ATCTT3`.
   - Atlassian account API tokens (starting `ATATT3`) won't work with this setup.
2. **Add one line per repo** to `~SANDBOX_USER/sandbox/bb-credentials/credentials` (mode 600):
   ```
   https://x-token-auth:<TOKEN>@bitbucket.org/<workspace>/<repo>.git
   ```
   `useHttpPath` is on, so the path must match the clone URL exactly. That means the workspace **ID**, not its
   display name, and the same `.git` suffix. Watch for pasted trailing characters or CRLF.
   `sed 's/:[^:@]*@/:***@/' file | cat -A` shows the line without revealing the token.
3. **Clone from the host.** The gitconfig's helper points at the in-container path, so give it a get-only helper
   for the host path:
   ```bash
   cd / && sudo -u dev -H git \
     -c 'credential.https://bitbucket.org.helper=' \
     -c 'credential.https://bitbucket.org.helper=!f() { test "$1" = get && git credential-store --file ~dev/sandbox/bb-credentials/credentials get; }; f' \
     clone https://bitbucket.org/<workspace>/<repo>.git ~dev/<repo>
   ```
   **Never use plain `store` here.** On an auth failure, git tells the helper to *erase* the credential, and
   plain `store` deletes your token line.
4. **Inside the sandbox**, git push/pull just works, and `bb` stands in for `gh`: `bb GET pullrequests`,
   `bb POST pullrequests '{…}'`. Run it with no arguments for examples.

Test a token without printing it. `200` works, `401` means a bad token, `403` a missing scope, and `404` a wrong
workspace/repo or a token made for another repo:

```bash
cd / && sudo -u dev bash -c 'tok=$(sed -E "s|.*x-token-auth:([^@]+)@.*|\1|" ~/sandbox/bb-credentials/credentials); curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $tok" https://api.bitbucket.org/2.0/repositories/<workspace>/<repo>'
```

## Gotchas

- **bubblewrap refuses to start in a process that holds unexpected capabilities.** That's why `entrypoint.sh`
  drops them after the firewall is up, and why `enableWeakerNestedSandbox` is on.
- **`http.proxyAuthMethod=basic` is set in the sandbox's gitconfig on purpose.** pre-commit scrubs the
  `GIT_CONFIG_PARAMETERS` that Claude's sandbox uses to set it, and git through the sandbox proxy then fails.
- **`UV_TOOL_DIR` is set only while building.** If it leaked into the runtime environment, `uvx` would point at
  the read-only system tool dir.
- **Resolving the allowlist once at startup doesn't work.** CDN-hosted names (Fastly, Cloudflare) rotate IPs
  within minutes, hence the live dnsmasq → ipset feed.
- **`can't raise ambient capability …` warnings during `podman build` are harmless** under rootless podman.
- **GitHub rejects pushes of commits that carry a private email address** if you've enabled email privacy. Use
  your `…@users.noreply.github.com` address as `GIT_EMAIL`.

## Contributing

`scripts/check-secrets.sh`, used as the pre-commit hook, refuses:
- token-shaped strings
- credential paths
- anything listed in your `local/forbidden-strings`

Issues and PRs are welcome.

## Credits

The sandbox approach was inspired by the [devcontainer](https://github.com/anthropics/claude-code/tree/main/.devcontainer)
in Anthropic's Claude Code repository. This repo's files were written independently. Licensed under MIT, see
`LICENSE`.
