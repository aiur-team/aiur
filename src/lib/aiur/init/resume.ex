defmodule Aiur.Init.Resume do
  @moduledoc """
  Saved-config readback for a resume run — the saved-selections summary and the tracker/agents/routing readback from an existing config.
  """

  alias Aiur.Init.{Format, Prewarm, Questions}

  @gitignore_entry ".aiur/"

  @spec print_saved_summary(Aiur.Init.io(), map()) :: :ok
  def print_saved_summary(io, config) do
    io.puts.("✅ Saved selections:")

    Enum.each(saved_summary_lines(config), fn line ->
      io.puts.(IO.ANSI.format([:faint, "  " <> line]))
    end)
  end

  @spec saved_summary_lines(map()) :: [String.t()]
  def saved_summary_lines(config) do
    agent = config["agent"] || %{}
    tracker = config["tracker"] || %{}
    workspace = config["workspace"] || %{}
    polling = config["polling"] || %{}
    permission_mode = get_in(agent, ["claude", "permission_mode"])

    (["tracker: #{tracker["kind"]}"] ++
       github_summary_lines(tracker["github"] || %{}) ++
       [
         "agent: #{agent["kind"]}",
         "routing: #{format_routing(agent["routing"])}",
         permission_mode && "permission_mode: #{permission_mode}",
         "max_concurrent_agents: #{agent["max_concurrent_agents"]}",
         "max_turns: #{agent["max_turns"]}",
         "max_agent_duration_minutes: #{agent["max_agent_duration_minutes"]}",
         "workspace_root: #{workspace["root"]}",
         "pre_warmed_sessions: #{config["pre_warmed_sessions"]}",
         "polling_interval_seconds: #{polling["interval_seconds"]}",
         alerts_summary_line(config),
         config["prompt_file"] && "prompt_file: #{config["prompt_file"]}"
       ])
    |> Enum.reject(&is_nil/1)
  end

  # The github repo/bot_account summary lines, kept out of saved_summary_lines/1
  # so that function's branch count stays within the credo complexity limit.
  @spec github_summary_lines(map()) :: [String.t() | nil]
  defp github_summary_lines(github) do
    [
      github["repo"] && "repo: #{github["repo"]}",
      github["bot_account"] && "bot_account: #{github["bot_account"]}"
    ]
  end

  @spec alerts_summary_line(map()) :: String.t() | nil
  def alerts_summary_line(config) do
    case config["alerts"] do
      %{"enabled" => enabled} -> "alerts: #{enabled}"
      _ -> nil
    end
  end

  @spec format_routing(map() | term()) :: String.t()
  def format_routing(routing) when is_map(routing) do
    routing
    |> Enum.sort_by(fn {level, _} -> to_string(level) end)
    |> Enum.map_join(", ", fn {level, value} -> "#{level}:#{value}" end)
  end

  def format_routing(_routing), do: ""

  @spec tracker_from_config(map()) :: {:ok, map()} | {:error, term()}
  def tracker_from_config(config) do
    tracker = config["tracker"] || %{}

    case tracker["kind"] do
      "github" ->
        repo = get_in(config, ["tracker", "github", "repo"])
        label_prefix = get_in(config, ["tracker", "github", "label_prefix"]) || "agent"

        with :ok <- require_github_repo(repo),
             {:ok, base_branch} <- require_base_branch(tracker["base_branch"]) do
          {:ok, %{kind: "github", repo: repo, label_prefix: label_prefix, base_branch: base_branch}}
        end

      "linear" ->
        with {:ok, base_branch} <- require_base_branch(tracker["base_branch"]) do
          {:ok,
           %{
             kind: "linear",
             api_key: get_in(config, ["tracker", "linear", "api_key"]),
             project_slug: get_in(config, ["tracker", "linear", "project_slug"]),
             base_branch: base_branch
           }}
        end

      kind ->
        with {:ok, base_branch} <- require_base_branch(tracker["base_branch"]) do
          {:ok, %{kind: kind, base_branch: base_branch}}
        end
    end
  end

  defp require_github_repo(repo) do
    case Aiur.GitHub.Config.parse_configured_repo(repo) do
      {:ok, _parsed} -> :ok
      {:error, _reason} -> {:error, :missing_github_repo}
    end
  end

  defp require_base_branch(base_branch) when is_binary(base_branch) do
    case String.trim(base_branch) do
      "" -> {:error, :missing_base_branch}
      trimmed -> {:ok, trimmed}
    end
  end

  defp require_base_branch(_base_branch), do: {:error, :missing_base_branch}

  # Backends to provision labels for: the default agent kind plus any backend
  # named in the routing table (e.g. `claude:sonnet` -> `claude`).
  @spec agents_from_config(map()) :: [String.t()]
  def agents_from_config(config) do
    agent = config["agent"] || %{}
    routing_backends = (agent["routing"] || %{}) |> Map.values() |> Enum.map(&routing_backend/1)

    [agent["kind"] | routing_backends]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.filter(&(&1 in Questions.agent_kind_choices()))
    |> Questions.agent_kinds()
  end

  @spec routing_backend(term()) :: String.t()
  def routing_backend(value), do: value |> to_string() |> String.split(":") |> hd()

  # Returns the path the config now lives at, so a later backfill appends to the
  # right file even after a migration moved it.

  # `:new` — already on the `.aiur/` layout, nothing to migrate.
  @spec maybe_migrate_layout(Aiur.Init.io(), Aiur.Init.deps(), :new | :legacy, atom(), Path.t()) :: Path.t()
  def maybe_migrate_layout(_io, _deps, :new, _location, target), do: target

  # `:legacy` — root-level files. Offer to move them into `.aiur/` (settings
  # preserved verbatim), and for a repo-local layout, optionally gitignore the
  # folder. Declining leaves the legacy layout, which still loads.
  def maybe_migrate_layout(io, deps, :legacy, location, legacy_target) do
    io.puts.("\naiur now keeps its files in a #{layout_label(location)} folder; yours use the legacy root layout.")

    if io.confirm.("Migrate them into #{layout_label(location)} now?", true) do
      ignore? = location == :repo_local and io.confirm.("Also add #{@gitignore_entry} to .gitignore?", false)
      new_target = deps.config_target.(location)

      case deps.migrate_layout.(%{legacy_config: legacy_target, new_config: new_target, ignore: ignore?}) do
        {:ok, _summary} ->
          io.puts.(["Migrated to: ", Format.dim(new_target)])
          new_target

        {:error, reason} ->
          io.puts.("⚠️ Migration failed (#{inspect(reason)}); keeping the legacy layout.")
          legacy_target
      end
    else
      io.puts.("Skipped. aiur still reads your legacy layout.")
      legacy_target
    end
  end

  @spec layout_label(:global | :repo_local) :: String.t()
  def layout_label(:global), do: "~/.aiur/"
  def layout_label(:repo_local), do: ".aiur/"

  # The registry of config sections a standard `aiur init` resume can backfill.
  # See the convention note on `run/3`: each entry pairs a top-level config key
  # with the fresh-setup prompt that configures it, so an existing user is
  # offered any section their config predates — no per-feature resume code.
  #
  # Each entry:
  #   * `key`       — top-level config key; its absence marks the section missing
  #   * `label`     — human name for the "Added …" confirmation line
  #   * `prompt`    — `(io, deps, location) -> answer`; the fresh-setup prompt
  #   * `opted_in?` — `(answer) -> boolean`; did the user choose to add it?
  #   * `to_yaml`   — `(answer) -> iodata`; the YAML block to append on opt-in
  #   * `first_run` — `(io, deps, target, tracker, answer) -> any`; one-time side
  #                   effect after the block is appended (gets the config target
  #                   so it can write sibling files, e.g. the `prewarm` script)
  @spec promptable_sections() :: [map()]
  def promptable_sections do
    [
      %{
        key: "prewarm",
        label: "warm-base pre-warm",
        prompt: &Prewarm.prompt_prewarm/3,
        opted_in?: fn answer -> answer.enabled end,
        to_yaml: &Prewarm.prewarm_section_yaml/1,
        first_run: &Prewarm.first_prewarm_backfill/5
      }
    ]
  end

  # For each registered section the saved config lacks, reuse its fresh-setup
  # prompt to offer adding it. On opt-in, append the rendered block to the
  # existing file (never regenerate — hand-tuned settings stay put) and run the
  # section's one-time side effect. Declining leaves the config untouched.
  @spec backfill_missing_sections(Aiur.Init.io(), Aiur.Init.deps(), atom(), map(), map(), Path.t()) :: :ok
  def backfill_missing_sections(io, deps, location, tracker, config, target) do
    promptable_sections()
    |> Enum.filter(&missing_section?(config, &1.key))
    |> Enum.each(&offer_section(io, deps, location, tracker, target, &1))
  end

  @spec missing_section?(map(), String.t()) :: boolean()
  def missing_section?(config, key), do: not Map.has_key?(config, key)

  @spec offer_section(Aiur.Init.io(), Aiur.Init.deps(), atom(), map(), Path.t(), map()) :: :ok | nil
  def offer_section(io, deps, location, tracker, target, section) do
    answer = section.prompt.(io, deps, location)

    # Only run the one-time side effect once the section actually persisted —
    # mirrors fresh setup, which builds the warm base only on a successful write.
    if section.opted_in?.(answer) and append_section(io, deps, target, section, answer) == :ok do
      section.first_run.(io, deps, target, tracker, answer)
    end
  end

  @spec append_section(Aiur.Init.io(), Aiur.Init.deps(), Path.t(), map(), map()) :: :ok | :error
  def append_section(io, deps, target, section, answer) do
    case deps.append_config.(target, section.to_yaml.(answer)) do
      {:ok, path} ->
        io.puts.(["Added ", section.label, " to ", Format.dim(path)])
        :ok

      {:error, reason} ->
        io.puts.(["⚠️  Couldn't update #{Path.basename(target)} (", inspect(reason), ")."])
        :error
    end
  end
end
