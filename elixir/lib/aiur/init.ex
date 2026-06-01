defmodule Aiur.Init do
  @moduledoc """
  Interactive `aiur init` wizard.

  Runs as a foreground, line-based command (never the tmux-backed TUI): it
  prompts for the decisions that branch behavior, writes a pure-YAML
  `.aiurconfig` to the run folder, and — for GitHub trackers — creates the
  labels aiur depends on.

  The wizard takes an injected `io` (prompt/print) and `deps` (filesystem,
  network, auth) so it is fully unit-testable with no real side effects.
  """

  alias Aiur.CodingAgent
  alias Aiur.Config.Schema
  alias Aiur.GitHub.Labels

  @config_file_name ".aiurconfig"
  @legacy_file_name "WORKFLOW.md"
  @env_file_name ".env"
  @env_example_file_name ".env.example"
  @token_url "https://github.com/settings/tokens"

  @env_example_content """
  # aiur reads secrets from this file. Keep it out of version control.
  # GitHub personal access token (repo scope). Create one at:
  #   #{@token_url}
  GITHUB_TOKEN=
  """

  @default_label_prefix "aiur"
  @tracker_kinds ["github", "linear", "memory"]
  # Low complexity routes to the first kind, high to the last. Matches the
  # `1-2 -> claude, 3-5 -> codex` starter table the wizard teaches.
  @routing_order ["claude", "codex"]

  @type io :: %{
          puts: (IO.chardata() -> :ok),
          gets: (String.t() -> String.t() | :eof)
        }

  @type deps :: %{
          existing_config_path: (-> String.t() | nil),
          detect_repo: (-> String.t() | nil),
          write_config: (String.t() -> {:ok, Path.t()} | {:error, term()}),
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
    with :ok <- guard_existing_config(opts, deps) do
      io.puts.("Setting up aiur in this repo.")

      tracker = prompt_tracker(io, deps)
      agents = prompt_agents(io)
      concurrency = prompt_concurrency(io)
      config = assemble_config(%{tracker: tracker, agents: agents, concurrency: concurrency})

      case deps.write_config.(to_yaml(config)) do
        {:ok, path} ->
          io.puts.("Wrote #{path}.")
          setup_env(io, deps, tracker)
          run_auth_checks(io, deps, tracker, agents)
          setup_labels(io, deps, tracker, agents)
          :ok

        {:error, reason} ->
          {:error, "Failed to write #{@config_file_name}: #{inspect(reason)}"}
      end
    end
  end

  defp guard_existing_config(%{force: true}, _deps), do: :ok

  defp guard_existing_config(_opts, deps) do
    case deps.existing_config_path.() do
      nil ->
        :ok

      path ->
        {:error,
         "#{Path.basename(path)} already exists at #{path}. " <>
           "Pass --force to overwrite it: aiur init --force"}
    end
  end

  defp prompt_tracker(io, deps) do
    case prompt_choice(io, "Issue tracker", @tracker_kinds, "github") do
      "github" ->
        detected = deps.detect_repo.()
        repo = prompt(io, "GitHub repo (owner/name)", detected)
        prefix = prompt(io, "Label prefix", @default_label_prefix)
        %{kind: "github", repo: repo, label_prefix: prefix}

      "linear" ->
        %{
          kind: "linear",
          api_key: prompt(io, "Linear API key", nil),
          project_slug: prompt(io, "Linear project slug", nil)
        }

      "memory" ->
        %{kind: "memory"}
    end
  end

  # GitHub is the only tracker that reads a secret from the environment
  # (the runtime resolves `GITHUB_TOKEN` for label and issue calls), so the
  # wizard scaffolds `.env` only on that path. Linear collects its key inline.
  defp setup_env(io, deps, %{kind: "github"}) do
    {status, path} = deps.ensure_env.(@env_example_content)

    case status do
      :created -> io.puts.("Created #{path} from #{@env_example_file_name}.")
      :exists -> io.puts.("Found existing #{path}; leaving it in place.")
    end

    io.puts.("Set GITHUB_TOKEN in #{path} to continue.")
    io.puts.("Create a token (repo scope) at #{@token_url}")
  end

  defp setup_env(_io, _deps, _tracker), do: :ok

  # GitHub-only: create the label families aiur routes on, explain each as we
  # go, then teach what `complexity:<n>` actually does. A label failure (no
  # token, no write scope) warns and is skipped — setup still succeeds (R6).
  defp setup_labels(io, deps, %{kind: "github", label_prefix: prefix} = tracker, agents) do
    backends = agent_kinds(agents)
    labels = Labels.label_set(prefix, backends)

    io.puts.("Creating #{length(labels)} labels aiur routes on:")
    io.puts.("  • #{prefix}:<state> — the lifecycle state the orchestrator sets on each issue")
    io.puts.("  • model:<agent>[-<model>] — pin an issue to a specific agent or model")
    io.puts.("  • complexity:1-5 — route an issue to the agent mapped at that level")

    case deps.create_labels.(tracker, labels) do
      :ok -> io.puts.("Created labels (existing ones left as-is).")
      {:error, message} -> io.puts.("⚠ label setup skipped: #{message}")
    end

    print_routing_summary(io, agents)
  end

  defp setup_labels(_io, _deps, _tracker, _agents), do: :ok

  # Truthful R9 summary: complexity steers which agent picks up the issue via
  # the routing table — it does not change the agent's skills or its prompt.
  defp print_routing_summary(io, agents) do
    routing = starter_routing(agents)

    io.puts.("Complexity routing (which agent runs an issue at each level):")

    Enum.each(1..5, fn level ->
      io.puts.("  complexity:#{level} → #{Map.fetch!(routing, level)}")
    end)

    io.puts.("A complexity label only selects the agent — it does not change skills or prompts.")
  end

  # Multi-select agents (at least one) with a per-agent model prompt defaulting
  # to the backend's first registry model. Order routes the starter table:
  # `agent_kinds/1` sorts by @routing_order so low complexity hits the first.
  defp prompt_agents(io) do
    io
    |> prompt_agent_kinds()
    |> Enum.map(fn kind -> %{kind: kind, model: prompt_agent_model(io, kind)} end)
  end

  defp prompt_agent_kinds(io) do
    choices = agent_kind_choices()
    default = if "claude" in choices, do: "claude", else: hd(choices)
    raw = prompt(io, "Coding agents (comma-separated: #{Enum.join(choices, "/")})", default)

    case parse_agent_kinds(raw, choices) do
      [] ->
        io.puts.("Please choose at least one of: #{Enum.join(choices, ", ")}.")
        prompt_agent_kinds(io)

      kinds ->
        kinds
    end
  end

  defp parse_agent_kinds(raw, choices) do
    raw
    |> to_string()
    |> String.split(~r/[,\s]+/, trim: true)
    |> Enum.map(&String.downcase/1)
    |> Enum.filter(&(&1 in choices))
    |> Enum.uniq()
  end

  defp prompt_agent_model(io, kind) do
    prompt(io, "#{kind} model", default_model(kind))
  end

  defp default_model(kind) do
    CodingAgent.backends()
    |> Map.get(kind, %{})
    |> Map.get(:models, [])
    |> List.first()
  end

  defp agent_kind_choices do
    known = known_agent_kinds()
    Enum.filter(@routing_order, &(&1 in known)) ++ Enum.reject(known, &(&1 in @routing_order))
  end

  # Concurrency knobs pre-filled with the schema defaults so accept-on-enter
  # round-trips the same values the runtime would apply anyway. min is 1 for the
  # two pane/agent caps; pre_warmed_sessions allows 0 to disable warm-up.
  defp prompt_concurrency(io) do
    %{
      max_concurrent_agents: prompt_int(io, "Max concurrent agents", default_agents(), 1),
      max_vertical_panes: prompt_int(io, "Max vertical panes", default_panes(), 1),
      pre_warmed_sessions: prompt_int(io, "Pre-warmed sessions", default_warm(), 0)
    }
  end

  defp default_agents, do: %Schema.Agent{}.max_concurrent_agents
  defp default_panes, do: %Schema{}.max_vertical_panes
  defp default_warm, do: %Schema{}.pre_warmed_sessions

  defp prompt_int(io, label, default, min) do
    case prompt(io, label, default) do
      ^default ->
        default

      raw ->
        case Integer.parse(to_string(raw)) do
          {n, ""} when n >= min ->
            n

          _ ->
            io.puts.("Enter a whole number ≥ #{min}.")
            prompt_int(io, label, default, min)
        end
    end
  end

  # Auth checks run after the config is written so a failure can never block
  # setup (R6). Success is silent; failure warns with a fix hint and offers
  # retry/skip, then proceeds either way.
  defp run_auth_checks(io, deps, tracker, agents) do
    Enum.each(agent_kinds(agents), fn kind ->
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

        case prompt_retry_skip(io) do
          :retry -> run_auth_check(io, label, check)
          :skip -> :ok
        end
    end
  end

  defp prompt_retry_skip(io) do
    case prompt(io, "[r]etry or [s]kip", "skip") do
      "r" <> _ -> :retry
      _ -> :skip
    end
  end

  # Unprompted sections are intentionally omitted: the schema applies its
  # defaults on load, so the written file carries only the decisions the
  # wizard collected plus the starter routing table it teaches.
  defp assemble_config(%{tracker: tracker, agents: agents, concurrency: concurrency}) do
    %{
      "agent" => agent_section(agents, concurrency),
      "max_vertical_panes" => concurrency.max_vertical_panes,
      "pre_warmed_sessions" => concurrency.pre_warmed_sessions
    }
    |> put_tracker(tracker)
    |> put_claude_model(agents)
  end

  # claude reads `claude.model` from its own section; codex has no config model
  # field (the codex model selection only seeds U6's `model:codex-*` labels), so
  # only a chosen claude model is persisted here.
  defp put_claude_model(config, agents) do
    case Enum.find(agents, &(&1.kind == "claude")) do
      %{model: model} when is_binary(model) and model != "" ->
        Map.put(config, "claude", %{"model" => model})

      _ ->
        config
    end
  end

  defp put_tracker(config, %{kind: "github", repo: repo, label_prefix: prefix}) do
    config
    |> Map.put("tracker", %{"kind" => "github"})
    |> Map.put("github", drop_nil(%{"repo" => repo, "label_prefix" => prefix}))
  end

  defp put_tracker(config, %{kind: "linear", api_key: api_key, project_slug: slug}) do
    config
    |> Map.put("tracker", %{"kind" => "linear"})
    |> Map.put("linear", drop_nil(%{"api_key" => api_key, "project_slug" => slug}))
  end

  defp put_tracker(config, %{kind: "memory"}) do
    Map.put(config, "tracker", %{"kind" => "memory"})
  end

  defp agent_section(agents, concurrency) do
    %{
      "kind" => primary_kind(agents),
      "max_concurrent_agents" => concurrency.max_concurrent_agents,
      "routing" => starter_routing(agents),
      "complexity_prompts" => starter_complexity_prompts()
    }
  end

  # Empty per-level placeholders so the dev can discover the knob and drop
  # in level-specific guidance that gets appended to the end of the prompt
  # for issues carrying that `complexity:<n>` label.
  defp starter_complexity_prompts do
    Map.new(1..5, &{&1, ""})
  end

  defp starter_routing(agents) do
    case agent_kinds(agents) do
      [single] ->
        Map.new(1..5, &{&1, single})

      [low, high | _] ->
        %{1 => low, 2 => low, 3 => high, 4 => high, 5 => high}
    end
  end

  defp primary_kind(agents), do: hd(agent_kinds(agents))

  defp agent_kinds(agents) do
    agents
    |> Enum.map(& &1.kind)
    |> Enum.uniq()
    |> Enum.sort_by(&Enum.find_index(@routing_order, fn k -> k == &1 end))
  end

  defp to_yaml(config), do: Ymlr.document!(config)

  defp drop_nil(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp prompt(io, label, default) do
    suffix = if default in [nil, ""], do: "", else: " [#{default}]"

    case io.gets.("#{label}#{suffix}: ") do
      :eof ->
        default

      input ->
        case String.trim(input) do
          "" -> default
          value -> value
        end
    end
  end

  defp prompt_choice(io, label, options, default) do
    value = prompt(io, "#{label} (#{Enum.join(options, "/")})", default)

    if value in options do
      value
    else
      io.puts.("Please choose one of: #{Enum.join(options, ", ")}.")
      prompt_choice(io, label, options, default)
    end
  end

  @spec runtime_io() :: io()
  defp runtime_io do
    %{
      puts: fn message -> IO.puts(message) end,
      gets: fn prompt -> IO.gets(prompt) end
    }
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      existing_config_path: &existing_config_path/0,
      detect_repo: &detect_repo/0,
      write_config: &write_config/1,
      ensure_env: &ensure_env/1,
      check_agent_auth: &check_agent_auth/1,
      check_tracker_auth: &check_tracker_auth/1,
      create_labels: &create_labels/2
    }
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

  defp existing_config_path do
    cwd = File.cwd!()

    [@config_file_name, @legacy_file_name]
    |> Enum.map(&Path.join(cwd, &1))
    |> Enum.find(&File.regular?/1)
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

  defp write_config(yaml) do
    path = Path.join(File.cwd!(), @config_file_name)

    case File.write(path, yaml) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
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
