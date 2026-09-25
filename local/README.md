# local/

Per-machine extras. Everything in this directory except this README is gitignored. All files are optional.

| File | Effect |
|---|---|
| `claude-settings.json` | Deep-merged over `dev/sandbox/claude-home/settings.json`. Objects merge, arrays are appended without duplicates, and other values override. Use it for plugins, marketplaces, theme, and extra `allowedDomains`. |
| `CLAUDE.md` | Appended to `dev/sandbox/claude-home/CLAUDE.md`. |
| `forbidden-strings` | One string per line (case-insensitive). `scripts/check-secrets.sh` refuses to commit any file containing one. Use it for your real email, host names, internal domains and so on. |

To allow a new domain for one machine only, add it to both `allowedDomains` in `claude-settings.json` and
`EXTRA_DOMAINS` in `devbox.conf`. `EXTRA_DOMAINS` is baked into the image firewall at build time.
