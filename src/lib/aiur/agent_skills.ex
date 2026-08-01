defmodule Aiur.AgentSkills do
  @moduledoc """
  Installs aiur's bundled agent-operating skills into each issue-worker
  workspace.

  The per-turn agent prompt (`shared-agent-instructions.md`) routes every agent
  to the `using-aiur` operating manual and the `/aiur-agent` cross-ticket event
  skill, while `/aiur-debug` is the shared diagnosis overlay available when a
  run or ticket fails. Those skills ship in aiur's own tree under
  `.claude/skills/`, but an agent's workspace is a checkout of the *target*
  repo, which has no copy — so
  without this, agents on non-aiur repos full-disk `find /` for a skill the
  prompt tells them to load (#689).

  The skill files are embedded at COMPILE time (via `@external_resource` +
  `File.read!`, the same way `Aiur.Init` embeds its config/prompt examples) so
  they survive into a shipped OTP release — which ships only compiled BEAM and
  `priv/`, not the repo's `.claude` tree. (A runtime `__DIR__`-relative read
  would resolve to the build machine's source path and silently no-op once the
  release is relocated, which is exactly the deployment this fixes.) After a
  workspace is populated (warm-base materialize or cold clone), the embedded
  files are written into registry-declared workspace skill paths. The shipped
  Claude and Codex entries retain the `.claude/skills/` canonical copy and
  `.codex/skills/<skill>` symlink convention.

  Installs are idempotent and never clobber a skill the target repo already
  ships (e.g. aiur dogfooding aiur), best-effort so a file error never fails
  workspace creation, and atomic per skill so an interrupted write never leaves
  a half-installed skill the presence check would then accept as complete.
  """

  require Logger

  alias Aiur.{CodingAgent, Workspace.Remote}

  # The skills the agent prompt routes issue workers to. This is a deliberate
  # subset of the canonical taxonomy in `Aiur.AiurAgentSkillTest`
  # (`@codex_exposed_aiur_skills` / `@claude_executor_only_skills`): Executor
  # skills (aiur-build, aiur-run, aiur-monitor, release) are excluded because an
  # issue worker has no reason to run aiur itself. That test cross-checks this
  # subset, so the two cannot silently drift.
  @issue_worker_skills ~w(using-aiur aiur-agent aiur-debug design-import)

  # The bundled source tree is the release build input. Backend workspace paths
  # are supplied by `CodingAgent.skill_install_locations/0` below.
  @bundled_skills_dir ".claude/skills"

  # src/lib/aiur -> src/lib -> src -> repo root, then `.claude/skills`. Used at
  # compile time only; nothing reads the source tree at runtime.
  @skills_root Path.expand("../../../#{@bundled_skills_dir}", __DIR__)

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

  @doc false
  @spec remote_install_script(Path.t()) :: String.t()
  def remote_install_script(workspace) when is_binary(workspace) do
    [
      "set -eu",
      Remote.remote_shell_assign("workspace", workspace),
      Enum.map_join(@issue_worker_skills, "\n", &remote_skill_script/1)
    ]
    |> Enum.join("\n")
  end

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

  defp install_skill(workspace, skill),
    do: Enum.each(CodingAgent.skill_install_locations(), &install_skill_at(workspace, skill, &1))

  defp remote_skill_script(skill) do
    files = skill_files(skill)

    writes =
      Enum.map_join(files, "\n", fn {relative_path, content} ->
        encoded = Base.encode64(content)
        relative_dir = Path.dirname(relative_path)

        [
          if(relative_dir == ".", do: nil, else: "mkdir -p \"$tmp/#{relative_dir}\""),
          "printf '%s' '#{encoded}' | base64 -d > \"$tmp/#{relative_path}\""
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")
      end)

    CodingAgent.skill_install_locations()
    |> Enum.map(&remote_skill_script(&1, skill, writes))
    |> Enum.join("\n")
  end

  defp remote_skill_script(%{path: path} = location, skill, writes) do
    dest = "$workspace/#{path}/#{skill}"

    case Map.get(location, :link_to) do
      nil ->
        [
          "dest=\"#{dest}\"",
          "if [ ! -e \"$dest\" ] && [ ! -L \"$dest\" ]; then",
          "  mkdir -p \"$(dirname \"$dest\")\"",
          "  tmp=\"$dest.tmp.$$\"",
          "  rm -rf \"$tmp\"",
          "  trap 'rm -rf \"$tmp\"' EXIT",
          "  mkdir -p \"$tmp\"",
          indent_script(writes, "  "),
          "  mv \"$tmp\" \"$dest\"",
          "  trap - EXIT",
          "fi"
        ]
        |> Enum.join("\n")

      link_to ->
        target = relative_link_target(path, link_to, skill)

        [
          "link=\"#{dest}\"",
          "if [ ! -e \"$link\" ] && [ ! -L \"$link\" ]; then",
          "  mkdir -p \"$(dirname \"$link\")\"",
          "  ln -s \"#{target}\" \"$link\"",
          "fi"
        ]
        |> Enum.join("\n")
    end
  end

  defp indent_script(script, prefix) do
    script
    |> String.split("\n")
    |> Enum.map_join("\n", &(prefix <> &1))
  end

  # Write the embedded skill files into a registry-declared workspace location
  # unless the target repo already ships its own copy.
  defp install_skill_at(workspace, skill, %{path: path} = location) do
    dest = Path.join([workspace, path, skill])

    case Map.get(location, :link_to) do
      nil -> install_embedded_skill(dest, skill)
      link_to -> link_skill(dest, relative_link_target(path, link_to, skill))
    end
  end

  defp install_embedded_skill(dest, skill) do
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

  # Linked backend locations share the canonical installed skill without a
  # duplicate copy. The registry owns both paths.
  defp link_skill(dest, target) do
    unless exists?(dest) do
      File.mkdir_p!(Path.dirname(dest))
      File.ln_s!(target, dest)
    end
  end

  defp relative_link_target(path, link_to, skill) do
    parents = path |> Path.split() |> Enum.reject(&(&1 == "."))
    Path.join(List.duplicate("..", length(parents)) ++ [link_to, skill])
  end

  # `File.exists?/1` follows symlinks, so a dangling Codex link would read as
  # absent and then fail the `ln_s!`. `lstat` detects the node itself.
  defp exists?(path), do: match?({:ok, _}, File.lstat(path))
end
