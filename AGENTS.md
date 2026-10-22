# Coding style guidelines

Before writing, modifying, or reviewing code, read and follow
[.claude/skills/code-review/coding-style.md](.claude/skills/code-review/coding-style.md).

# Upstream sync

When asked to 「更新到上游」/「同步上游」/「把 my-deploy 更到最新」, follow
[.claude/skills/upstream-sync/SKILL.md](.claude/skills/upstream-sync/SKILL.md)
instead of improvising. Key invariants: `main` only ever fast-forwards to
`upstream/main`; `my-deploy` is always `main` plus exactly one squashed commit;
`squash merge` must precede `reset --soft main`.
