defmodule Aiur.Init do
  @moduledoc """
  Interactive `aiur init` wizard.

  Runs as a foreground command (never the tmux-backed TUI): it asks the
  decisions that branch behavior using interactive Owl components, fills the
  committed config example template, writes the result to the chosen target
  (`./.aiur/config` or the global `~/.aiur/config`, alongside `hooks`,
  `prompt.md`, and `examples/`), and — for GitHub trackers — creates the labels
  aiur depends on.

  The wizard takes an injected `io` (prompt/print) and `deps` (filesystem,
  network, auth) so it is fully unit-testable with no real side effects.
  """

  alias Aiur.CodingAgent
  alias Aiur.GitHub.Labels
  alias Aiur.Init.Prompt
  alias Aiur.Prewarm.Detect
  alias Aiur.RepoBase

  # New layout: aiur files live in a `.aiur/` folder (`.aiur/config`, `.aiur/hooks`,
  # `.aiur/prompt.md`, `.aiur/examples/`). `@config_file_name` is the repo-relative
  # path used for both the target and user-facing messages; the legacy root
  # `.aiurconfig` is still honored on read (see `Aiur.Workflow`) and is what the
  # migration path (resume) moves into the folder.
  @config_file_name ".aiur/config"
  @legacy_config_file_name ".aiurconfig"
  @prompt_basename "prompt.md"
  @examples_dir "examples"
  @gitignore_entry ".aiur/"
  # Legacy root example file -> new `.aiur/examples/` name, for the migration.
  @legacy_examples [
    {".aiurconfig.example", "config.example"},
    {".aiurhooks.example", "hooks.example"},
    {"AIUR.md.example", "prompt.md.example"}
  ]
  @env_file_name ".env"
  @env_example_file_name ".env.example"
  @token_url "https://github.com/settings/tokens"
  @linear_key_url "https://linear.app/settings/api"

  # Scaffolded prompt_file template. PromptBuilder renders this as the whole
  # turn template (Liquid), so it must reference the issue or the agent gets
  # no task. The `{{REPO}}` placeholder is init-filled (not Liquid); turn-time
  # `{{ issue.* }}` Liquid is preserved for PromptBuilder.
  @prompt_example_path Path.expand("../../../.aiur/examples/prompt.md.example", __DIR__)
  @external_resource @prompt_example_path
  @prompt_example_template File.read!(@prompt_example_path)
  @repo_placeholder "{{REPO}}"

  @env_example_content """
  # aiur reads secrets from this file. Keep it out of version control.
  # GitHub personal access token (repo scope). Create one at:
  #   #{@token_url}
  GITHUB_TOKEN=
  """

  # The workflow-state label namespace is fixed (operators don't customize it):
  # aiur picks up issues tagged `agent:todo` and walks them through `agent:*`.
  @label_prefix "agent"
  @tracker_kinds ["github", "linear"]
  @permission_modes ["bypassPermissions", "default (coming soon)", "acceptEdits (coming soon)"]
  # Low complexity routes to the first kind, high to the last.
  @routing_order ["claude", "codex"]

  # Embed the annotated example at compile time so the wizard works from a
  # release without a runtime file dependency. aiur dogfoods the `.aiur/` layout,
  # so the canonical templates live under `.aiur/examples/` in this repo.
  @example_path Path.expand("../../../.aiur/examples/config.example", __DIR__)
  @external_resource @example_path
  @example_template File.read!(@example_path)

  # The scaffolded config references hooks via `hooks_file: hooks`, so init also
  # writes a `.aiur/hooks` (from `.aiur/examples/hooks.example`) next to the config
  # — otherwise the first run would fail resolving a missing hooks file. Embedded at
  # compile time so the wizard works from a release with no runtime file dependency.
  @aiurhooks_file_name "hooks"
  @prewarm_file_name "prewarm"
  @aiurhooks_example_path Path.expand("../../../.aiur/examples/hooks.example", __DIR__)
  @external_resource @aiurhooks_example_path
  @aiurhooks_example_template File.read!(@aiurhooks_example_path)

  # The scaffolded config references the alert sound map via `alerts_file: alerts`,
  # so init also writes an extensionless `.aiur/alerts` next to the config —
  # matching the `.aiur/` convention where config-like files have no extension.
  # macOS and Linux ship different system sounds, so there is one filled example
  # per platform and init scaffolds the host's. Embedded at compile time so the
  # wizard works from a release with no runtime file dependency.
  @alerts_file_name "alerts"
  @alerts_macos_example_path Path.expand("../../../.aiur/examples/alerts.macos.example", __DIR__)
  @alerts_linux_example_path Path.expand("../../../.aiur/examples/alerts.linux.example", __DIR__)
  @external_resource @alerts_macos_example_path
  @external_resource @alerts_linux_example_path
  @alerts_macos_example_template File.read!(@alerts_macos_example_path)
  @alerts_linux_example_template File.read!(@alerts_linux_example_path)

  @type io :: %{
          puts: (IO.chardata() -> :ok),
          input: (String.t(), String.t() | nil, String.t() | nil -> String.t() | nil),
          select: (String.t(), [String.t()], String.t() -> String.t()),
          multiselect: (String.t(), [String.t()], [String.t()] -> [String.t()]),
          confirm: (String.t(), boolean() -> boolean())
        }

  @type deps :: %{
          config_target: (atom() -> Path.t()),
          legacy_config_target: (atom() -> Path.t()),
          existing_config_path: (Path.t() -> String.t() | nil),
          load_config: (Path.t() -> {:ok, map()} | {:error, term()}),
          migrate_layout: (map() -> {:ok, map()} | {:error, term()}),
          read_example: (-> String.t()),
          detect_repo: (-> String.t() | nil),
          detect_toolchain: (-> Detect.result()),
          prewarm_build: (String.t(), String.t() -> {:ok, Path.t()} | {:error, term()}),
          global_alerts_path: (-> Path.t()),
          existing_alerts_path: (Path.t() -> String.t() | nil),
          write_config: (Path.t(), String.t() -> {:ok, Path.t()} | {:error, term()}),
          append_config: (Path.t(), iodata() -> {:ok, Path.t()} | {:error, term()}),
          ensure_prompt_file: (Path.t(), String.t(), String.t() | nil -> {:created | :exists, Path.t()}),
          ensure_aiurhooks: (Path.t() -> {:created | :exists, Path.t()}),
          ensure_alerts: (Path.t(), Path.t() | nil -> {:created | :exists, Path.t()}),
          ensure_prewarm_file: (Path.t(), String.t() -> {:created | :exists, Path.t()}),
          add_gitignore_entry: (String.t() -> {:added | :exists, Path.t()}),
          ensure_env: (String.t() -> {:created | :exists, Path.t()}),
          check_agent_auth: (String.t() -> :ok | {:error, String.t()}),
          install_claude_app_server: (-> :ok | {:error, String.t()}),
          github_token: (-> String.t() | nil),
          list_labels: (map() -> {:ok, [String.t()]} | {:error, term()}),
          create_labels: (map(), [String.t()] -> :ok | {:error, String.t()})
        }

  @spec run(%{force: boolean()}) :: :ok | {:error, String.t()}
  def run(opts) do
    load_dotenv()
    ensure_http_client()
    run(opts, runtime_io(), runtime_deps())
  end

  # `aiur init` boots interactively without the OTP app started, so the Req /
  # Finch HTTP client the GitHub label calls rely on isn't running yet. Start
  # it up front so a token-present run reaches tag creation instead of crashing.
  defp ensure_http_client do
    Application.ensure_all_started(:req)
    :ok
  end

  @spec run(%{force: boolean()}, io(), deps()) :: :ok | {:error, String.t()}
  def run(opts, io, deps) do
    io.puts.(init_warning())

    case existing_config_target(opts, deps) do
      nil ->
        location = prompt_location(io)
        fresh_setup(io, deps, location, deps.config_target.(location))

      # Resume re-provisions labels/auth AND backfills config sections added by
      # newer features. `resume/3` walks `promptable_sections/0` and, for any
      # registered section the saved config lacks (e.g. the `prewarm` block from
      # #410), reuses that section's fresh-setup prompt to offer adding it —
      # appending to the existing config instead of regenerating it. CONVENTION
      # (#411): whenever you add a new init prompt for a new config section,
      # register it in `promptable_sections/0` so a standard `aiur init`
      # backfills it for existing users without needing `--force`.
      target ->
        resume(io, deps, target)
    end
  end

  # Shown once at the top of every `aiur init`: aiur runs agents with all
  # permission prompts bypassed, so the operator should know the risk up front.
  defp init_warning do
    "⚠️  Use at your own risk: aiur bypasses all agent permissions, is an unstable preview, and " <>
      "has minimal token-efficiency optimization. Best for simple tasks under supervision.\n"
  end

  # On a re-run, an existing repo-local (preferred) or global config is detected
  # before asking anything, so setup resumes from the saved answers instead of
  # re-prompting for location. `--force` always starts fresh.
  defp existing_config_target(%{force: true}, _deps), do: nil

  defp existing_config_target(_opts, deps) do
    Enum.find_value(config_probe_targets(deps), fn {kind, location, path} ->
      if found = deps.existing_config_path.(path), do: {kind, location, found}
    end)
  end

  # Probe order mirrors `Aiur.Workflow` discovery: repo `.aiur/`, repo legacy,
  # global `.aiur/`, global legacy. A `:legacy` hit drives the migration on
  # resume; a `:new` hit just resumes in place.
  defp config_probe_targets(deps) do
    [
      {:new, :repo_local, deps.config_target.(:repo_local)},
      {:legacy, :repo_local, deps.legacy_config_target.(:repo_local)},
      {:new, :global, deps.config_target.(:global)},
      {:legacy, :global, deps.legacy_config_target.(:global)}
    ]
  end

  # A re-run over an existing config skips the intro questions, shows what was
  # saved, and picks the token/label flow back up — so adding a token and
  # re-running just continues setup instead of starting over. When the config
  # sits at a legacy root location, the re-run also offers to migrate it into the
  # `.aiur/` folder (settings unchanged) before continuing.
  defp resume(io, deps, {kind, location, target}) do
    case deps.load_config.(target) do
      {:ok, config} ->
        io.puts.("Found an existing config at #{target}; resuming setup.")
        print_saved_summary(io, config)
        effective_target = maybe_migrate_layout(io, deps, kind, location, target)
        tracker = tracker_from_config(deps, config)
        backfill_missing_sections(io, deps, location, tracker, config, effective_target)
        maybe_resume_prewarm(io, deps, tracker, config)
        provision(io, deps, tracker, agents_from_config(config))

      {:error, reason} ->
        {:error,
         "Couldn't read the existing config at #{target} (#{inspect(reason)}). " <>
           "Pass --force to recreate it: aiur init --force"}
    end
  end

  # Returns the path the config now lives at, so a later backfill appends to the
  # right file even after a migration moved it.

  # `:new` — already on the `.aiur/` layout, nothing to migrate.
  defp maybe_migrate_layout(_io, _deps, :new, _location, target), do: target

  # `:legacy` — root-level files. Offer to move them into `.aiur/` (settings
  # preserved verbatim), and for a repo-local layout, optionally gitignore the
  # folder. Declining leaves the legacy layout, which still loads.
  defp maybe_migrate_layout(io, deps, :legacy, location, legacy_target) do
    io.puts.("\naiur now keeps its files in a #{layout_label(location)} folder; yours use the legacy root layout.")

    if io.confirm.("Migrate them into #{layout_label(location)} now?", true) do
      ignore? = location == :repo_local and io.confirm.("Also add #{@gitignore_entry} to .gitignore?", false)
      new_target = deps.config_target.(location)

      case deps.migrate_layout.(%{legacy_config: legacy_target, new_config: new_target, ignore: ignore?}) do
        {:ok, _summary} ->
          io.puts.(["Migrated to: ", dim(new_target)])
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

  defp layout_label(:global), do: "~/.aiur/"
  defp layout_label(:repo_local), do: ".aiur/"

  # Default workspace root, scoped by the repo captured in the tracker prompt so
  # agents land in ~/.aiur/workspaces/<owner>/<repo>/<issue> (the runtime append
  # is idempotent, so baking owner/name into the root never doubles it). The
  # global config has no fixed repo, so it keeps the bare root.
  defp workspace_default(%{kind: "github", repo: repo}) when is_binary(repo) and repo != "",
    do: "~/.aiur/workspaces/" <> repo

  defp workspace_default(_tracker), do: "~/.aiur/workspaces"

  defp fresh_setup(io, deps, location, target) do
    tracker = prompt_tracker(io, deps, location)
    agents = prompt_agents(io)
    routing = prompt_routing(io, agents)
    permission_mode = prompt_permission_mode(io)
    workspace_root = io.input.("Where should agents work?", workspace_default(tracker), nil)
    max_agents = prompt_int(io, "Max concurrent agents", 10, 1)
    max_turns = prompt_max_turns(io)
    max_duration = prompt_max_duration(io)

    pre_warmed = prompt_int(io, "How many opencode sessions would you like to pre-warm?", 3, 0)
    polling = prompt_int(io, "How often should aiur check the tracker for new work? (seconds)", 30, 1)
    # prompt_file is repo-specific, so the general global config omits it.
    prompt_file = if location == :global, do: "", else: io.input.("Per-repo agent prompt file", @prompt_basename, nil)
    prewarm = prompt_prewarm(io, deps, location)
    alerts = prompt_alerts(io, deps, target)

    fills =
      build_fills(%{
        tracker: tracker,
        agents: agents,
        routing: routing,
        permission_mode: permission_mode,
        workspace_root: workspace_root,
        max_agents: max_agents,
        max_turns: max_turns,
        max_duration: max_duration,
        pre_warmed: pre_warmed,
        polling: polling,
        prompt_file: prompt_file,
        prewarm: prewarm,
        alerts: alerts
      })

    config_yaml = fill_template(deps.read_example.(), fills)

    case deps.write_config.(target, config_yaml) do
      {:ok, path} ->
        io.puts.(["Created: ", dim(path)])
        ensure_prompt_file(io, deps, path, prompt_file, tracker_repo(tracker))
        ensure_aiurhooks(io, deps, path)
        ensure_alerts(io, deps, path, alerts)
        ensure_prewarm_file(io, deps, path, prewarm)
        setup_env(io, deps, tracker)
        maybe_offer_gitignore(io, deps, location)
        maybe_first_prewarm(io, deps, tracker, prewarm)
        provision(io, deps, tracker, agents)

      {:error, reason} ->
        {:error, "Failed to write #{Path.basename(target)}: #{inspect(reason)}"}
    end
  end

  # After the config is written (or found on a re-run), wire up secrets and
  # labels. GitHub gates label creation on a token being present: with no
  # token yet, the wizard calmly explains the single next step instead of
  # warning, so a first run never looks like a failure.
  defp provision(io, deps, %{kind: "github"} = tracker, agents) do
    check_agent_clis(io, deps, agents)

    if github_token_present?(deps) do
      case setup_labels(io, deps, tracker, agents) do
        :ok -> final_screen(io)
        # The gh fallback was printed; don't claim setup is finished.
        :error -> :ok
      end
    else
      token_setup_instructions(io)
    end

    :ok
  end

  defp provision(io, deps, %{kind: "linear"} = tracker, agents) do
    check_agent_clis(io, deps, agents)
    linear_walkthrough(io, tracker)
    final_screen(io)
    :ok
  end

  defp provision(io, deps, _tracker, agents) do
    check_agent_clis(io, deps, agents)
    final_screen(io)
    :ok
  end

  defp github_token_present?(deps), do: deps.github_token.() not in [nil, ""]

  # --- Resume (existing config) ---

  defp print_saved_summary(io, config) do
    io.puts.("✅ Saved selections:")

    Enum.each(saved_summary_lines(config), fn line ->
      io.puts.(IO.ANSI.format([:faint, "  " <> line]))
    end)
  end

  defp saved_summary_lines(config) do
    agent = config["agent"] || %{}
    tracker = config["tracker"] || %{}
    github = tracker["github"] || %{}
    workspace = config["workspace"] || %{}
    polling = config["polling"] || %{}
    permission_mode = get_in(agent, ["claude", "permission_mode"])

    [
      "tracker: #{tracker["kind"]}",
      github["repo"] && "repo: #{github["repo"]}",
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
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp alerts_summary_line(config) do
    case config["alerts"] do
      %{"enabled" => enabled} -> "alerts: #{enabled}"
      _ -> nil
    end
  end

  defp format_routing(routing) when is_map(routing) do
    routing
    |> Enum.sort_by(fn {level, _} -> to_string(level) end)
    |> Enum.map_join(", ", fn {level, value} -> "#{level}:#{value}" end)
  end

  defp format_routing(_routing), do: ""

  defp tracker_from_config(deps, config) do
    tracker = config["tracker"] || %{}

    case tracker["kind"] do
      "github" ->
        repo = get_in(config, ["tracker", "github", "repo"]) || deps.detect_repo.()
        %{kind: "github", repo: repo}

      "linear" ->
        %{
          kind: "linear",
          api_key: get_in(config, ["tracker", "linear", "api_key"]),
          project_slug: get_in(config, ["tracker", "linear", "project_slug"])
        }

      kind ->
        %{kind: kind}
    end
  end

  # Backends to provision labels for: the default agent kind plus any backend
  # named in the routing table (e.g. `claude:sonnet` -> `claude`).
  defp agents_from_config(config) do
    agent = config["agent"] || %{}
    routing_backends = (agent["routing"] || %{}) |> Map.values() |> Enum.map(&routing_backend/1)

    [agent["kind"] | routing_backends]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> agent_kinds()
  end

  defp routing_backend(value), do: value |> to_string() |> String.split(":") |> hd()

  # --- Resume backfill of init-promptable sections (#411) ---

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
  defp promptable_sections do
    [
      %{
        key: "prewarm",
        label: "warm-base pre-warm",
        prompt: &prompt_prewarm/3,
        opted_in?: fn answer -> answer.enabled end,
        to_yaml: &prewarm_section_yaml/1,
        first_run: &first_prewarm_backfill/5
      }
    ]
  end

  # For each registered section the saved config lacks, reuse its fresh-setup
  # prompt to offer adding it. On opt-in, append the rendered block to the
  # existing file (never regenerate — hand-tuned settings stay put) and run the
  # section's one-time side effect. Declining leaves the config untouched.
  defp backfill_missing_sections(io, deps, location, tracker, config, target) do
    promptable_sections()
    |> Enum.filter(&missing_section?(config, &1.key))
    |> Enum.each(&offer_section(io, deps, location, tracker, target, &1))
  end

  defp missing_section?(config, key), do: not Map.has_key?(config, key)

  defp offer_section(io, deps, location, tracker, target, section) do
    answer = section.prompt.(io, deps, location)

    # Only run the one-time side effect once the section actually persisted —
    # mirrors fresh setup, which builds the warm base only on a successful write.
    if section.opted_in?.(answer) and append_section(io, deps, target, section, answer) == :ok do
      section.first_run.(io, deps, target, tracker, answer)
    end
  end

  defp append_section(io, deps, target, section, answer) do
    case deps.append_config.(target, section.to_yaml.(answer)) do
      {:ok, path} ->
        io.puts.(["Added ", section.label, " to ", dim(path)])
        :ok

      {:error, reason} ->
        io.puts.(["⚠️  Couldn't update #{Path.basename(target)} (", inspect(reason), ")."])
        :error
    end
  end

  # The `prewarm:` block, matching the committed config example. Only rendered on
  # opt-in (`enabled: true`); the command lives in the sibling `.aiur/prewarm`
  # script (written by `first_prewarm_backfill/5`), so the block points at it via
  # `base_build_file` rather than inlining the command (mirrors fresh setup).
  defp prewarm_section_yaml(_prewarm) do
    [
      "# === Warm base pre-warm (added by `aiur init`) ===\n",
      "prewarm:\n",
      "  enabled: true\n",
      "  base_build_file: #{@prewarm_file_name}\n",
      "  poll_seconds: 0\n"
    ]
  end

  # Backfill side effect for the prewarm section: write the sibling `.aiur/prewarm`
  # script the appended `base_build_file` points at, then run the one-time first
  # build — mirroring fresh setup's `ensure_prewarm_file` + `maybe_first_prewarm`.
  defp first_prewarm_backfill(io, deps, target, tracker, answer) do
    ensure_prewarm_file(io, deps, target, answer)
    maybe_first_prewarm(io, deps, tracker, answer)
  end

  defp maybe_resume_prewarm(io, deps, tracker, config) do
    case prewarm_from_config(config) do
      %{enabled: true, base_build: cmd} = prewarm when is_binary(cmd) and cmd != "" ->
        maybe_first_prewarm(io, deps, tracker, prewarm)

      _ ->
        :ok
    end
  end

  defp prewarm_from_config(%{"prewarm" => %{"enabled" => true, "base_build" => cmd}}),
    do: %{enabled: true, base_build: cmd}

  defp prewarm_from_config(_config), do: %{enabled: false, base_build: nil}

  # --- Prompts ---

  defp prompt_location(io) do
    options = ["repo (./.aiur/)", "global (~/.aiur/)"]

    case value_of(io.select.("Where will you store aiur settings for this project?", options, hd(options))) do
      "global" -> :global
      _ -> :repo_local
    end
  end

  defp prompt_tracker(io, deps, location) do
    case io.select.("Issue tracker", @tracker_kinds, "github") do
      "github" ->
        # The global config is general, so it omits the repo (auto-detected
        # from the git remote of whatever repo aiur runs in).
        repo = if location == :global, do: nil, else: io.input.("GitHub repo (owner/name)", deps.detect_repo.(), nil)
        %{kind: "github", repo: repo}

      "linear" ->
        %{
          kind: "linear",
          api_key: io.input.("Linear API key", nil, nil),
          project_slug: io.input.("Linear project slug", nil, nil)
        }
    end
  end

  # Multi-select agents (at least one). The remote-control option is introduced
  # later (at tag creation), not here.
  defp prompt_agents(io) do
    choices = agent_kind_choices()

    selected =
      case io.multiselect.("Which agents to support", choices, ["claude"]) do
        [] -> [List.first(choices)]
        kinds -> kinds
      end

    agent_kinds(selected)
  end

  # Optional per-complexity-tag routing. With the gate accepted, each story-point
  # tag (1-5) picks backend, model, then backend-native effort. Declining routes
  # every tag to the primary agent's default backend/model/effort. Remote mode is
  # not chosen here — it is applied per ticket via the model:remote tag
  # (explained when tags are listed).
  defp prompt_routing(io, agents) do
    primary = primary_kind(agents)

    io.puts.("Aiur supports story point complexity tags to optimize agent effort per ticket.")

    if io.confirm.("Would you like to select models and effort for 5 complexity tags?", false) do
      io.puts.("Select backend, model, and effort for issues with the following story points (1-5):")
      Map.new(1..5, fn level -> {level, prompt_routing_level(io, agents, level, primary)} end)
    else
      Map.new(1..5, fn level -> {level, primary} end)
    end
  end

  defp prompt_routing_level(io, agents, level, primary) do
    backend = io.select.("complexity:#{level} backend", agents, primary) |> value_of()
    model = prompt_routing_model(io, backend, level)
    effort = prompt_routing_effort(io, backend, level)

    routing_value(backend, model, effort)
  end

  defp prompt_routing_model(io, backend, level) do
    models = CodingAgent.backends() |> Map.get(backend, %{}) |> Map.get(:models, [])

    case io.select.("complexity:#{level} #{backend} model", ["default model" | models], "default model") |> value_of() do
      "default model" -> nil
      model -> model
    end
  end

  defp prompt_routing_effort(io, backend, level) do
    case CodingAgent.efforts(backend) do
      [] ->
        nil

      efforts ->
        case io.select.("complexity:#{level} #{backend} effort", ["default effort" | efforts], "default effort") |> value_of() do
          "default effort" -> nil
          effort -> effort
        end
    end
  end

  defp routing_value(backend, nil, nil), do: backend
  defp routing_value(backend, model, nil), do: "#{backend}:#{model}"
  defp routing_value(backend, nil, effort), do: "#{backend}::#{effort}"
  defp routing_value(backend, model, effort), do: "#{backend}:#{model}:#{effort}"

  # Only bypassPermissions works for autonomous agents; the interactive modes
  # would hang waiting for approvals, so they are offered but redirected.
  defp prompt_permission_mode(io) do
    case io.select.("Claude permission mode", @permission_modes, "bypassPermissions") do
      "bypassPermissions" ->
        "bypassPermissions"

      other ->
        io.puts.("⚠️ #{other} needs an approval UI (coming soon) — using bypassPermissions.")
        "bypassPermissions"
    end
  end

  defp prompt_int(io, label, default, min, hint \\ nil) do
    case Integer.parse(to_string(io.input.(label, Integer.to_string(default), hint))) do
      {n, ""} when n >= min ->
        n

      _ ->
        io.puts.("Enter a whole number ≥ #{min}.")
        prompt_int(io, label, default, min, hint)
    end
  end

  # Max turns per issue defaults to `none` (uncapped); a number caps it.
  defp prompt_max_turns(io) do
    case normalize_int_or_none(io.input.("Max turns per issue", "none", "none = unlimited")) do
      :none ->
        "none"

      n when is_integer(n) ->
        n

      :invalid ->
        io.puts.("Enter a whole number ≥ 1, or `none`.")
        prompt_max_turns(io)
    end
  end

  # Safety net that hard-kills a stuck agent after N minutes. `none` opts out
  # (written as 0, which the watchdog treats as disabled).
  defp prompt_max_duration(io) do
    case normalize_int_or_none(io.input.("Max agent duration in minutes", "60", "Fallback for stuck agents: none = never auto-kill")) do
      :none ->
        0

      n when is_integer(n) ->
        n

      :invalid ->
        io.puts.("Enter a whole number ≥ 1, or `none`.")
        prompt_max_duration(io)
    end
  end

  defp normalize_int_or_none(value) do
    trimmed = value |> to_string() |> String.trim()

    if String.downcase(trimmed) in ["none", "unlimited", ""] do
      :none
    else
      case Integer.parse(trimmed) do
        {n, ""} when n >= 1 -> n
        _ -> :invalid
      end
    end
  end

  # --- Pre-warm opt-in (detect toolchain, confirm, write config) ---

  # Skip pre-warm for a global config: the warm base lives at a per-repo path,
  # so it is configured when init runs inside the repo, not globally.
  defp prompt_prewarm(_io, _deps, :global), do: %{enabled: false, base_build: nil}

  defp prompt_prewarm(io, deps, _location) do
    if io.confirm.("Keep a pre-warmed copy of latest main so agents skip cloning + building?", true) do
      resolve_prewarm(io, deps)
    else
      %{enabled: false, base_build: nil}
    end
  end

  defp resolve_prewarm(io, deps) do
    case deps.detect_toolchain.() do
      {:ok, %{language: lang, build_root: root, command: command}} ->
        io.puts.([
          "\nDetected ",
          to_string(lang),
          " (build root ",
          dim(root),
          "). Base build:\n  ",
          dim(command),
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

  defp print_prewarm_fallback(io) do
    io.puts.([
      "\nCouldn't auto-detect this repo's build — pre-warm left off. To enable it, paste this to your coding agent:\n\n",
      dim(prewarm_fallback_prompt())
    ])
  end

  # Detection found several competing build roots (e.g. a polyglot monorepo).
  # Pre-warm builds a single base, so rather than silently picking one — or
  # misreporting "couldn't detect" — disclose what was found and hand the operator
  # the same agent prompt to pick one (or describe a combined build).
  defp print_prewarm_ambiguous(io, candidates) do
    roots =
      Enum.map_join(candidates, "\n", fn %{language: lang, build_root: root} ->
        "  • #{lang} (#{root})"
      end)

    io.puts.([
      "\nFound multiple build roots — pre-warm builds one base, so it needs a single command:\n",
      dim(roots),
      "\n\nLeaving pre-warm off. To enable it, pick one (or describe the combined build) and paste this to your coding agent:\n\n",
      dim(prewarm_fallback_prompt())
    ])
  end

  defp prewarm_fallback_prompt do
    """
    You are working in a repository managed by aiur, an agent-orchestration
    runtime. aiur runs coding agents in isolated workspaces. To avoid every
    agent cold-cloning, installing dependencies, and compiling at the same time,
    aiur can keep one shared, pre-installed checkout of this repo's main branch
    called the warm base. Agent workspaces are materialized from that base with
    copy-on-write, so they inherit dependency caches and build artifacts.

    Your task: detect this repo's real install + build command, write it into
    .aiur/config as prewarm.base_build, and verify it locally. Do not just
    describe the command.

    base_build conventions:
    - It runs in a checkout of this repo's main branch, and aiur reruns it when
      main changes. Make it idempotent and incremental.
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

  # On opt-in, build the warm base once during init (one-time clone + compile) so
  # the first `aiur` run dispatches immediately. Mockable via deps for tests.
  defp maybe_first_prewarm(io, deps, tracker, %{enabled: true, base_build: cmd})
       when is_binary(cmd) and cmd != "" do
    case tracker_repo(tracker) do
      repo when is_binary(repo) and repo != "" ->
        io.puts.("\nBuilding the warm base now — one-time clone + compile; later runs reuse it.")

        case deps.prewarm_build.("https://github.com/#{repo}.git", cmd) do
          {:ok, _path} ->
            io.puts.("✅ Warm base ready.")

          {:error, reason} ->
            report_prewarm_failure(io, repo, cmd, reason)
        end

      _ ->
        :ok
    end
  end

  defp maybe_first_prewarm(_io, _deps, _tracker, _prewarm), do: :ok

  # A warm-base build that fails at runtime (private-repo clone auth, network, or
  # a broken base_build command) used to print a single "retries next run" line
  # with no path forward. Classify the failure, give the operator concrete
  # self-resolution steps for that class, and hand them a ready-to-paste prompt —
  # embedding the actual captured failure output — so a coding agent can fix it.
  defp report_prewarm_failure(io, repo, cmd, reason) do
    class = classify_prewarm_failure(reason)

    io.puts.(["\n⚠️  Warm base build failed (", inspect(reason), ")."])
    io.puts.(prewarm_failure_guidance(class, repo))

    io.puts.([
      "\nOr paste this to your coding agent to fix it for you:\n\n",
      dim(prewarm_failure_prompt(repo, cmd, reason))
    ])

    io.puts.("\nThe warm base also retries automatically on the next `aiur` run.")
  end

  # Clone/fetch/reset failures carry the git stderr; an auth signature in it means
  # the token is missing/invalid/unauthorized. A base_build failure is a toolchain
  # problem. Anything else degrades to generic guidance.
  defp classify_prewarm_failure({tag, _status, out})
       when tag in [:repo_base_clone_failed, :repo_base_fetch_failed, :repo_base_reset_failed] and
              is_binary(out) do
    if auth_error?(out), do: :auth, else: :clone
  end

  defp classify_prewarm_failure({:base_build_failed, _status, _out}), do: :build
  defp classify_prewarm_failure(_reason), do: :other

  defp auth_error?(out) do
    out = String.downcase(out)

    Enum.any?(
      [
        "authentication failed",
        "could not read username",
        "invalid username or token",
        "password authentication",
        "terminal prompts disabled",
        "permission denied",
        "403 forbidden"
      ],
      &String.contains?(out, &1)
    )
  end

  defp prewarm_failure_guidance(:auth, repo) do
    [
      "\nThis looks like a GitHub authentication failure cloning ",
      dim(repo),
      ".\nTo fix it yourself:\n",
      "  • Make sure GITHUB_TOKEN is set in .env and still valid:\n",
      "      ",
      dim(~s(curl -fsS -H "Authorization: Bearer $GITHUB_TOKEN" https://api.github.com/user)),
      "\n",
      "  • The token's account must have read access to this repo.\n",
      "  • Classic tokens need the `repo` scope; fine-grained tokens need Contents: Read.\n",
      "  • Then re-run `aiur init` (or `aiur`) to rebuild the warm base."
    ]
  end

  defp prewarm_failure_guidance(:clone, repo) do
    [
      "\nThe warm-base clone of ",
      dim(repo),
      " failed.\nTo fix it yourself:\n",
      "  • Confirm the repo exists and is reachable from this machine.\n",
      "  • Check your network/proxy, and that GITHUB_TOKEN (if the repo is private) has access.\n",
      "  • Then re-run `aiur init` (or `aiur`) to rebuild the warm base."
    ]
  end

  defp prewarm_failure_guidance(:build, _repo) do
    [
      "\nThe repo cloned, but the base_build command failed.\nTo fix it yourself:\n",
      "  • Run the base_build command in a clean checkout and watch where it breaks.\n",
      "  • Fix it in .aiur/config under prewarm.base_build (keep it idempotent).\n",
      "  • Then re-run `aiur init` (or `aiur`) to rebuild the warm base."
    ]
  end

  defp prewarm_failure_guidance(:other, _repo) do
    [
      "\nTo fix it yourself, inspect the error above, resolve the underlying cause,\n",
      "then re-run `aiur init` (or `aiur`) to rebuild the warm base."
    ]
  end

  # The AI handoff, mirroring `prewarm_fallback_prompt/0` but for a *runtime*
  # failure: it embeds the repo, the configured base_build, and the captured
  # failure output so the agent can diagnose auth vs. toolchain without guessing.
  defp prewarm_failure_prompt(repo, cmd, reason) do
    """
    You are working in a repository managed by aiur, an agent-orchestration
    runtime. To avoid every agent cold-cloning and recompiling, aiur keeps one
    shared, pre-installed checkout of this repo's main branch — the "warm base" —
    and materializes agent workspaces from it copy-on-write.

    Building the warm base just FAILED. Diagnose and fix it, then verify locally.

    Repo: #{repo}
    Configured prewarm.base_build: #{cmd}

    Captured failure output:
    #{failure_output(reason)}

    Likely causes and what to do:
    - GitHub auth: cloning a private repo needs a valid GITHUB_TOKEN in .env whose
      account has read access (classic token `repo` scope, or fine-grained
      Contents: Read). If the token is missing or expired, tell the operator
      exactly what to set — do not invent a secret.
    - Toolchain/build: if the repo cloned but base_build failed, detect this repo's
      real install + build command and write it into .aiur/config as
      prewarm.base_build. Route tool calls through `mise exec --`, cd into the
      directory holding the build manifest, use frozen/locked installs, and keep it
      idempotent and incremental. Do not mutate tracked source; no brew/apt/sudo.

    Then run the fix in a clean checkout, confirm it exits 0, run it a second time
    unchanged to confirm it is a near no-op, and report the final command (or the
    secret the operator must set).
    """
  end

  defp failure_output({_tag, _status, out}) when is_binary(out),
    do: out |> String.trim() |> String.slice(0, 1500)

  defp failure_output(reason), do: inspect(reason)

  # --- Alert sound opt-in ---

  # A final opt-in for cross-platform alert sounds. The first question is the
  # on/off master switch; on "yes" a second question lets the operator pick the
  # built-in macOS/Linux OS-default set or the fully customizable topic→sound map
  # — pointing them at the `.aiur/alerts` file init scaffolds so the customization
  # surface is discoverable, not just the on/off setting. Either way init writes
  # `.aiur/alerts`; the map is only consulted when OS-default sounds are off.
  # Sounds are machine-level, so this is offered for global configs too (unlike
  # prewarm, which is per-repo).
  defp prompt_alerts(io, deps, target) do
    if io.confirm.("Add sound effects for alerts (e.g. an agent is stuck or needs your input)?", false) do
      io.puts.([
        "aiur scaffolds an editable ",
        dim(".aiur/alerts"),
        " map so you can set a custom sound per event."
      ])

      source_path = prompt_reuse_global_alerts(io, deps, target)
      use_os = io.confirm.("Use the built-in OS default sounds? (No = play the custom .aiur/alerts mapping)", true)
      %{enabled: true, use_os_default_sounds: use_os, source_path: source_path}
    else
      %{enabled: false, use_os_default_sounds: false, source_path: nil}
    end
  end

  defp prompt_reuse_global_alerts(io, deps, _target) do
    source = deps.global_alerts_path.()

    case deps.existing_alerts_path.(source) do
      nil ->
        nil

      path ->
        if io.confirm.(
             "Found an existing alerts file at ~/.aiur/alerts — copy it into this repo's .aiur/alerts?",
             true
           ) do
          path
        end
    end
  end

  # --- Template fill ---

  defp build_fills(d) do
    %{
      "{{TRACKER_KIND}}" => d.tracker.kind,
      "{{TRACKER_PROVIDER}}" => tracker_provider_block(d.tracker),
      "{{AGENT_KIND}}" => primary_kind(d.agents),
      "{{MAX_AGENTS}}" => Integer.to_string(d.max_agents),
      "{{MAX_TURNS}}" => to_string(d.max_turns),
      "{{MAX_AGENT_DURATION}}" => Integer.to_string(d.max_duration),
      "{{ROUTING}}" => routing_inline(d.routing),
      "{{PERMISSION_MODE}}" => d.permission_mode,
      "{{WORKSPACE_ROOT}}" => d.workspace_root,
      "{{PROMPT_FILE}}" => d.prompt_file,
      "{{POLLING}}" => Integer.to_string(d.polling),
      "{{PRE_WARMED}}" => Integer.to_string(d.pre_warmed),
      "{{PREWARM_ENABLED}}" => to_string(d.prewarm.enabled),
      "{{PREWARM_BASE_BUILD_FILE}}" => prewarm_base_build_file_line(d.prewarm),
      "{{ALERTS_ENABLED}}" => to_string(d.alerts.enabled),
      "{{ALERTS_OS_SOUNDS}}" => to_string(d.alerts.use_os_default_sounds)
    }
  end

  defp prewarm_base_build_file_line(%{enabled: true, base_build: cmd}) when is_binary(cmd) and cmd != "",
    do: "  base_build_file: #{@prewarm_file_name}\n"

  defp prewarm_base_build_file_line(_), do: ""

  defp fill_template(template, fills) do
    Enum.reduce(fills, template, fn {token, value}, acc ->
      String.replace(acc, token, to_string(value))
    end)
  end

  defp tracker_provider_block(%{kind: "github", repo: repo}) do
    # label_prefix is fixed (`agent`) and matches the schema default, so the
    # written config omits it.
    [
      "  github:",
      repo && "    repo: #{repo}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp tracker_provider_block(%{kind: "linear", api_key: api_key, project_slug: slug}) do
    [
      "  linear:",
      api_key && "    api_key: #{api_key}",
      slug && "    project_slug: #{slug}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp tracker_provider_block(_tracker), do: ""

  defp routing_inline(routing) do
    "{" <> Enum.map_join(1..5, ", ", fn level -> "#{level}: #{Map.fetch!(routing, level)}" end) <> "}"
  end

  # --- Closing steps ---

  # Create the per-repo prompt file the config points at so the very next
  # config load (auth checks, then boot) doesn't fail on a missing file.
  defp ensure_prompt_file(_io, _deps, _target, prompt_file, _repo) when prompt_file in [nil, ""], do: :ok

  defp ensure_prompt_file(io, deps, target, prompt_file, repo) do
    case deps.ensure_prompt_file.(target, prompt_file, repo) do
      {:created, path} -> io.puts.(["Created: ", dim(path)])
      {:exists, _path} -> :ok
    end
  end

  # The scaffolded config references the hooks file via `hooks_file: hooks`, so
  # make sure `.aiur/hooks` exists (created from .aiurhooks.example). Never clobber
  # an existing one — the dev may have tuned it for their toolchain.
  defp ensure_aiurhooks(io, deps, target) do
    case deps.ensure_aiurhooks.(target) do
      {:created, path} -> io.puts.(["Created: ", dim(path)])
      {:exists, _path} -> :ok
    end
  end

  # The scaffolded config references the alert sound map via `alerts_file: alerts`,
  # so make sure `.aiur/alerts` exists (created from the host's alerts example).
  # Never clobber an existing one — the operator may have tuned the topic→sound map.
  defp ensure_alerts(io, deps, target, alerts) do
    case deps.ensure_alerts.(target, alerts.source_path) do
      {:created, path} -> io.puts.(["Created: ", dim(path)])
      {:exists, _path} -> :ok
    end
  end

  # Write the detected base build command to a sibling `.aiur/prewarm` script so
  # the multi-line shell stays out of the config (which points at it via
  # `prewarm.base_build_file`). Only on opt-in; never clobbers an existing script.
  defp ensure_prewarm_file(io, deps, target, %{enabled: true, base_build: cmd})
       when is_binary(cmd) and cmd != "" do
    case deps.ensure_prewarm_file.(target, cmd) do
      {:created, path} -> io.puts.(["Created: ", dim(path)])
      {:exists, _path} -> :ok
    end
  end

  defp ensure_prewarm_file(_io, _deps, _target, _prewarm), do: :ok

  # Repo-local only: offer to gitignore the whole `.aiur/` folder. Declining leaves
  # it tracked (team-shared config, as `.aiurconfig` was). Global setup has nothing
  # in the repo to ignore, so the prompt is skipped.
  defp maybe_offer_gitignore(_io, _deps, :global), do: :ok

  defp maybe_offer_gitignore(io, deps, _repo_local) do
    if io.confirm.("Add #{@gitignore_entry} to .gitignore?", false) do
      case deps.add_gitignore_entry.(@gitignore_entry) do
        {:added, path} -> io.puts.(["Updated: ", dim(path)])
        {:exists, _path} -> :ok
      end
    else
      :ok
    end
  end

  defp tracker_repo(%{repo: repo}), do: repo
  defp tracker_repo(_tracker), do: nil

  # GitHub is the only tracker that reads a secret from the environment, so the
  # wizard scaffolds `.env` only on that path. Linear collects its key inline.
  defp setup_env(io, deps, %{kind: "github"}) do
    {status, path} = deps.ensure_env.(@env_example_content)

    case status do
      :created -> io.puts.(["Created: ", dim(path)])
      :exists -> io.puts.(["Found: ", dim(path)])
    end
  end

  defp setup_env(_io, _deps, _tracker), do: :ok

  # Label creation runs as gated stages: required lifecycle labels first (the
  # operator presses Enter), then optional complexity, model, and remote labels
  # (each create-or-skip). Existing repo labels are fetched once; a stage whose
  # labels all already exist is reported as created instead of prompting again.
  defp setup_labels(io, deps, %{kind: "github"} = tracker, agents) do
    kinds = agent_kinds(agents)
    existing = fetch_existing_labels(deps, tracker)

    with :ok <- create_lifecycle_labels(io, deps, tracker, existing),
         :ok <- maybe_create_complexity_labels(io, deps, tracker, existing),
         :ok <- maybe_create_model_labels(io, deps, tracker, existing, kinds) do
      maybe_create_remote_label(io, deps, tracker, existing, kinds)
    end
  end

  defp setup_labels(_io, _deps, _tracker, _agents), do: :ok

  # Existing repo labels, fetched once. If we can't read them, treat all as
  # missing — create_labels is idempotent, so already-present labels are skipped.
  defp fetch_existing_labels(deps, tracker) do
    case deps.list_labels.(tracker) do
      {:ok, existing} -> existing
      {:error, _reason} -> []
    end
  end

  # Stage 1 — the required lifecycle (`agent:*`) labels the orchestrator reads.
  defp create_lifecycle_labels(io, deps, tracker, existing) do
    labels = Labels.state_labels(@label_prefix)

    case labels -- existing do
      [] ->
        io.puts.(label_status_line("Lifecycle agent tags"))
        :ok

      missing ->
        io.puts.("\nAiur uses ticket labels to route agents. Next we'll use your GITHUB_TOKEN to create the following labels in the repo:")
        print_label_list(io, labels)
        print_hint(io, "These lifecycle ticket labels are required.")
        io.input.("Press Enter to create them", "", nil)
        create_labels_request(io, deps, tracker, labels, missing)
    end
  end

  # Stage 2 — optional complexity labels.
  defp maybe_create_complexity_labels(io, deps, tracker, existing) do
    labels = Labels.complexity_labels()

    case labels -- existing do
      [] ->
        io.puts.(label_status_line("Complexity tags"))
        :ok

      missing ->
        io.puts.("\nNext you can create story point complexity labels:")
        print_label_list(io, labels)
        print_hint(io, "Optional: Used to optimize effort. You can add point-specific prompts in #{@config_file_name} to have the agent use different skills and models based on complexity.")
        create_or_skip(io, deps, tracker, labels, missing, "Create the complexity labels?", true)
    end
  end

  # Stage 3 — optional model-override labels for the chosen backends (the remote
  # flag is its own stage). These override complexity-routed model choices.
  defp maybe_create_model_labels(io, deps, tracker, existing, kinds) do
    labels = Labels.model_labels(kinds)

    case labels -- existing do
      [] ->
        io.puts.(label_status_line("Model tags"))
        :ok

      missing ->
        io.puts.("\nNext you can create model labels to route specific issues to different models:")
        print_label_list(io, labels)
        print_hint(io, "Optional: These will override complexity label model choices.")
        create_or_skip(io, deps, tracker, labels, missing, "Create the model labels?", true)
    end
  end

  # Stage 4 — optional remote-control flag label, only when claude is supported.
  defp maybe_create_remote_label(io, deps, tracker, existing, kinds) do
    case Labels.alias_labels(kinds) do
      [] ->
        :ok

      labels ->
        case labels -- existing do
          [] ->
            io.puts.(label_status_line("Remote-control tag"))
            :ok

          missing ->
            io.puts.("\nFinally, if you'd like the agent to open a ticket in remote-control mode, add this label:")
            print_label_list(io, labels)
            print_hint(io, "Optional: Supports claude remote-control")
            create_or_skip(io, deps, tracker, labels, missing, "Create the model:remote label?", false)
        end
    end
  end

  defp create_or_skip(io, deps, tracker, labels, missing, prompt, default) do
    if io.confirm.(prompt, default) do
      create_labels_request(io, deps, tracker, labels, missing)
    else
      io.puts.("Skipped.")
      :ok
    end
  end

  # Reported in the saved-selections style when a stage's labels all already
  # exist, so a re-run confirms them instead of prompting to create them again.
  defp label_status_line(name), do: IO.ANSI.format([:faint, "  #{name}: created."])

  defp create_labels_request(io, deps, tracker, labels, missing) do
    case deps.create_labels.(tracker, missing) do
      :ok ->
        io.puts.("Created #{length(missing)} (#{length(labels) - length(missing)} already existed).")
        :ok

      {:error, message} ->
        emit_gh_label_fallback(io, tracker, missing, message)
        :error
    end
  end

  # Pad each label to the widest in the list so the `—` descriptions align.
  defp print_label_list(io, labels) do
    width = Enum.reduce(labels, 0, fn label, acc -> max(acc, String.length(label)) end)

    Enum.each(labels, fn label ->
      io.puts.(["  ", String.pad_trailing(label, width), " — ", Labels.describe(label)])
    end)
  end

  defp print_hint(io, text), do: io.puts.(dim("  " <> text))

  # When the token can't create labels (e.g. missing scope), hand the operator
  # a copy-paste command to create them, then ask them to re-run to confirm.
  defp emit_gh_label_fallback(io, tracker, labels, message) do
    repo = tracker[:repo] || "<owner/name>"

    io.puts.("\n⚠️ Couldn't create labels automatically (#{message}).")
    io.puts.("Run these to create them yourself (existing ones are skipped):")

    Enum.each(labels, fn label ->
      io.puts.("  gh label create #{shell_arg(label)} --repo #{repo} --description #{shell_arg(Labels.describe(label))} --force")
    end)

    io.puts.("Then run `aiur init` again to confirm all labels exist.")
  end

  defp shell_arg(value), do: "'" <> String.replace(to_string(value), "'", "'\\''") <> "'"

  # Shown when GitHub is the tracker but no token is set yet. Calm, single
  # next step — never a warning — with the minimum scopes aiur needs.
  defp token_setup_instructions(io) do
    io.puts.("\nNext — give aiur a GitHub token so it can create labels and act as its bot account:")
    io.puts.("  1. Create a token at #{@token_url}")
    io.puts.("     Classic token:")
    io.puts.("       • Click `Generate new token (classic)`")
    io.puts.("       • Check the `repo` scope (Full control of private repositories)")
    io.puts.("     Fine-grained token:")
    io.puts.("       • Repository access → `Only select repositories` → choose this repo")
    io.puts.("       • Permissions → Repository permissions, set each to `Read and write`:")
    io.puts.("           – Issues  (creating labels needs this)")
    io.puts.("           – Contents")
    io.puts.("           – Pull requests")
    io.puts.(IO.ANSI.format([:faint, "     The token's account must have write access to this repo (otherwise GitHub returns 404)."]))
    io.puts.("  2. Put it in #{@env_file_name} as GITHUB_TOKEN=<token> (aiur's bot account).")
    io.puts.("  3. Run `aiur init` again to continue creating repo tags.")
  end

  defp final_screen(io) do
    io.puts.("\n✅ aiur is set up. You can now:")
    io.puts.("  1. Add `agent:todo` labels to the issues you want worked.")
    io.puts.("  2. Run `aiur` (foreground) or `aiur --bg` (background) to start agents.")
  end

  defp linear_walkthrough(io, %{kind: "linear"}) do
    io.puts.("\nNext — give aiur a Linear API key:")
    io.puts.("  1. Create a personal API key at #{@linear_key_url}")
    io.puts.("  2. Set linear.api_key in your config or the LINEAR_API_KEY env var.")
    io.puts.("\n⚠️  WARNING: Linear support is LIMITED and lightly tested. If it")
    io.puts.("   breaks, please file an issue — github trackers are the happy path.")
  end

  defp linear_walkthrough(_io, _tracker), do: :ok

  # Agent-CLI presence checks run after the config is written so a failure can
  # never block setup. Success is silent; a missing CLI warns with a fix hint
  # and offers retry/skip, then proceeds either way.
  defp check_agent_clis(io, deps, agents) do
    # Only CLI-backed agents have a command to verify; `claude-repl` (a routed
    # or resumed remote transport) has none, so skip it rather than warn.
    agents
    |> Enum.filter(&(&1 in @routing_order))
    |> Enum.each(&ensure_agent_cli(io, deps, &1))

    :ok
  end

  # Claude's CLI is the `aiur-claude` app-server, published to npm. When it's
  # missing, install it before warning so selecting claude during init yields a
  # working backend with no manual PATH steps. An already-present command skips
  # the install (idempotent); a failed install degrades to a manual-install hint
  # rather than wedging setup.
  defp ensure_agent_cli(io, deps, "claude") do
    case deps.check_agent_auth.("claude") do
      :ok -> :ok
      {:error, _missing} -> install_claude_then_check(io, deps)
    end
  end

  defp ensure_agent_cli(io, deps, kind) do
    run_auth_check(io, "#{kind} agent", fn -> deps.check_agent_auth.(kind) end)
  end

  defp install_claude_then_check(io, deps) do
    io.puts.("Installing claude app-server (aiur-claude)…")

    case deps.install_claude_app_server.() do
      :ok ->
        run_auth_check(io, "claude agent", fn -> deps.check_agent_auth.("claude") end)

      {:error, message} ->
        io.puts.(
          "⚠️ claude agent: couldn't install aiur-claude (#{message}). " <>
            "Install it manually: npm install -g aiur-claude"
        )

        :ok
    end
  end

  defp run_auth_check(io, label, check) do
    case check.() do
      :ok ->
        :ok

      {:error, message} ->
        io.puts.("⚠️ #{label}: #{message}")

        if io.confirm.("Retry #{label}?", false) do
          run_auth_check(io, label, check)
        else
          :ok
        end
    end
  end

  # --- Agent-kind helpers ---

  # Only CLI-backed agents are user-selectable. `claude-repl` is an internal
  # remote transport (not its own CLI), so it never appears in the wizard.
  defp agent_kind_choices do
    Enum.filter(@routing_order, &(&1 in known_agent_kinds()))
  end

  defp primary_kind(agents), do: hd(agent_kinds(agents))

  defp agent_kinds(kinds) when is_list(kinds) do
    kinds
    |> Enum.uniq()
    |> Enum.sort_by(&Enum.find_index(@routing_order, fn k -> k == &1 end))
  end

  # --- Runtime io / deps ---

  @spec runtime_io() :: io()
  defp runtime_io do
    %{
      puts: fn message -> IO.puts(message) end,
      input: fn label, default, hint ->
        case Prompt.input(label, default, hint: hint) do
          "" -> default
          value -> value
        end
      end,
      select: fn label, options, default ->
        Prompt.select(label, options, default, render: &dim_help/1)
      end,
      multiselect: fn label, options, defaults -> Prompt.multiselect(label, options, defaults) end,
      confirm: fn label, default ->
        Prompt.select(label, ["Yes", "No"], if(default, do: "Yes", else: "No")) == "Yes"
      end
    }
  end

  # Greys an inline help suffix — the ` (...)` tail of an option — so the hint
  # (default model, file path, "coming soon") reads as secondary without
  # competing with the choice. `value_of/1` recovers the bare option value.
  defp dim_help(option) do
    case String.split(option, " (", parts: 2) do
      [head, rest] -> [head, IO.ANSI.format([:faint, " (" <> rest])]
      [head] -> head
    end
  end

  defp value_of(option), do: option |> to_string() |> String.split(" (", parts: 2) |> hd() |> String.trim()

  defp dim(text), do: IO.ANSI.format([:faint, to_string(text)])

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      config_target: &config_target/1,
      legacy_config_target: &legacy_config_target/1,
      existing_config_path: &existing_config_path/1,
      load_config: &load_config/1,
      migrate_layout: &migrate_layout/1,
      read_example: fn -> @example_template end,
      detect_repo: &detect_repo/0,
      detect_toolchain: &detect_toolchain/0,
      prewarm_build: &run_first_prewarm/2,
      global_alerts_path: &global_alerts_path/0,
      existing_alerts_path: &existing_alerts_path/1,
      write_config: &write_config/2,
      append_config: &append_config_section/2,
      ensure_prompt_file: &write_prompt_file/3,
      ensure_aiurhooks: &write_aiurhooks/1,
      ensure_alerts: &write_alerts_file/2,
      ensure_prewarm_file: &write_prewarm_file/2,
      add_gitignore_entry: &add_gitignore_entry/1,
      ensure_env: &ensure_env/1,
      check_agent_auth: &check_agent_auth/1,
      install_claude_app_server: &install_claude_app_server/0,
      github_token: &Aiur.GitHub.Config.token/0,
      list_labels: &list_repo_labels/1,
      create_labels: &create_labels/2
    }
  end

  defp config_target(:global), do: Path.expand("~/" <> @config_file_name)
  defp config_target(_location), do: Path.join(File.cwd!(), @config_file_name)

  defp legacy_config_target(:global), do: Path.expand("~/" <> @legacy_config_file_name)
  defp legacy_config_target(_location), do: Path.join(File.cwd!(), @legacy_config_file_name)

  defp global_alerts_path, do: Path.expand("~/.aiur/" <> @alerts_file_name)

  defp existing_config_path(target) do
    if File.regular?(target), do: target
  end

  defp existing_alerts_path(path) do
    if File.regular?(path), do: path
  end

  defp load_config(target) do
    case Aiur.Workflow.load(target) do
      {:ok, loaded} -> {:ok, loaded.config}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_config(target, yaml) do
    File.mkdir_p!(Path.dirname(target))

    case File.write(target, yaml) do
      :ok -> {:ok, target}
      {:error, reason} -> {:error, reason}
    end
  end

  # Append a config section to an existing file, separated by a blank line, so a
  # resume backfill adds the block without disturbing the user's other settings.
  defp append_config_section(target, block) do
    with {:ok, existing} <- File.read(target),
         body = String.trim_trailing(existing, "\n") <> "\n\n" <> IO.iodata_to_binary(block),
         :ok <- File.write(target, body) do
      {:ok, target}
    end
  end

  defp detect_toolchain, do: Detect.detect(File.cwd!())

  defp run_first_prewarm(url, command) do
    RepoBase.refresh(RepoBase.base_path(url), url, command)
  end

  defp write_prompt_file(target, prompt_file, repo) do
    path = Path.expand(prompt_file, Path.dirname(target))

    if File.regular?(path) do
      {:exists, path}
    else
      File.write!(path, prompt_file_scaffold(repo))
      {:created, path}
    end
  end

  defp write_aiurhooks(target) do
    path = Path.join(Path.dirname(target), @aiurhooks_file_name)

    if File.regular?(path) do
      {:exists, path}
    else
      File.write!(path, @aiurhooks_example_template)
      {:created, path}
    end
  end

  defp write_alerts_file(target, source_path) do
    path = Path.join(Path.dirname(target), @alerts_file_name)

    if File.regular?(path) do
      {:exists, path}
    else
      write_new_alerts_file(path, source_path)
    end
  end

  defp write_new_alerts_file(path, source_path) when is_binary(source_path) do
    if same_path?(path, source_path) do
      {:exists, path}
    else
      File.cp!(source_path, path)
      {:created, path}
    end
  end

  defp write_new_alerts_file(path, _source_path) do
    File.write!(path, alerts_template(:os.type()))
    {:created, path}
  end

  defp same_path?(left, right), do: Path.expand(left) == Path.expand(right)

  defp write_prewarm_file(target, command) do
    path = Path.join(Path.dirname(target), @prewarm_file_name)

    if File.regular?(path) do
      {:exists, path}
    else
      File.write!(path, command <> "\n")
      {:created, path}
    end
  end

  # Append an entry to the repo's `.gitignore` (creating it if absent), unless the
  # entry is already present. Idempotent; returns `:exists` when nothing changed.
  defp add_gitignore_entry(entry), do: add_gitignore_entry(File.cwd!(), entry)

  defp add_gitignore_entry(dir, entry) do
    path = Path.join(dir, ".gitignore")

    existing =
      case File.read(path) do
        {:ok, content} -> content
        {:error, _} -> ""
      end

    present? = existing |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.member?(entry)

    if present? do
      {:exists, path}
    else
      separator = if existing == "" or String.ends_with?(existing, "\n"), do: "", else: "\n"
      File.write!(path, existing <> separator <> entry <> "\n")
      {:added, path}
    end
  end

  @doc """
  Migrate a legacy root-level aiur layout into the `.aiur/` folder. Copies the
  referenced hooks/prompt files and any `*.example` templates into `.aiur/`,
  writes the config to `.aiur/config` (rewriting `hooks_file:`/`prompt_file:` to
  the folder-relative names), and only then removes the legacy originals — so a
  partial failure never leaves a state aiur can't load. Tracked files are moved
  via git (and removed with `git rm`); with `ignore: true`, `.aiur/` is appended
  to `.gitignore` and the new files are left untracked. Settings are preserved
  verbatim apart from the two pointer values.
  """
  @spec migrate_layout(%{
          :legacy_config => Path.t(),
          :new_config => Path.t(),
          optional(:ignore) => boolean()
        }) :: {:ok, %{moved: [Path.t()]}} | {:error, term()}
  def migrate_layout(%{legacy_config: legacy_config, new_config: new_config} = opts) do
    ignore? = Map.get(opts, :ignore, false)
    base_dir = Path.dirname(legacy_config)
    new_dir = Path.dirname(new_config)
    git? = git_work_tree?(base_dir)

    raw = File.read!(legacy_config)
    config = parse_yaml(raw)

    File.mkdir_p!(new_dir)

    # Resolve the referenced pointer files. `pointer_src/2` only returns a source
    # that exists AND lives inside the repo — a `hooks_file:`/`prompt_file:` value
    # pointing outside the repo (absolute or `../` traversal, or `~/shared`) is
    # left in place, never copied or deleted.
    pointers = [
      {"hooks_file", pointer_src(base_dir, config["hooks_file"]), Path.join(new_dir, @aiurhooks_file_name)},
      {"prompt_file", pointer_src(base_dir, config["prompt_file"]), Path.join(new_dir, @prompt_basename)}
    ]

    pointer_moves = for {_key, src, dest} <- pointers, not is_nil(src), do: {src, dest}

    example_moves =
      for {legacy_name, new_name} <- @legacy_examples,
          src = Path.join(base_dir, legacy_name),
          File.regular?(src),
          do: {src, Path.join([new_dir, @examples_dir, new_name])}

    # 1. Copy content-preserving files into `.aiur/` (legacy left intact so far).
    copied =
      Enum.map(pointer_moves ++ example_moves, fn {src, dest} ->
        File.mkdir_p!(Path.dirname(dest))
        File.cp!(src, dest)
        {src, dest}
      end)

    # 2. Write the rewritten config — the new layout is now complete and loadable.
    #    Only rewrite a pointer key whose file was actually migrated into `.aiur/`;
    #    a key whose source stayed put keeps its original value (still resolves).
    migrated_keys = for {key, src, _dest} <- pointers, not is_nil(src), do: key
    File.write!(new_config, rewrite_pointers(raw, migrated_keys))

    # 3. Remove the legacy originals (config last is implicit: it's only removed
    #    once `new_config` exists above).
    [legacy_config | Enum.map(copied, fn {src, _dest} -> src end)]
    |> Enum.each(&remove_path(&1, base_dir, git?))

    new_paths = [new_config | Enum.map(copied, fn {_src, dest} -> dest end)]

    # 4. Track the new files, or leave them untracked and gitignored.
    if ignore? do
      add_gitignore_entry(base_dir, @gitignore_entry)
    else
      if git?, do: git(base_dir, ["add", "--" | new_paths])
    end

    {:ok, %{moved: new_paths}}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp pointer_src(_base, value) when value in [nil, ""], do: nil

  defp pointer_src(base, value) do
    src = Path.expand(value, base)
    if File.regular?(src) and inside?(base, src), do: src
  end

  # True when `path` is `base` itself or nested under it — guards the migration
  # against copying/deleting a pointer target that resolves outside the repo
  # (absolute, `~/...`, or `../` traversal).
  defp inside?(base, path) do
    base = Path.expand(base)
    path = Path.expand(path)
    path == base or String.starts_with?(path, base <> "/")
  end

  defp rewrite_pointers(raw, keys) do
    new_value = %{"hooks_file" => @aiurhooks_file_name, "prompt_file" => @prompt_basename}
    Enum.reduce(keys, raw, fn key, acc -> replace_pointer_value(acc, key, new_value[key]) end)
  end

  # Rewrite the value of a top-level `key:` line, matching a double-quoted,
  # single-quoted, or bare token so a quoted value containing spaces is replaced
  # whole. Indented/nested keys and trailing inline comments are left untouched.
  defp replace_pointer_value(raw, key, new_value) do
    Regex.replace(~r/^(#{key}:[ \t]*)(?:"[^"]*"|'[^']*'|\S+)/m, raw, "\\1#{new_value}")
  end

  defp parse_yaml(raw) do
    case YamlElixir.read_from_string(raw) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp git_work_tree?(dir) do
    case System.cmd("git", ["rev-parse", "--is-inside-work-tree"], cd: dir, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out) == "true"
      _ -> false
    end
  rescue
    _ -> false
  end

  # Remove a legacy file: `git rm` when tracked (keeps git's rename detection
  # against the freshly-added `.aiur/` copy), plain delete otherwise.
  defp remove_path(path, base_dir, true) do
    rel = Path.relative_to(path, base_dir)

    case git(base_dir, ["rm", "-q", "-f", "--", rel]) do
      :ok -> :ok
      :error -> File.rm(path)
    end
  end

  defp remove_path(path, _base_dir, false), do: File.rm(path)

  defp git(dir, args) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      _ -> :error
    end
  rescue
    _ -> :error
  end

  @doc "Raw .aiurhooks template that `aiur init` scaffolds."
  @spec aiurhooks_template() :: String.t()
  def aiurhooks_template, do: @aiurhooks_example_template

  @doc "Raw alert sound map template that `aiur init` scaffolds as `.aiur/alerts`."
  @spec alerts_template() :: String.t()
  def alerts_template, do: alerts_template(:os.type())

  @doc false
  @spec alerts_template({atom(), atom()} | term()) :: String.t()
  def alerts_template({:unix, :darwin}), do: @alerts_macos_example_template
  def alerts_template({:unix, _}), do: @alerts_linux_example_template
  def alerts_template(_os_type), do: @alerts_linux_example_template

  @doc "Raw prompt_file template (with the `{{REPO}}` placeholder) that `aiur init` scaffolds."
  @spec prompt_file_template() :: String.t()
  def prompt_file_template, do: @prompt_example_template

  @doc "Prompt_file scaffold with the repo placeholder filled for `repo` (or a neutral fallback)."
  @spec prompt_file_scaffold(String.t() | nil) :: String.t()
  def prompt_file_scaffold(repo) do
    String.replace(@prompt_example_template, @repo_placeholder, repo_display(repo))
  end

  defp repo_display(repo) when is_binary(repo) do
    case String.trim(repo) do
      "" -> "current"
      trimmed -> trimmed
    end
  end

  defp repo_display(_repo), do: "current"

  defp create_labels(%{kind: "github", repo: repo}, labels) do
    with {:ok, {owner, name}} <- parse_owner_repo(repo),
         {:ok, token} <- require_github_token() do
      case Labels.ensure(owner, name, token, labels) do
        :ok -> :ok
        {:error, reason} -> {:error, label_error_message(reason)}
      end
    end
  end

  defp create_labels(_tracker, _labels), do: :ok

  # Existing label names on the repo, so a re-run only creates what's missing.
  defp list_repo_labels(%{kind: "github", repo: repo}) do
    with {:ok, {owner, name}} <- parse_owner_repo(repo),
         {:ok, token} <- require_github_token() do
      fetch_label_names(owner, name, token, 1, [])
    end
  end

  defp list_repo_labels(_tracker), do: {:ok, []}

  defp fetch_label_names(owner, name, token, page, acc) do
    url = "https://api.github.com/repos/#{owner}/#{name}/labels?per_page=100&page=#{page}"

    headers = [
      {"authorization", "Bearer #{token}"},
      {"accept", "application/vnd.github+json"},
      {"user-agent", "aiur-init"}
    ]

    case Req.get(url, headers: headers, connect_options: [timeout: 30_000]) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        names = acc ++ Enum.map(body, & &1["name"])
        if length(body) == 100, do: fetch_label_names(owner, name, token, page + 1, names), else: {:ok, names}

      {:ok, %{status: status}} ->
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, {:github_api_request, reason}}
    end
  rescue
    error -> {:error, {:github_api_request, Exception.message(error)}}
  end

  defp parse_owner_repo(repo) do
    case repo && String.split(to_string(repo), "/", trim: true) do
      [owner, name] -> {:ok, {owner, name}}
      _ -> {:error, "github.repo is not set to owner/name — add it to #{@config_file_name}"}
    end
  end

  defp require_github_token do
    case Aiur.GitHub.Config.token() do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, "GITHUB_TOKEN not set — add it to #{@env_file_name} (#{@token_url})"}
    end
  end

  defp label_error_message({:github_api_status, 403, label}),
    do: "GitHub rejected #{label} (403) — the token needs repo write scope"

  defp label_error_message({:github_api_status, 404, label}),
    do:
      "GitHub returned 404 for #{label} — the repo wasn't found or the token can't access it. " <>
        "Check github.repo in #{@config_file_name} and that the token's account has access to this repo (Issues: Read & write)."

  defp label_error_message({:github_api_status, status, label}),
    do: "GitHub rejected #{label} (HTTP #{status})"

  defp label_error_message({:github_api_request, reason}),
    do: "request failed: #{inspect(reason)}"

  defp label_error_message(other), do: inspect(other)

  defp check_agent_auth(kind) do
    case agent_executable(kind) do
      nil ->
        {:error, "no command configured for #{kind}"}

      exe ->
        if System.find_executable(exe) do
          :ok
        else
          {:error, "#{exe} not found on PATH — #{install_hint(kind, exe)}"}
        end
    end
  end

  # Names the exact command that provisions a missing backend so the warning is
  # actionable instead of pointing at a generic "CLI".
  defp install_hint("claude", _exe), do: "install it with: npm install -g aiur-claude"
  defp install_hint(_kind, exe), do: "install #{exe} and add it to PATH"

  # Installs the claude app-server (`aiur-claude`) globally via npm. Isolated
  # behind its own function so `aiur init` can provision the claude backend and
  # tests can mock it. Returns a message on failure so the wizard degrades
  # gracefully instead of crashing when npm is absent or the install errors.
  defp install_claude_app_server do
    case System.find_executable("npm") do
      nil ->
        {:error, "npm not found on PATH"}

      npm ->
        case System.cmd(npm, ["install", "-g", "aiur-claude"], stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {output, status} -> {:error, "npm exited #{status}: #{String.trim(output)}"}
        end
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp agent_executable(kind) do
    command =
      case kind do
        "claude" -> Aiur.Claude.Config.command()
        "codex" -> Aiur.Codex.Config.command()
        _ -> nil
      end

    case command && String.split(String.trim(command), ~r/\s+/, trim: true) do
      [exe | _] -> exe
      _ -> nil
    end
  end

  defp detect_repo do
    case System.cmd("git", ["remote", "get-url", "origin"], stderr_to_stdout: true) do
      {output, 0} -> parse_repo(String.trim(output))
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp parse_repo(url) do
    url
    |> String.replace_suffix(".git", "")
    |> String.split(~r{[/:]}, trim: true)
    |> Enum.take(-2)
    |> case do
      [owner, name] when owner != "" and name != "" -> "#{owner}/#{name}"
      _ -> nil
    end
  end

  defp ensure_env(example_content) do
    cwd = File.cwd!()
    File.write!(Path.join(cwd, @env_example_file_name), example_content)
    env_path = Path.join(cwd, @env_file_name)

    if File.regular?(env_path) do
      {:exists, env_path}
    else
      File.write!(env_path, example_content)
      {:created, env_path}
    end
  end

  # `aiur init` runs as a bare foreground process (the launcher only sources
  # .env for the running app, not init), so a GITHUB_TOKEN the operator placed
  # in the repo's .env is not yet in the environment. Load any KEY=VALUE pairs
  # from the cwd .env — an existing env var always wins — so the token check and
  # label creation see it. Values are populated, never inspected or logged.
  defp load_dotenv do
    path = Path.join(File.cwd!(), @env_file_name)

    case File.read(path) do
      {:ok, content} -> Enum.each(parse_dotenv(content), &put_env_if_unset/1)
      {:error, _} -> :ok
    end
  end

  defp put_env_if_unset({key, value}) do
    if System.get_env(key) in [nil, ""], do: System.put_env(key, value)
    :ok
  end

  @doc false
  @spec parse_dotenv(String.t()) :: [{String.t(), String.t()}]
  def parse_dotenv(content) do
    content
    |> String.split("\n")
    |> Enum.flat_map(&parse_dotenv_line/1)
  end

  defp parse_dotenv_line(line) do
    trimmed = String.trim(line)

    if trimmed == "" or String.starts_with?(trimmed, "#") do
      []
    else
      parse_dotenv_pair(trimmed)
    end
  end

  defp parse_dotenv_pair(trimmed) do
    case String.split(trimmed, "=", parts: 2) do
      [key, raw] ->
        case dotenv_value(raw) do
          "" -> []
          value -> [{String.trim(key), value}]
        end

      _ ->
        []
    end
  end

  defp dotenv_value(raw), do: raw |> String.trim() |> String.trim("\"") |> String.trim("'")

  @doc false
  @spec known_agent_kinds() :: [String.t()]
  def known_agent_kinds, do: CodingAgent.known_backends()
end
