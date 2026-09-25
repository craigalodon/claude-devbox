# Sandbox notes

- GitHub repos: use `gh` as usual.
- Bitbucket repos (origin on bitbucket.org): there is no `gh`. Use `bb <METHOD> <path> [json]` for
  pull requests and other REST calls against the current repo; run `bb` with no args for examples.
  git push/pull over HTTPS authenticates automatically with a per-repo access token.
