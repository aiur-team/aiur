defmodule Aiur.Init.Prewarm do
  @moduledoc """
  Warm-base opt-in flow for `aiur init`.

  This module owns detection prompts, fallback and ambiguity disclosure,
  first-build execution, resume verification, the `prewarm:` YAML block, and the
  sibling `.aiur/prewarm` script wrapper.
  """

  alias Aiur.Init.{Format, Prewarm.Failure}

  @prewarm_file_name "prewarm"

  @doc false
  @spec prompt_prewarm(Aiur.Init.io(), Aiur.Init.deps(), atom()) :: %{enabled: boolean(), base_build: String.t() | nil}
  def prompt_prewarm(_io, _deps, :global), do: %{enabled: false, base_build: nil}

  def prompt_prewarm(io, deps, _location) do
    if io.confirm.("Keep a pre-warmed copy of the configured base branch so agents skip cloning + building?", true) do
      resolve_prewarm(io, deps)
    else
      %{enabled: false, base_build: nil}
    end
  end

  @doc false
  @spec resolve_prewarm(Aiur.Init.io(), Aiur.Init.deps()) :: %{enabled: boolean(), base_build: String.t() | nil}
  def resolve_prewarm(io, deps) do
    case deps.detect_toolchain.() do
      {:ok, %{language: lang, build_root: root, command: command}} ->
        io.puts.([
          "\nDetected ",
          to_string(lang),
          " (build root ",
          Format.dim(root),
          "). Base build:\n  ",
          Format.dim(command),
          "\n"
        ])

        case io.select.("Use this base build command?", ["use", "edit", "skip"], "use") do
          "use" -> %{enabled: true, base_build: command}
          "edit" -> %{enabled: true, base_build: io.input.("Base build command", command, nil)}
          _ -> %{enabled: false, base_build: nil}
        end

      {:ambiguous, candidates} ->
        print_prewarm_ambiguous(io, candidates)
        %{enabled: false, base_build: nil}

      :none ->
        print_prewarm_fallback(io)
        %{enabled: false, base_build: nil}
    end
  end

  @doc false
  @spec print_prewarm_fallback(Aiur.Init.io()) :: :ok
  def print_prewarm_fallback(io) do
    io.puts.([
      "\nCouldn't auto-detect this repo's build — pre-warm left off. To enable it, paste this to your coding agent:\n\n",
      Format.dim(prewarm_fallback_prompt())
    ])
  end

  @doc false
  @spec print_prewarm_ambiguous(Aiur.Init.io(), [map()]) :: :ok
  def print_prewarm_ambiguous(io, candidates) do
    roots =
      Enum.map_join(candidates, "\n", fn %{language: lang, build_root: root} ->
        "  • #{lang} (#{root})"
      end)

    io.puts.([
      "\nFound multiple build roots — pre-warm builds one base, so it needs a single command:\n",
      Format.dim(roots),
      "\n\nLeaving pre-warm off. To enable it, pick one (or describe the combined build) and paste this to your coding agent:\n\n",
      Format.dim(prewarm_fallback_prompt())
    ])
  end

  @doc false
  @spec prewarm_fallback_prompt() :: String.t()
  def prewarm_fallback_prompt do
    """
    You are working in a repository managed by aiur, an agent-orchestration
    runtime. aiur runs coding agents in isolated workspaces. To avoid every
    agent cold-cloning, installing dependencies, and compiling at the same time,
    aiur can keep one shared, pre-installed checkout of this repo's configured base branch
    called the warm base. Agent workspaces are materialized from that base with
    copy-on-write, so they inherit dependency caches and build artifacts.

    Your task: detect this repo's real install + build command, write it into
    .aiur/config as prewarm.base_build, and verify it locally. Do not just
    describe the command.

    base_build conventions:
    - It runs in a checkout of this repo's configured base branch, and aiur
      reruns it when that branch changes. Make it idempotent and incremental.
    - Route every tool call through `mise exec --` so Linux and macOS use the
      repo-pinned toolchain.
    - cd into the directory that holds the build manifest before running the
      install/build command.
    - Use frozen/locked installs: `npm ci`, `pnpm install --frozen-lockfile`,
      `yarn install --immutable`, `uv sync --frozen`, etc.
    - Do not mutate tracked source. Do not use brew, apt, sudo, or machine-local
      absolute paths.

    Concrete examples:
    - Node/pnpm workspaces:
      `mise exec -- corepack enable && mise exec -- pnpm install --frozen-lockfile && mise exec -- pnpm -r --if-present build`
    - Node/npm workspaces:
      `mise exec -- npm ci && mise exec -- npm run build --workspaces --if-present`
    - Elixir app in src/:
      `cd src && mise exec -- mix local.hex --force --if-missing && mise exec -- mix local.rebar --force --if-missing && mise exec -- mix deps.get && mise exec -- mix compile`

    Write this exact block shape in .aiur/config, replacing the command:

      prewarm:
        enabled: true
        base_build: "<one-time install + compile command>"
        poll_seconds: 0

    Then run the base_build command once in a clean checkout and confirm it exits
    0 and produces the expected artifacts (for example node_modules, dist, _build,
    target). Run it a second time unchanged and confirm it is fast or a near
    no-op. Fix the command until both runs succeed, then report the final command
    and the artifacts it prepares.
    """
  end

  @doc false
  @spec maybe_first_prewarm(Aiur.Init.io(), Aiur.Init.deps(), map(), map()) :: :ok
  def maybe_first_prewarm(io, deps, tracker, %{enabled: true, base_build: cmd})
      when is_binary(cmd) and cmd != "" do
    case tracker_repo(tracker) do
      repo when is_binary(repo) and repo != "" ->
        io.puts.("\nBuilding the warm base now — one-time clone + compile; later runs reuse it.")

        case deps.prewarm_build.("https://github.com/#{repo}.git", cmd) do
          {:ok, _path} ->
            io.puts.("✅ Warm base ready.")

          {:error, reason} ->
            Failure.report(io, repo, cmd, reason)
        end

      _ ->
        :ok
    end
  end

  def maybe_first_prewarm(_io, _deps, _tracker, _prewarm), do: :ok

  @doc false
  @spec maybe_resume_prewarm(Aiur.Init.io(), Aiur.Init.deps(), map(), map()) :: :ok
  def maybe_resume_prewarm(io, deps, tracker, config) do
    case prewarm_from_config(config) do
      %{enabled: true, base_build: cmd} = prewarm when is_binary(cmd) and cmd != "" ->
        maybe_first_prewarm(io, deps, tracker, prewarm)

      _ ->
        :ok
    end
  end

  @doc false
  @spec prewarm_from_config(map()) :: %{enabled: boolean(), base_build: String.t() | nil}
  def prewarm_from_config(%{"prewarm" => %{"enabled" => true, "base_build" => cmd}}),
    do: %{enabled: true, base_build: cmd}

  def prewarm_from_config(_config), do: %{enabled: false, base_build: nil}

  @doc false
  @spec prewarm_section_yaml(map()) :: iodata()
  def prewarm_section_yaml(%{enabled: true}) do
    [
      "# === Warm base pre-warm (added by `aiur init`) ===\n",
      "prewarm:\n",
      "  enabled: true\n",
      "  base_build_file: #{@prewarm_file_name}\n",
      "  poll_seconds: 0\n"
    ]
  end

  def prewarm_section_yaml(_prewarm) do
    [
      "# === Warm base pre-warm (declined in `aiur init`) ===\n",
      "prewarm:\n",
      "  enabled: false\n"
    ]
  end

  @doc false
  @spec first_prewarm_backfill(Aiur.Init.io(), Aiur.Init.deps(), Path.t(), map(), map()) :: :ok
  def first_prewarm_backfill(io, deps, target, tracker, answer) do
    ensure_prewarm_file(io, deps, target, answer)
    maybe_first_prewarm(io, deps, tracker, answer)
  end

  @doc false
  @spec ensure_prewarm_file(Aiur.Init.io(), Aiur.Init.deps(), Path.t(), map()) :: :ok
  def ensure_prewarm_file(io, deps, target, %{enabled: true, base_build: cmd})
      when is_binary(cmd) and cmd != "" do
    case deps.ensure_prewarm_file.(target, cmd) do
      {:created, path} -> io.puts.(["Created: ", Format.dim(path)])
      {:exists, _path} -> :ok
    end
  end

  def ensure_prewarm_file(_io, _deps, _target, _prewarm), do: :ok

  defp tracker_repo(%{repo: repo}), do: repo
  defp tracker_repo(_tracker), do: nil
end
