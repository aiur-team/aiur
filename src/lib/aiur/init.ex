defmodule Aiur.Init do
  @moduledoc """
  Interactive `aiur init` wizard.

  The wizard takes an injected `io` (prompt/print) and `deps` (filesystem,
  network, auth) so it is fully unit-testable with no real side effects.
  """

  alias Aiur.Codeowners
  alias Aiur.GitHub.Labels
  alias Aiur.Init.Alerts
  alias Aiur.Init.Format
  alias Aiur.Init.Migration
  alias Aiur.Init.Prewarm
  alias Aiur.Init.Prompt
  alias Aiur.Init.Questions
  alias Aiur.Init.Resume
  alias Aiur.Init.Runtime
  alias Aiur.Init.Scaffold
  alias Aiur.Init.Templates
  alias Aiur.Prewarm.Detect

  @config_file_name ".aiur/config"
  @prompt_basename "prompt.md"
  @env_file_name ".env"
  @codeowners_file_name ".github/CODEOWNERS"
  @token_url "https://github.com/settings/tokens"
  @linear_key_url "https://linear.app/settings/api"

  @label_prefix "agent"
  @routing_order ["claude", "codex"]

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
          repo_root: (-> Path.t()),
          github_login: (-> String.t() | nil),
          github_token: (-> String.t() | nil),
          list_labels: (map() -> {:ok, [String.t()]} | {:error, term()}),
          create_labels: (map(), [String.t()] -> :ok | {:error, String.t()})
        }

  @spec run(%{force: boolean()}) :: :ok | {:error, String.t()}
  def run(opts) do
    load_dotenv()
    Runtime.ensure_http_client()
    run(opts, runtime_io(), runtime_deps())
  end

  @spec run(%{force: boolean()}, io(), deps()) :: :ok | {:error, String.t()}
  def run(opts, io, deps) do
    io.puts.(init_warning())

    case existing_config_target(opts, deps) do
      nil ->
        location = Questions.prompt_location(io)
        fresh_setup(io, deps, location, deps.config_target.(location))

      target ->
        resume(io, deps, target)
    end
  end

  defp init_warning do
    "⚠️  Use at your own risk: aiur bypasses all agent permissions, is an unstable preview, and " <>
      "has minimal token-efficiency optimization. Best for simple tasks under supervision.\n"
  end

  defp existing_config_target(%{force: true}, _deps), do: nil

  defp existing_config_target(_opts, deps) do
    Enum.find_value(config_probe_targets(deps), fn {kind, location, path} ->
      if found = deps.existing_config_path.(path), do: {kind, location, found}
    end)
  end

  defp config_probe_targets(deps) do
    [
      {:new, :repo_local, deps.config_target.(:repo_local)},
      {:legacy, :repo_local, deps.legacy_config_target.(:repo_local)},
      {:new, :global, deps.config_target.(:global)},
      {:legacy, :global, deps.legacy_config_target.(:global)}
    ]
  end

  defp resume(io, deps, {kind, location, target}) do
    case deps.load_config.(target) do
      {:ok, config} ->
        io.puts.("Found an existing config at #{target}; resuming setup.")
        Resume.print_saved_summary(io, config)
        effective_target = Resume.maybe_migrate_layout(io, deps, kind, location, target)
        tracker = Resume.tracker_from_config(deps, config)
        Resume.backfill_missing_sections(io, deps, location, tracker, config, effective_target)
        Prewarm.maybe_resume_prewarm(io, deps, tracker, config)
        setup_codeowners(io, deps, tracker)
        provision(io, deps, tracker, Resume.agents_from_config(config))

      {:error, reason} ->
        {:error,
         "Couldn't read the existing config at #{target} (#{inspect(reason)}). " <>
           "Pass --force to recreate it: aiur init --force"}
    end
  end

  defp fresh_setup(io, deps, location, target) do
    tracker = Questions.prompt_tracker(io, deps, location)
    agents = Questions.prompt_agents(io)
    routing = Questions.prompt_routing(io, agents)
    permission_mode = Questions.prompt_permission_mode(io)
    workspace_root = io.input.("Where should agents work?", Questions.workspace_default(tracker), nil)
    max_agents = Questions.prompt_int(io, "Max concurrent agents", 10, 1)
    max_turns = Questions.prompt_max_turns(io)
    max_duration = Questions.prompt_max_duration(io)

    pre_warmed = Questions.prompt_int(io, "How many opencode sessions would you like to pre-warm?", 3, 0)
    polling = Questions.prompt_int(io, "How often should aiur check the tracker for new work? (seconds)", 30, 1)
    prompt_file = if location == :global, do: "", else: io.input.("Per-repo agent prompt file", @prompt_basename, nil)
    prewarm = Prewarm.prompt_prewarm(io, deps, location)
    alerts = Alerts.prompt_alerts(io, deps, target)

    fills =
      Templates.build_fills(%{
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

    config_yaml = Templates.fill_template(deps.read_example.(), fills)

    case deps.write_config.(target, config_yaml) do
      {:ok, path} ->
        io.puts.(["Created: ", Format.dim(path)])
        Scaffold.ensure_prompt_file(io, deps, path, prompt_file, tracker_repo(tracker))
        Scaffold.ensure_aiurhooks(io, deps, path)
        Alerts.ensure_alerts(io, deps, path, alerts)
        Prewarm.ensure_prewarm_file(io, deps, path, prewarm)
        Scaffold.setup_env(io, deps, tracker)
        Scaffold.maybe_offer_gitignore(io, deps, location)
        setup_codeowners(io, deps, tracker)
        Prewarm.maybe_first_prewarm(io, deps, tracker, prewarm)
        provision(io, deps, tracker, agents)

      {:error, reason} ->
        {:error, "Failed to write #{Path.basename(target)}: #{inspect(reason)}"}
    end
  end

  defp provision(io, deps, %{kind: "github"} = tracker, agents) do
    check_agent_clis(io, deps, agents)

    if github_token_present?(deps) do
      case setup_labels(io, deps, tracker, agents) do
        :ok -> final_screen(io)
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

  defp tracker_repo(%{repo: repo}), do: repo
  defp tracker_repo(_tracker), do: nil

  defp setup_codeowners(io, deps, %{kind: "github"}) do
    repo_root = deps.repo_root.()

    repo_root
    |> then(fn repo_root -> Codeowners.file_path(repo_root: repo_root) end)
    |> maybe_create_codeowners(io, repo_root)
    |> maybe_add_operator_codeowner(io, deps, repo_root)
  end

  defp setup_codeowners(_io, _deps, _tracker), do: :ok

  defp maybe_create_codeowners(nil, io, repo_root) do
    explain_codeowners_trust(io)

    if io.confirm.("Create #{@codeowners_file_name} for aiur's GitHub trust checks?", true) do
      case create_codeowners_file(repo_root) do
        {:ok, path} ->
          io.puts.(["Created: ", Format.dim(path)])
          path

        {:error, reason} ->
          io.puts.(["⚠️  Couldn't create #{@codeowners_file_name} (", inspect(reason), ")."])
          nil
      end
    else
      io.puts.("Skipped CODEOWNERS. Without it, only explicitly configured GitHub accounts are trusted by aiur.")
      nil
    end
  end

  defp maybe_create_codeowners(path, _io, _repo_root), do: path

  defp explain_codeowners_trust(io) do
    io.puts.([
      "\naiur uses CODEOWNERS to determine which GitHub accounts it will trust ",
      "when responding to PR/issue comments. Without CODEOWNERS, only explicitly ",
      "configured accounts are trusted."
    ])
  end

  defp create_codeowners_file(repo_root) do
    path = Path.join(repo_root, @codeowners_file_name)

    if File.regular?(path) do
      {:ok, path}
    else
      File.mkdir_p!(Path.dirname(path))

      File.write(path, """
      # aiur uses CODEOWNERS to decide which GitHub accounts are trusted for PR/issue comments.
      # Add owners below, for example:
      # * @your-github-login
      """)
      |> case do
        :ok -> {:ok, path}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp maybe_add_operator_codeowner(nil, _io, _deps, _repo_root), do: :ok

  defp maybe_add_operator_codeowner(path, io, deps, repo_root) do
    detected_login = normalize_login(deps.github_login.())

    if is_binary(detected_login) and codeowners_has_login?(repo_root, detected_login) do
      :ok
    else
      path
      |> prompt_and_add_operator_codeowner(io, repo_root, detected_login)
    end
  end

  defp prompt_and_add_operator_codeowner(path, io, repo_root, default_login) do
    case prompt_github_login(io, default_login) do
      nil ->
        io.puts.("Skipped CODEOWNERS account entry because no GitHub login was provided.")

      login ->
        if codeowners_has_login?(repo_root, login) do
          :ok
        else
          offer_operator_codeowner(io, path, login)
        end
    end
  end

  defp prompt_github_login(io, default) do
    io.input.(
      "GitHub account to add to CODEOWNERS",
      default,
      "This account will be trusted to drive aiur from PR/issue comments."
    )
    |> normalize_login()
  end

  defp codeowners_has_login?(repo_root, login) do
    login in Codeowners.repo_ownership(repo_root: repo_root).owners
  end

  defp offer_operator_codeowner(io, path, login) do
    if io.confirm.("Add @#{login} to CODEOWNERS so aiur trusts your PR/issue comments?", true) do
      case add_codeowners_login(path, login) do
        {:updated, updated_path} -> io.puts.(["Updated: ", Format.dim(updated_path)])
        {:exists, _path} -> :ok
        {:error, reason} -> io.puts.(["⚠️  Couldn't update CODEOWNERS (", inspect(reason), ")."])
      end
    else
      io.puts.("Skipped. Add your account to CODEOWNERS later if you want aiur to trust your comments.")
    end
  end

  defp add_codeowners_login(path, login) do
    login = normalize_login(login)

    with true <- is_binary(login) and login != "",
         {:ok, content} <- File.read(path) do
      if codeowners_content_has_login?(content, login) do
        {:exists, path}
      else
        write_codeowners_login(path, content, login)
      end
    else
      false -> {:error, :missing_github_login}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_codeowners_login(path, content, login) do
    case File.write(path, content_with_codeowner(content, login)) do
      :ok -> {:updated, path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp codeowners_content_has_login?(content, login) do
    login = normalize_login(login)

    content
    |> String.split(~r/\R/, trim: true)
    |> Enum.flat_map(&codeowner_tokens/1)
    |> Enum.any?(&(normalize_login(&1) == login))
  end

  defp codeowner_tokens(line) do
    line
    |> String.trim()
    |> case do
      "" -> []
      "#" <> _comment -> []
      line -> line |> String.split(~r/\s+/, trim: true) |> Enum.take_while(&(not String.starts_with?(&1, "#"))) |> Enum.drop(1)
    end
  end

  defp content_with_codeowner(content, login) do
    case wildcard_rule_index(content) do
      nil ->
        append_codeowner_rule(content, login)

      index ->
        content
        |> String.split("\n", trim: false)
        |> List.update_at(index, &append_login_to_rule(&1, login))
        |> Enum.join("\n")
    end
  end

  defp wildcard_rule_index(content) do
    lines = String.split(content, "\n", trim: false)

    lines
    |> Enum.with_index()
    |> Enum.filter(fn {line, _index} -> wildcard_rule?(line) end)
    |> List.last()
    |> case do
      {_line, index} -> index
      nil -> nil
    end
  end

  defp wildcard_rule?(line) do
    case codeowner_rule_tokens(line) do
      ["*" | owners] when owners != [] -> true
      _ -> false
    end
  end

  defp codeowner_rule_tokens(line) do
    line
    |> String.trim()
    |> case do
      "" -> []
      "#" <> _comment -> []
      line -> line |> String.split(~r/\s+/, trim: true) |> Enum.take_while(&(not String.starts_with?(&1, "#")))
    end
  end

  defp append_login_to_rule(line, login) do
    case String.split(line, "#", parts: 2) do
      [rule, comment] -> String.trim_trailing(rule) <> " @#{login} #" <> comment
      [rule] -> String.trim_trailing(rule) <> " @#{login}"
    end
  end

  defp append_codeowner_rule(content, login) do
    separator = if content == "" or String.ends_with?(content, "\n"), do: "", else: "\n"
    content <> separator <> "* @#{login}\n"
  end

  defp normalize_login(nil), do: nil

  defp normalize_login(login) when is_binary(login) do
    login
    |> String.trim()
    |> String.trim_leading("@")
    |> String.downcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  # Label creation runs as gated stages: required lifecycle labels first (the
  # operator presses Enter), then optional complexity, model, and remote labels
  # (each create-or-skip). Existing repo labels are fetched once; a stage whose
  # labels all already exist is reported as created instead of prompting again.
  defp setup_labels(io, deps, %{kind: "github"} = tracker, agents) do
    kinds = Questions.agent_kinds(agents)
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
        Format.print_hint(io, "These lifecycle ticket labels are required.")
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
        Format.print_hint(io, "Optional: Used to optimize effort. You can add point-specific prompts in #{@config_file_name} to have the agent use different skills and models based on complexity.")
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
        Format.print_hint(io, "Optional: These will override complexity label model choices.")
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
            Format.print_hint(io, "Optional: Supports claude remote-control")
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
        Prompt.select(label, options, default, render: &Format.dim_help/1)
      end,
      multiselect: fn label, options, defaults -> Prompt.multiselect(label, options, defaults) end,
      confirm: fn label, default ->
        Prompt.select(label, ["Yes", "No"], if(default, do: "Yes", else: "No")) == "Yes"
      end
    }
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      config_target: &Scaffold.config_target/1,
      legacy_config_target: &Scaffold.legacy_config_target/1,
      existing_config_path: &Scaffold.existing_config_path/1,
      load_config: &Runtime.load_config/1,
      migrate_layout: &Migration.migrate_layout/1,
      read_example: fn -> Templates.config_example() end,
      detect_repo: &detect_repo/0,
      detect_toolchain: &Runtime.detect_toolchain/0,
      prewarm_build: &Runtime.run_first_prewarm/2,
      global_alerts_path: &Scaffold.global_alerts_path/0,
      existing_alerts_path: &Scaffold.existing_alerts_path/1,
      write_config: &Scaffold.write_config/2,
      append_config: &Scaffold.append_config_section/2,
      ensure_prompt_file: &Scaffold.write_prompt_file/3,
      ensure_aiurhooks: &Scaffold.write_aiurhooks/1,
      ensure_alerts: &Alerts.write_alerts_file/2,
      ensure_prewarm_file: &Scaffold.write_prewarm_file/2,
      add_gitignore_entry: &Scaffold.add_gitignore_entry/1,
      ensure_env: &Scaffold.ensure_env/1,
      check_agent_auth: &check_agent_auth/1,
      install_claude_app_server: &install_claude_app_server/0,
      repo_root: fn -> Codeowners.repo_root(File.cwd!()) end,
      github_login: &detect_github_login/0,
      github_token: &Aiur.GitHub.Config.token/0,
      list_labels: &list_repo_labels/1,
      create_labels: &create_labels/2
    }
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
  defdelegate migrate_layout(opts), to: Migration

  @doc "Raw .aiurhooks template that `aiur init` scaffolds."
  @spec aiurhooks_template() :: String.t()
  defdelegate aiurhooks_template(), to: Templates

  @doc "Raw alert sound map template that `aiur init` scaffolds as `.aiur/alerts`."
  @spec alerts_template() :: String.t()
  defdelegate alerts_template(), to: Templates

  @doc false
  @spec alerts_template({atom(), atom()} | term()) :: String.t()
  defdelegate alerts_template(os_type), to: Templates

  @doc "Raw prompt_file template (with the `{{REPO}}` placeholder) that `aiur init` scaffolds."
  @spec prompt_file_template() :: String.t()
  defdelegate prompt_file_template(), to: Templates

  @doc "Prompt_file scaffold with the repo placeholder filled for `repo` (or a neutral fallback)."
  @spec prompt_file_scaffold(String.t() | nil) :: String.t()
  defdelegate prompt_file_scaffold(repo), to: Templates

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

  defp detect_github_login do
    case System.cmd("gh", ["api", "user", "--jq", ".login"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.trim()
        |> normalize_login()

      _ ->
        nil
    end
  rescue
    _ -> nil
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
  defdelegate known_agent_kinds(), to: Questions
end
