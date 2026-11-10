# Repository posture

This fork is deployment-only. We never push, PR, or contribute anything upstream; `upstream` is read-only. Upstream's contributor-facing requirements (coding style, log language, typing rules, CI/pre-commit, test and docs conventions) do not apply to deployment adaptations here — the only bar is that the deployment works, behaves correctly, and stays traceable. All local work lives on `my-deploy`; `main` is a pure upstream mirror. `docs/` belongs entirely to upstream: we neither maintain nor read it. The human-readable sync runbook is [UPSTREAM_SYNC.md](UPSTREAM_SYNC.md) at the repo root, never under `docs/`.

# Coding style guidelines

[.claude/skills/code-review/coding-style.md](.claude/skills/code-review/coding-style.md) is upstream-contributor reference material, not a binding rule for deployment-layer changes. Consult it for general readability only; ignore its upstream-contribution requirements.

# Upstream sync

When asked to 「更新到上游」/「同步上游」/「把 my-deploy 更到最新」, follow
[.claude/skills/upstream-sync/SKILL.md](.claude/skills/upstream-sync/SKILL.md)
instead of improvising. Human-readable runbook: [UPSTREAM_SYNC.md](UPSTREAM_SYNC.md).
Key invariants: `main` only ever fast-forwards to `upstream/main`; `my-deploy` is
always `main` plus exactly one squashed commit; `squash merge` must precede
`reset --soft main`; optional step 0 may squash our own commits against the old
`main` **before** `main` fast-forwards. Never push to `upstream`.
