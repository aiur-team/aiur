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

  @default_label_prefix "aiur"
  @tracker_kinds ["github", "linear", "memory"]
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
          input: (String.t(), String.t() | nil -> String.t() | nil),
          select: (String.t(), [String.t()], String.t() -> String.t()),
          multiselect: (String.t(), [String.t()], [String.t()] -> [String.t()]),
          confirm: (String.t(), boolean() -> boolean())
        }

  @type deps :: %{
          config_target: (atom() -> Path.t()),
          existing_config_path: (Path.t() -> String.t() | nil),
          read_example: (-> String.t()),
          detect_repo: (-> String.t() | nil),
          write_config: (Path.t(), String.t() -> {:ok, Path.t()} | {:error, term()}),
          ensure_env: (String.t() -> {:created | :exists, Path.t()}),
          check_agent_auth: (String.t() -> :ok | {:error, String.t()}),
          check_tracker_auth: (map() -> :ok | {:error, String.t()}),
          create_labels: (map(), [String.t()] -> :ok | {:error, String.t()})
        }

  @spec run(%{force: boolean()}) :: :ok | {:error, String.t()}
  def run(opts) do
    run(opts, runtime_io(), runtime_deps())
  end

  @spec run(%{force: boolean()}, io(), deps()) :: :ok | {:error, String.t()}
  def run(opts, io, deps) do
    location = prompt_location(io)
    target = deps.config_target.(location)

    with :ok <- guard_existing_config(opts, deps, target) do
      io.puts.("Setting up aiur (#{location} config at #{target}).")

      tracker = prompt_tracker(io, deps, location)
      agents = prompt_agents(io)
      routing = prompt_routing(io, agents)
      permission_mode = prompt_permission_mode(io)
      workspace_root = io.input.("Workspace root", "~/code/aiur-workspaces")
      max_agents = prompt_int(io, "Max concurrent agents", 10, 1)
      max_turns = prompt_int(io, "Max turns per issue", 20, 1)
      max_duration = prompt_int(io, "Max agent duration minutes (0 disables)", 60, 0)
      pre_warmed = prompt_int(io, "Pre-warmed sessions", 3, 0)
      polling = prompt_int(io, "Polling interval seconds", 30, 1)
      prompt_file = io.input.("Per-repo agent prompt file", "AIUR.md")

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
          io.puts.("Wrote #{path}.")
          setup_env(io, deps, tracker)
          run_auth_checks(io, deps, tracker, agents)
          setup_labels(io, deps, tracker, agents)
          bot_token_walkthrough(io, tracker)
          linear_walkthrough(io, tracker)
          :ok

        {:error, reason} ->
          {:error, "Failed to write #{Path.basename(target)}: #{inspect(reason)}"}
      end
    end
  end

  defp guard_existing_config(%{force: true}, _deps, _target), do: :ok

  defp guard_existing_config(_opts, deps, target) do
    case deps.existing_config_path.(target) do
      nil ->
        :ok

      path ->
        {:error, "#{path} already exists. Pass --force to overwrite it: aiur init --force"}
    end
  end

  # --- Prompts ---

  defp prompt_location(io) do
    case io.select.("Config location", ["repo-local", "global"], "repo-local") do
      "global" -> :global
      _ -> :repo_local
    end
  end

  defp prompt_tracker(io, deps, location) do
    case io.select.("Issue tracker", @tracker_kinds, "github") do
      "github" ->
        # The global config is general, so it omits the repo (auto-detected
        # from the git remote of whatever repo aiur runs in).
        repo = if location == :global, do: nil, else: io.input.("GitHub repo (owner/name)", deps.detect_repo.())
        prefix = io.input.("Label prefix", @default_label_prefix)
        %{kind: "github", repo: repo, label_prefix: prefix}

      "linear" ->
        %{
          kind: "linear",
          api_key: io.input.("Linear API key", nil),
          project_slug: io.input.("Linear project slug", nil)
        }

      "memory" ->
        %{kind: "memory"}
    end
  end

  # Multi-select agents (at least one). A claude pick surfaces the RC hint.
  defp prompt_agents(io) do
    choices = agent_kind_choices()

    selected =
      case io.multiselect.("Which agents to support", choices, ["claude"]) do
        [] -> [List.first(choices)]
        kinds -> kinds
      end

    if "claude" in selected do
      io.puts.("ℹ aiur supports Claude remote-control mode for claude agents.")
    end

    agent_kinds(selected)
  end

  # Optional per-complexity-tag routing. Each tag (1-5) can pick a backend or
  # `backend:model` (e.g. claude:sonnet). Declining routes every tag to the
  # primary agent.
  defp prompt_routing(io, agents) do
    primary = primary_kind(agents)

    if io.confirm.("Set specific models per complexity tag?", false) do
      options = routing_options(agents)
      Map.new(1..5, fn level -> {level, io.select.("complexity:#{level}", options, primary)} end)
    else
      Map.new(1..5, fn level -> {level, primary} end)
    end
  end

  defp routing_options(agents) do
    Enum.flat_map(agents, fn kind ->
      models = CodingAgent.backends() |> Map.get(kind, %{}) |> Map.get(:models, [])
      [kind | Enum.map(models, &"#{kind}:#{&1}")]
    end)
  end

  # Only bypassPermissions works for autonomous agents; the interactive modes
  # would hang waiting for approvals, so they are offered but redirected.
  defp prompt_permission_mode(io) do
    case io.select.("Claude permission mode", @permission_modes, "bypassPermissions") do
      "bypassPermissions" ->
        "bypassPermissions"

      other ->
        io.puts.("⚠ #{other} needs an approval UI (coming soon) — using bypassPermissions.")
        "bypassPermissions"
    end
  end

  defp prompt_int(io, label, default, min) do
    case Integer.parse(to_string(io.input.(label, Integer.to_string(default)))) do
      {n, ""} when n >= min ->
        n

      _ ->
        io.puts.("Enter a whole number ≥ #{min}.")
        prompt_int(io, label, default, min)
    end
  end

  # --- Template fill ---

  defp build_fills(d) do
    %{
      "{{TRACKER_KIND}}" => d.tracker.kind,
      "{{TRACKER_PROVIDER}}" => tracker_provider_block(d.tracker),
      "{{AGENT_KIND}}" => primary_kind(d.agents),
      "{{MAX_AGENTS}}" => Integer.to_string(d.max_agents),
      "{{MAX_TURNS}}" => Integer.to_string(d.max_turns),
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

  defp tracker_provider_block(%{kind: "github", repo: repo, label_prefix: prefix}) do
    [
      "  github:",
      repo && "    repo: #{repo}",
      "    label_prefix: #{prefix || @default_label_prefix}"
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

  # GitHub is the only tracker that reads a secret from the environment, so the
  # wizard scaffolds `.env` only on that path. Linear collects its key inline.
  defp setup_env(io, deps, %{kind: "github"}) do
    {status, path} = deps.ensure_env.(@env_example_content)

    case status do
      :created -> io.puts.("Created #{path} from #{@env_example_file_name}.")
      :exists -> io.puts.("Found existing #{path}; leaving it in place.")
    end
  end

  defp setup_env(_io, _deps, _tracker), do: :ok

  defp setup_labels(io, deps, %{kind: "github", label_prefix: prefix} = tracker, agents) do
    labels = Labels.label_set(prefix, agent_kinds(agents))

    io.puts.("Creating #{length(labels)} labels aiur routes on (#{prefix}:<state>, model:<agent>, complexity:1-5)…")

    case deps.create_labels.(tracker, labels) do
      :ok -> io.puts.("Created labels (existing ones left as-is).")
      {:error, message} -> io.puts.("⚠ label setup skipped: #{message}")
    end
  end

  defp setup_labels(_io, _deps, _tracker, _agents), do: :ok

  defp bot_token_walkthrough(io, %{kind: "github"}) do
    io.puts.("\nNext — give aiur a GitHub token to act as its bot account:")
    io.puts.("  1. Create a token (repo scope) at #{@token_url}")
    io.puts.("  2. Put it in #{@env_file_name} as GITHUB_TOKEN=<token>")
    io.puts.("  3. aiur posts PRs and comments as that token's account.")
  end

  defp bot_token_walkthrough(_io, _tracker), do: :ok

  defp linear_walkthrough(io, %{kind: "linear"}) do
    io.puts.("\nNext — give aiur a Linear API key:")
    io.puts.("  1. Create a personal API key at #{@linear_key_url}")
    io.puts.("  2. Set linear.api_key in your config or the LINEAR_API_KEY env var.")
    io.puts.("\n⚠️  WARNING: Linear support is LIMITED and lightly tested. If it")
    io.puts.("   breaks, please file an issue — github trackers are the happy path.")
  end

  defp linear_walkthrough(_io, _tracker), do: :ok

  # Auth checks run after the config is written so a failure can never block
  # setup. Success is silent; failure warns with a fix hint and offers
  # retry/skip, then proceeds either way.
  defp run_auth_checks(io, deps, tracker, agents) do
    Enum.each(agents, fn kind ->
      run_auth_check(io, "#{kind} agent", fn -> deps.check_agent_auth.(kind) end)
    end)

    run_auth_check(io, "#{tracker.kind} tracker", fn -> deps.check_tracker_auth.(tracker) end)
    :ok
  end

  defp run_auth_check(io, label, check) do
    case check.() do
      :ok ->
        :ok

      {:error, message} ->
        io.puts.("⚠ #{label}: #{message}")

        if io.confirm.("Retry #{label}?", false) do
          run_auth_check(io, label, check)
        else
          :ok
        end
    end
  end

  # --- Agent-kind helpers ---

  defp agent_kind_choices do
    known = known_agent_kinds()
    Enum.filter(@routing_order, &(&1 in known)) ++ Enum.reject(known, &(&1 in @routing_order))
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
      input: fn label, default ->
        prompt = if default in [nil, ""], do: label, else: "#{label} [#{default}]"

        case Owl.IO.input(label: prompt, optional: true) do
          value when value in [nil, ""] -> default
          value -> value
        end
      end,
      select: fn label, options, _default -> Owl.IO.select(options, label: label) end,
      multiselect: fn label, options, _defaults -> Owl.IO.multiselect(options, label: label) end,
      confirm: fn label, default -> Owl.IO.confirm(message: label, default: default) end
    }
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      config_target: &config_target/1,
      existing_config_path: &existing_config_path/1,
      read_example: fn -> @example_template end,
      detect_repo: &detect_repo/0,
      write_config: &write_config/2,
      ensure_env: &ensure_env/1,
      check_agent_auth: &check_agent_auth/1,
      check_tracker_auth: &check_tracker_auth/1,
      create_labels: &create_labels/2
    }
  end

  defp config_target(:global), do: Path.expand("~/" <> @config_file_name)
  defp config_target(_location), do: Path.join(File.cwd!(), @config_file_name)

  defp existing_config_path(target) do
    if File.regular?(target), do: target
  end

  defp write_config(target, yaml) do
    case File.write(target, yaml) do
      :ok -> {:ok, target}
      {:error, reason} -> {:error, reason}
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

  defp check_tracker_auth(%{kind: "github"}) do
    case Aiur.GitHub.Config.token() do
      token when is_binary(token) and token != "" ->
        github_identity(token)

      _ ->
        {:error, "GITHUB_TOKEN not set — add it to #{@env_file_name} (#{@token_url})"}
    end
  end

  defp check_tracker_auth(%{kind: "linear"}) do
    case Aiur.Linear.Config.api_key() do
      key when is_binary(key) and key != "" ->
        :ok

      _ ->
        {:error, "Linear API key not set — set linear.api_key or LINEAR_API_KEY"}
    end
  end

  defp check_tracker_auth(_tracker), do: :ok

  defp github_identity(token) do
    headers = [
      {"authorization", "Bearer #{token}"},
      {"accept", "application/vnd.github+json"},
      {"user-agent", "aiur-init"}
    ]

    case Req.get("https://api.github.com/user", headers: headers, connect_options: [timeout: 10_000]) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: 401}} -> {:error, "GITHUB_TOKEN rejected (401) — create a repo-scoped token at #{@token_url}"}
      {:ok, %{status: status}} -> {:error, "GitHub identity check failed (HTTP #{status})"}
      {:error, reason} -> {:error, "GitHub identity check failed: #{inspect(reason)}"}
    end
  rescue
    error -> {:error, "GitHub identity check failed: #{Exception.message(error)}"}
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

  @doc false
  @spec known_agent_kinds() :: [String.t()]
  def known_agent_kinds, do: CodingAgent.known_backends()
end
