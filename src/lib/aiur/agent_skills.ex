defmodule Aiur.AgentSkills do
  @moduledoc """
  Installs aiur's bundled agent-operating skills into each issue-worker
  workspace.

  The per-turn agent prompt (`shared-agent-instructions.md`) routes every agent
  to the `using-aiur` operating manual and the `/aiur-agent` cross-ticket event
  skill. Those skills ship in aiur's own tree under `.claude/skills/`, but an
  agent's workspace is a checkout of the *target* repo, which has no copy — so
  without this, agents on non-aiur repos full-disk `find /` for a skill the
  prompt tells them to load (#689).

  The skill files are embedded at COMPILE time (via `@external_resource` +
  `File.read!`, the same way `Aiur.Init` embeds its config/prompt examples) so
  they survive into a shipped OTP release — which ships only compiled BEAM and
  `priv/`, not the repo's `.claude` tree. (A runtime `__DIR__`-relative read
  would resolve to the build machine's source path and silently no-op once the
  release is relocated, which is exactly the deployment this fixes.) After a
  workspace is populated (warm-base materialize or cold clone), the embedded
  files are written into `<workspace>/.claude/skills/`, and the repo's Codex
  convention is mirrored with `.codex/skills/<skill>` symlinks back to the
  canonical `.claude` copy.

  Installs are idempotent and never clobber a skill the target repo already
  ships (e.g. aiur dogfooding aiur), best-effort so a file error never fails
  workspace creation, and atomic per skill so an interrupted write never leaves
  a half-installed skill the presence check would then accept as complete.
  """

  require Logger

  # The skills the agent prompt routes issue workers to. This is a deliberate
  # subset of the canonical taxonomy in `Aiur.AiurAgentSkillTest`
  # (`@codex_exposed_aiur_skills` / `@claude_operator_only_skills`): operator
  # skills (aiur-run, aiur-monitor, aiur-loop, release) are excluded because an
  # issue worker has no reason to run aiur itself. That test cross-checks this
  # subset, so the two cannot silently drift.
  @issue_worker_skills ~w(using-aiur aiur-agent design-import)

  @claude_skills_dir ".claude/skills"
  @codex_skills_dir ".codex/skills"

  # src/lib/aiur -> src/lib -> src -> repo root, then `.claude/skills`. Used at
  # compile time only; nothing reads the source tree at runtime.
  @skills_root Path.expand("../../../#{@claude_skills_dir}", __DIR__)

  # Every file under the bundled skills, read at compile time and keyed by its
  # path relative to the skills root (e.g. "using-aiur/SKILL.md").
  bundled_paths =
    @issue_worker_skills
    |> Enum.flat_map(fn skill ->
      [Path.join([@skills_root, skill, "*"]), Path.join([@skills_root, skill, "**", "*"])]
    end)
    |> Enum.flat_map(&Path.wildcard(&1, match_dot: true))
    |> Enum.uniq()
    |> Enum.filter(&File.regular?/1)

  for path <- bundled_paths, do: @external_resource(path)

  @bundled_files for path <- bundled_paths, do: {Path.relative_to(path, @skills_root), File.read!(path)}

  @doc "The skills installed into every issue-worker workspace."
  @spec issue_worker_skills() :: [String.t()]
  def issue_worker_skills, do: @issue_worker_skills

  @doc """
  Install the bundled issue-worker skills into `workspace`.

  Best-effort and idempotent: a `nil` workspace is a no-op and a failed file
  operation never raises into the caller's workspace-creation path.
  """
  @spec install(Path.t() | nil) :: :ok
  def install(workspace) when is_binary(workspace) do
    Enum.each(@issue_worker_skills, &install_skill(workspace, &1))
  rescue
    error in [ArgumentError, ErlangError, File.Error] ->
      Logger.warning("agent skill install failed workspace=#{workspace} error=#{Exception.message(error)}")
      :ok
  end

  def install(_workspace), do: :ok

  defp install_skill(workspace, skill) do
    install_claude_skill(workspace, skill)
    link_codex_skill(workspace, skill)
  end

  # Write the embedded skill files into the workspace unless the target repo
  # already ships its own copy (don't clobber a repo's tuned skill).
  defp install_claude_skill(workspace, skill) do
    dest = Path.join([workspace, @claude_skills_dir, skill])

    unless exists?(dest) do
      File.mkdir_p!(Path.dirname(dest))
      stage_and_rename(dest, skill_files(skill))
    end
  end

  # Stage the files in a sibling temp dir and rename into place (atomic within
  # the same parent). An interrupted write then leaves only an abandoned temp
  # dir — cleaned up here — never a half-populated `dest` the `exists?/1` guard
  # would accept as a complete skill on the next dispatch.
  defp stage_and_rename(dest, files) do
    tmp = dest <> ".tmp." <> Integer.to_string(System.unique_integer([:positive]))

    try do
      Enum.each(files, fn {rel, content} ->
        target = Path.join(tmp, rel)
        File.mkdir_p!(Path.dirname(target))
        File.write!(target, content)
      end)

      File.rename!(tmp, dest)
    after
      File.rm_rf(tmp)
    end
  end

  # The embedded files for `skill`, re-keyed by their path relative to the skill
  # dir (e.g. "using-aiur/SKILL.md" -> "SKILL.md").
  defp skill_files(skill) do
    prefix = skill <> "/"

    for {rel, content} <- @bundled_files, String.starts_with?(rel, prefix) do
      {Path.relative_to(rel, skill), content}
    end
  end

  # Codex discovers skills under `.codex/skills/`; each entry is a relative
  # symlink back to the canonical `.claude` copy (the same shape committed in
  # aiur's own tree), so Codex agents resolve the skill with no second copy.
  defp link_codex_skill(workspace, skill) do
    dest = Path.join([workspace, @codex_skills_dir, skill])

    unless exists?(dest) do
      File.mkdir_p!(Path.dirname(dest))
      File.ln_s!(Path.join("../../.claude/skills", skill), dest)
    end
  end

  # `File.exists?/1` follows symlinks, so a dangling Codex link would read as
  # absent and then fail the `ln_s!`. `lstat` detects the node itself.
  defp exists?(path), do: match?({:ok, _}, File.lstat(path))
end
