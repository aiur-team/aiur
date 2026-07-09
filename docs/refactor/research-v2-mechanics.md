# Decision-16 verification: aiur mechanics against a v2 base branch (2026-07-06)

Verified against code:
1. CI (.github/workflows/ci.yml): `on: pull_request` has NO branch filter → PRs targeting v2 run the full 4-job gate. `on: push` is main-only → v2 post-merge state not re-verified. FIX: Phase-1 gate ticket adds `v2` to push branches (one line).
2. tracker.base_branch config option EXISTS (src/lib/aiur/config/schema.ex:89, cast at :101). Consumers:
   - orchestrator.ex:846 default_branch_name() → maybe_notify_agents_on_default_branch_push (post-#720 notify) — config-driven, default "main".
   - events/universal_subscriptions.ex:22-35 → system.<base>.branch.push auto-subscription — config-driven, default "main".
   → For the refactor run: set tracker.base_branch: "v2" in .aiur/config. Notify + subscriptions follow.
3. GAP: src/lib/aiur/repo_base.ex:28 hardcodes @default_branch "main" — clone --branch main (:248), fetch origin main (:258), rev-parse origin/main (:260), reset --hard origin/main (:270), ls-remote refs/heads/main (:359). RepoBase does NOT read tracker.base_branch → workspaces + warm base would cut from main.
   → MANDATORY pre-ticket: RepoBase (and any prewarm path using it) respects tracker.base_branch. Small, behavior-preserving when base_branch=main (default unchanged).
4. Blocker-branch push detection (LsRemoteTicker refs/heads/aiur/<digits>) is branch-name-based, base-agnostic — no change.
5. Website: Netlify deploys from main only → website changes merged to v2 stay staged until final v2→main merge (desirable). Website CI job pre-ticket still needed for PR-time verification.

Ticket implications:
- Pre-ticket A (Phase 1): RepoBase base-branch config support + set tracker.base_branch v2 + CI push branches += v2. Verification: workspace clone/fetch/reset target v2; notify fires on v2 push.
- Operator setup step (00-overview): create v2 from main before opening any issues; set tracker.base_branch in the refactor run's .aiur/config.
- GitHub PR creation: executor dev-loop opens PRs with base v2 — check where `gh pr create` base is set (dev-loop skill / push skill) → ticket boilerplate states `--base v2`; verify default-branch assumption in .codex/skills/push and using-aiur/dev-loop.md at U10 authoring time.
