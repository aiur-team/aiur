defmodule Aiur.Init do
  @moduledoc """
  Interactive `aiur init` wizard.

  Runs as a foreground command (never the tmux-backed TUI): it asks the
  decisions that branch behavior using interactive Owl components, fills the
  committed `.aiurconfig.example` template, writes the result to the chosen
  target (`./.aiurconfig` or the global `~/.aiurconfig`), and — for GitHub
  trackers — creates the labels aiur depends on.

  The wizard takes an injected `io` (prompt/print) and `deps` (filesystem,
  network, auth) so it is fully unit-testable with no real side effects.
  """

  alias Aiur.CodingAgent
  alias Aiur.GitHub.Labels
  alias Aiur.Init.Prompt

  @config_file_name ".aiurconfig"
  @env_file_name ".env"
  @env_example_file_name ".env.example"
  @token_url "https://github.com/settings/tokens"
  @linear_key_url "https://linear.app/settings/api"

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
  # release without a runtime file dependency. The canonical file lives at
  # the repo root for humans to read.
  @example_path Path.expand("../../../.aiurconfig.example", __DIR__)
  @external_resource @example_path
  @example_template File.read!(@example_path)

  @type io :: %{
          puts: (IO.chardata() -> :ok),
          input: (String.t(), String.t() | nil, String.t() | nil -> String.t() | nil),
          select: (String.t(), [String.t()], String.t() -> String.t()),
          multiselect: (String.t(), [String.t()], [String.t()] -> [String.t()]),
          confirm: (String.t(), boolean() -> boolean())
        }

  @type deps :: %{
          config_target: (atom() -> Path.t()),
          existing_config_path: (Path.t() -> String.t() | nil),
          load_config: (Path.t() -> {:ok, map()} | {:error, term()}),
          read_example: (-> String.t()),
          detect_repo: (-> String.t() | nil),
          write_config: (Path.t(), String.t() -> {:ok, Path.t()} | {:error, term()}),
          ensure_prompt_file: (Path.t(), String.t() -> {:created | :exists, Path.t()}),
          ensure_env: (String.t() -> {:created | :exists, Path.t()}),
          check_agent_auth: (String.t() -> :ok | {:error, String.t()}),
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
    case existing_config_target(opts, deps) do
      nil ->
        location = prompt_location(io)
        fresh_setup(io, deps, location, deps.config_target.(location))

      target ->
        resume(io, deps, target)
    end
  end

  # On a re-run, an existing repo-local (preferred) or global config is detected
  # before asking anything, so setup resumes from the saved answers instead of
  # re-prompting for location. `--force` always starts fresh.
  defp existing_config_target(%{force: true}, _deps), do: nil

  defp existing_config_target(_opts, deps) do
    Enum.find_value([:repo_local, :global], fn location ->
      deps.existing_config_path.(deps.config_target.(location))
    end)
  end

  # A re-run over an existing config skips the intro questions, shows what was
  # saved, and picks the token/label flow back up — so adding a token and
  # re-running just continues setup instead of starting over.
  defp resume(io, deps, target) do
    case deps.load_config.(target) do
      {:ok, config} ->
        io.puts.("Found an existing config at #{target}; resuming setup.")
        print_saved_summary(io, config)
        provision(io, deps, tracker_from_config(deps, config), agents_from_config(config))

      {:error, reason} ->
        {:error,
         "Couldn't read the existing config at #{target} (#{inspect(reason)}). " <>
           "Pass --force to recreate it: aiur init --force"}
    end
  end

  defp fresh_setup(io, deps, location, target) do
    tracker = prompt_tracker(io, deps, location)
    agents = prompt_agents(io)
    routing = prompt_routing(io, agents)
    permission_mode = prompt_permission_mode(io)
    workspace_root = io.input.("Where should agents work?", "~/code/aiur-workspaces", nil)
    max_agents = prompt_int(io, "Max concurrent agents", 10, 1)
    max_turns = prompt_max_turns(io)
    max_duration = prompt_max_duration(io)

    pre_warmed = prompt_int(io, "How many opencode sessions would you like to pre-warm?", 3, 0)
    polling = prompt_int(io, "How often should aiur check the tracker for new work? (seconds)", 30, 1)
    # prompt_file is repo-specific, so the general global config omits it.
    prompt_file = if location == :global, do: "", else: io.input.("Per-repo agent prompt file", "AIUR.md", nil)

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
        prompt_file: prompt_file
      })

    config_yaml = fill_template(deps.read_example.(), fills)

    case deps.write_config.(target, config_yaml) do
      {:ok, path} ->
        io.puts.(["Created: ", dim(path)])
        ensure_prompt_file(io, deps, path, prompt_file)
        setup_env(io, deps, tracker)
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
    io.puts.("Saved selections:")

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
      config["prompt_file"] && "prompt_file: #{config["prompt_file"]}"
    ]
    |> Enum.reject(&is_nil/1)
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

  # --- Prompts ---

  defp prompt_location(io) do
    options = ["repo (./.aiurconfig)", "global (~/.aiurconfig)"]

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
  # tag (1-5) picks a default model; declining routes every tag to the primary
  # agent's default model. Remote mode is not chosen here — it is applied per
  # ticket via the model:remote tag (explained when tags are listed).
  defp prompt_routing(io, agents) do
    primary = primary_kind(agents)

    io.puts.("Aiur supports story point complexity tags to optimize agent effort per ticket.")

    if io.confirm.("Would you like to select models for 5 complexity tags?", false) do
      options = routing_options(agents)
      io.puts.("Select default model for issues with the following story points (1-5):")
      Map.new(1..5, fn level -> {level, value_of(io.select.("complexity:#{level}", options, primary))} end)
    else
      Map.new(1..5, fn level -> {level, primary} end)
    end
  end

  # The bare-backend option runs the backend's own default model; the
  # "(default model)" help is greyed by dim_help/1 and stripped to the bare
  # value by value_of/1.
  defp routing_options(agents) do
    Enum.flat_map(agents, fn kind ->
      models = CodingAgent.backends() |> Map.get(kind, %{}) |> Map.get(:models, [])
      ["#{kind} (default model)" | Enum.map(models, &"#{kind}:#{&1}")]
    end)
  end

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
      "{{PRE_WARMED}}" => Integer.to_string(d.pre_warmed)
    }
  end

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
  defp ensure_prompt_file(_io, _deps, _target, prompt_file) when prompt_file in [nil, ""], do: :ok

  defp ensure_prompt_file(io, deps, target, prompt_file) do
    case deps.ensure_prompt_file.(target, prompt_file) do
      {:created, path} -> io.puts.(["Created: ", dim(path)])
      {:exists, _path} -> :ok
    end
  end

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
    |> Enum.each(fn kind ->
      run_auth_check(io, "#{kind} agent", fn -> deps.check_agent_auth.(kind) end)
    end)

    :ok
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
      existing_config_path: &existing_config_path/1,
      load_config: &load_config/1,
      read_example: fn -> @example_template end,
      detect_repo: &detect_repo/0,
      write_config: &write_config/2,
      ensure_prompt_file: &write_prompt_file/2,
      ensure_env: &ensure_env/1,
      check_agent_auth: &check_agent_auth/1,
      github_token: &Aiur.GitHub.Config.token/0,
      list_labels: &list_repo_labels/1,
      create_labels: &create_labels/2
    }
  end

  defp config_target(:global), do: Path.expand("~/" <> @config_file_name)
  defp config_target(_location), do: Path.join(File.cwd!(), @config_file_name)

  defp existing_config_path(target) do
    if File.regular?(target), do: target
  end

  defp load_config(target) do
    case Aiur.Workflow.load(target) do
      {:ok, loaded} -> {:ok, loaded.config}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_config(target, yaml) do
    case File.write(target, yaml) do
      :ok -> {:ok, target}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_prompt_file(target, prompt_file) do
    path = Path.expand(prompt_file, Path.dirname(target))

    if File.regular?(path) do
      {:exists, path}
    else
      File.write!(path, "# Agent prompt\n\nGuidance appended to each agent turn for this repo.\n")
      {:created, path}
    end
  end

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
          {:error, "#{exe} not found on PATH — install the #{kind} CLI or add it to PATH"}
        end
    end
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
