defmodule Aiur.CLI do
  @moduledoc """
  Escript entrypoint for running Aiur with an explicit config-file path.
  """

  alias Aiur.LogFile

  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @repo "aiur-team/aiur"
  @version Mix.Project.config()[:version]
  @git_rev String.trim(
             case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
               {rev, 0} -> rev
               _ -> ""
             end
           )
  @switches [
    {@acknowledgement_switch, :boolean},
    logs_root: :string,
    port: :integer,
    host: :string,
    version: :boolean,
    interactive: :boolean,
    headless: :boolean,
    no_dashboard: :boolean,
    max_agents: :integer,
    pause: :boolean,
    force: :boolean,
    todo: :boolean,
    only: :boolean,
    unfiled: :boolean,
    slugs: :boolean,
    scope: :string,
    record: :string,
    repo: :string,
    digest: :boolean,
    body: :string,
    body_file: :string,
    urgency: :string,
    blocking: :boolean,
    done: :string,
    note: :string,
    json: :boolean,
    open: :boolean,
    all: :boolean
  ]

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type deps :: %{
          required(:file_regular?) => (String.t() -> boolean()),
          required(:set_workflow_file_path) => (String.t() -> :ok | {:error, term()}),
          required(:set_logs_root) => (String.t() -> :ok | {:error, term()}),
          required(:set_server_port_override) => (non_neg_integer() | nil -> :ok | {:error, term()}),
          required(:set_server_host_override) => (String.t() | nil -> :ok | {:error, term()}),
          required(:ensure_all_started) => (-> ensure_started_result()),
          optional(:configured_max_agents) => (-> pos_integer())
        }

  @spec main([String.t()]) :: :ok | no_return()
  def main(args), do: args |> evaluate() |> dispatch()

  defp dispatch(:ok), do: wait_for_shutdown()
  defp dispatch({:version, version}), do: IO.puts("aiur #{version} (#{@repo} #{@git_rev})")
  defp dispatch({:init, opts}), do: run_init_command(opts)
  defp dispatch({:todo, issue_ids, opts}), do: run_todo_command(issue_ids, opts)
  defp dispatch({:findings, opts}), do: run_findings_command(opts)
  defp dispatch({:asks, command}), do: run_asks_command(command)

  defp dispatch({:error, message}), do: shutdown_with_error(message)

  defp shutdown_with_error(message) do
    IO.puts(:stderr, message)
    Aiur.Shutdown.shutdown(1)
  end

  defp run_init_command(opts) do
    case Aiur.Init.run(opts) do
      :ok -> :ok
      {:error, message} -> shutdown_with_error(message)
    end
  end

  defp run_todo_command(issue_ids, opts) do
    case Aiur.AgentControlCLI.todo(issue_ids, only: opts.only) do
      0 ->
        :ok

      exit_code ->
        # `--todo` runs under the distribution-free start_clean boot and never
        # starts Aiur's supervision tree. Full application cleanup would touch
        # run-only resources and can print unrelated warnings.
        System.halt(exit_code)
    end
  end

  defp run_findings_command(opts) do
    case Aiur.FindingsCLI.run(opts) do
      0 -> :ok
      exit_code -> System.halt(exit_code)
    end
  end

  defp run_asks_command(command) do
    case Aiur.AsksCLI.run(command) do
      0 -> :ok
      exit_code -> System.halt(exit_code)
    end
  end

  @doc """
  Read CLI argv from the file named by `AIUR_ARGV_FILE`, one argument
  per line. The release-mode shim writes argv to a tempfile so quoting
  survives the `bin/aiur eval` round-trip — `System.argv()` is empty
  under `eval` mode, so we cannot rely on it.

  Returns `[]` when no file is set, so existing escript callers that
  pass argv directly to `main/1` keep working unchanged.
  """
  @spec argv_from_file() :: [String.t()]
  def argv_from_file do
    case System.get_env("AIUR_ARGV_FILE") do
      path when is_binary(path) and path != "" ->
        case File.read(path) do
          {:ok, body} ->
            body
            |> String.split("\n", trim: false)
            |> Enum.reject(&(&1 == ""))

          _ ->
            []
        end

      _ ->
        []
    end
  end

  @spec evaluate([String.t()], deps()) ::
          :ok
          | {:version, String.t()}
          | {:init, %{force: boolean()}}
          | {:todo, [String.t()], %{only: boolean()}}
          | {:findings, %{unfiled: boolean(), slugs: boolean(), scope: String.t() | nil}}
          | {:findings, %{record: String.t(), repo: String.t()}}
          | {:findings, %{digest: true, scope: String.t() | nil}}
          | {:asks, Aiur.AsksCLI.command()}
          | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps()) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, positional, []} ->
        cond do
          todo_switch?(opts) -> evaluate_todo(opts, positional)
          findings_switch?(opts) and not match?(["findings" | _], positional) -> {:error, usage_message()}
          true -> evaluate_standard(opts, positional, deps)
        end

      _ ->
        {:error, usage_message()}
    end
  end

  defp evaluate_standard([version: true], _positional, _deps), do: {:version, @version}

  defp evaluate_standard(opts, ["init" | rest], _deps) do
    if rest == [] do
      {:init, %{force: Keyword.get(opts, :force, false)}}
    else
      {:error, usage_message()}
    end
  end

  defp evaluate_standard(opts, ["findings" | rest], _deps), do: evaluate_findings(opts, rest)
  defp evaluate_standard(opts, ["ask" | rest], _deps), do: evaluate_ask(opts, rest)
  defp evaluate_standard(opts, ["asks" | rest], _deps), do: evaluate_asks(opts, rest)

  defp evaluate_standard(opts, [], deps) do
    evaluate_run(opts, Aiur.Workflow.detect_run_folder_config(), deps)
  end

  defp evaluate_standard(opts, [workflow_path], deps), do: evaluate_run(opts, workflow_path, deps)
  defp evaluate_standard(_opts, _positional, _deps), do: {:error, usage_message()}

  defp evaluate_run(opts, workflow_path, deps) do
    with :ok <- require_guardrails_acknowledgement(opts),
         :ok <- maybe_set_logs_root(opts, deps),
         :ok <- maybe_set_server_port(opts, deps),
         :ok <- maybe_set_server_host(opts, deps),
         :ok <- maybe_set_max_agents(opts),
         :ok <- maybe_set_interactive(opts),
         :ok <- maybe_set_headless(opts),
         :ok <- maybe_disable_dashboard(opts),
         :ok <- maybe_set_pause(opts) do
      run(workflow_path, deps, opts)
    end
  end

  defp todo_switch?(opts), do: Keyword.has_key?(opts, :todo) or Keyword.has_key?(opts, :only)

  defp findings_switch?(opts),
    do: Enum.any?([:unfiled, :slugs, :scope, :record, :repo, :digest], &Keyword.has_key?(opts, &1))

  defp evaluate_findings(opts, positional) do
    if positional == [] do
      evaluate_findings_opts(opts)
    else
      {:error, usage_message()}
    end
  end

  defp evaluate_findings_opts(opts) do
    cond do
      Keyword.has_key?(opts, :record) or Keyword.has_key?(opts, :repo) -> evaluate_findings_record(opts)
      Keyword.has_key?(opts, :digest) -> evaluate_findings_digest(opts)
      true -> evaluate_findings_read(opts)
    end
  end

  defp evaluate_findings_record(opts) do
    if Enum.sort(Keyword.keys(opts)) == [:record, :repo] do
      {:findings, %{record: opts[:record], repo: opts[:repo]}}
    else
      {:error, usage_message()}
    end
  end

  defp evaluate_findings_digest(opts) do
    with true <- Enum.all?(Keyword.keys(opts), &(&1 in [:digest, :scope])),
         true <- opts[:digest] == true,
         {:ok, scope} <- parse_findings_scope(opts[:scope]) do
      {:findings, %{digest: true, scope: scope}}
    else
      _ -> {:error, usage_message()}
    end
  end

  defp evaluate_findings_read(opts) do
    with true <- Enum.all?(Keyword.keys(opts), &(&1 in [:unfiled, :slugs, :scope])),
         {:ok, scope} <- parse_findings_scope(opts[:scope]) do
      {:findings, %{unfiled: opts[:unfiled] || false, slugs: opts[:slugs] || false, scope: scope}}
    else
      _ -> {:error, usage_message()}
    end
  end

  defp parse_findings_scope(nil), do: {:ok, nil}
  defp parse_findings_scope(scope) when scope in ["aiur", "repo"], do: {:ok, scope}
  defp parse_findings_scope(_scope), do: :error

  defp evaluate_ask(opts, positional) do
    if Keyword.has_key?(opts, :done), do: evaluate_ask_done(opts, positional), else: evaluate_ask_create(opts, positional)
  end

  defp evaluate_ask_done(opts, positional) do
    with true <- positional == [],
         true <- Enum.all?(Keyword.keys(opts), &(&1 in [:done, :note])),
         [id] <- Keyword.get_values(opts, :done),
         true <- String.trim(id) != "",
         true <- single_option?(opts, :note) do
      {:asks, {:done, %{id: id, note: Keyword.get(opts, :note)}}}
    else
      _ -> {:error, usage_message()}
    end
  end

  defp evaluate_ask_create(opts, positional) do
    with [title] <- positional,
         true <- String.trim(title) != "",
         true <- Enum.all?(Keyword.keys(opts), &(&1 in [:body, :body_file, :urgency, :blocking])),
         true <- single_option?(opts, :body),
         true <- single_option?(opts, :body_file),
         true <- not (Keyword.has_key?(opts, :body) and Keyword.has_key?(opts, :body_file)),
         true <- single_option?(opts, :urgency),
         {:ok, body} <- ask_body(opts),
         {:ok, urgency} <- ask_urgency(opts) do
      {:asks, {:create, %{title: title, body: body, urgency: urgency, blocking: Keyword.get(opts, :blocking, false)}}}
    else
      _ -> {:error, usage_message()}
    end
  end

  defp evaluate_asks(opts, positional) do
    with true <- positional == [],
         true <- Enum.all?(Keyword.keys(opts), &(&1 in [:open, :all, :json])),
         true <- not (Keyword.get(opts, :open, false) and Keyword.get(opts, :all, false)) do
      status = if Keyword.get(opts, :all, false), do: :all, else: :open
      {:asks, {:list, %{status: status, json: Keyword.get(opts, :json, false)}}}
    else
      _ -> {:error, usage_message()}
    end
  end

  defp ask_body(opts) do
    case Keyword.fetch(opts, :body_file) do
      {:ok, path} -> File.read(path)
      :error -> {:ok, Keyword.get(opts, :body)}
    end
  end

  defp ask_urgency(opts) do
    urgency = Keyword.get(opts, :urgency, "normal")
    if urgency in ["low", "normal", "high"], do: {:ok, urgency}, else: :error
  end

  defp single_option?(opts, key), do: length(Keyword.get_values(opts, key)) <= 1

  defp evaluate_todo(opts, positional) do
    with true <- Keyword.get(opts, :todo, false),
         true <- Enum.all?(Keyword.keys(opts), &(&1 in [:todo, :only])),
         {:ok, issue_ids} <- parse_todo_ids(positional) do
      {:todo, issue_ids, %{only: Keyword.get(opts, :only, false)}}
    else
      _ -> {:error, usage_message()}
    end
  end

  defp parse_todo_ids(positional) do
    issue_ids =
      positional
      |> Enum.flat_map(&String.split(&1, ",", trim: false))
      |> Enum.map(&String.trim/1)

    if issue_ids != [] and Enum.all?(issue_ids, &Regex.match?(~r/^\d+$/, &1)) do
      {:ok, issue_ids |> Enum.map(&canonicalize_todo_id/1) |> Enum.uniq()}
    else
      :error
    end
  end

  # Enumerated issue identifiers are canonical (no leading zeros, see
  # github/issues.ex normalize_issue/4), so a requested ID must match that
  # form or `--only` can mistake the ticket it just queued for one to clear.
  defp canonicalize_todo_id(id), do: id |> String.to_integer() |> Integer.to_string()

  @spec run(String.t(), deps()) :: :ok | {:error, String.t()}
  def run(workflow_path, deps), do: run(workflow_path, deps, [])

  @spec run(String.t(), deps(), keyword()) :: :ok | {:error, String.t()}
  def run(workflow_path, deps, opts) do
    expanded_path = Path.expand(workflow_path)

    if deps.file_regular?.(expanded_path) do
      :ok = deps.set_workflow_file_path.(expanded_path)

      case deps.ensure_all_started.() do
        {:ok, _started_apps} ->
          warn_if_max_agents_exceeds_config(opts, deps)
          :ok

        {:error, reason} ->
          {:error, "Failed to start Aiur with workflow #{expanded_path}: #{inspect(reason)}"}
      end
    else
      {:error, "Config file not found: #{expanded_path}. Run `aiur init` to scaffold a .aiur/config."}
    end
  end

  @spec usage_message() :: String.t()
  defp usage_message do
    "Usage: aiur [--interactive] [--headless] [--no-dashboard] [--pause] [--max-agents <n>] [--logs-root <path>] [--port <port>] [--host <host>] [config-path]\n       aiur init [--force]\n       aiur --todo <id> [<id> ...] [--only]\n       aiur findings [--unfiled] [--slugs] [--scope aiur|repo]\n       aiur findings --record <json> --repo <owner/repo>\n       aiur findings --digest [--scope aiur|repo]\n       aiur ask <title> [--body <text>|--body-file <path>] [--urgency low|normal|high] [--blocking]\n       aiur ask --done <id> [--note <text>]\n       aiur asks [--open|--all] [--json]"
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      file_regular?: &File.regular?/1,
      set_workflow_file_path: &Aiur.Workflow.set_workflow_file_path/1,
      set_logs_root: &set_logs_root/1,
      set_server_port_override: &set_server_port_override/1,
      set_server_host_override: &set_server_host_override/1,
      ensure_all_started: fn -> Application.ensure_all_started(:aiur) end,
      configured_max_agents: &Aiur.Config.max_concurrent_agents/0
    }
  end

  defp warn_if_max_agents_exceeds_config(opts, deps) do
    with requested when is_integer(requested) <- last_option_value(opts, :max_agents),
         configured_max_agents when is_function(configured_max_agents, 0) <- Map.get(deps, :configured_max_agents),
         ceiling when is_integer(ceiling) and ceiling > 0 <- configured_max_agents.(),
         true <- requested > ceiling do
      IO.puts(:stderr, [
        "warning: --max-agents #{requested} exceeds agent.max_concurrent_agents (#{ceiling}); ",
        "the explicit CLI value wins, so using #{requested}. ",
        "Raise the config value or pass --max-agents <= #{ceiling} to silence this."
      ])
    else
      _ -> :ok
    end
  end

  defp last_option_value(opts, key) do
    case Keyword.get_values(opts, key) do
      [] -> nil
      values -> List.last(values)
    end
  end

  defp maybe_set_logs_root(opts, deps) do
    case Keyword.get_values(opts, :logs_root) do
      [] ->
        :ok

      values ->
        logs_root = values |> List.last() |> String.trim()

        if logs_root == "" do
          {:error, usage_message()}
        else
          :ok = deps.set_logs_root.(Path.expand(logs_root))
        end
    end
  end

  defp require_guardrails_acknowledgement(opts) do
    if Keyword.get(opts, @acknowledgement_switch, false) do
      :ok
    else
      {:error, acknowledgement_banner()}
    end
  end

  @spec acknowledgement_banner() :: String.t()
  defp acknowledgement_banner do
    lines = [
      "This Aiur implementation is a low key engineering preview.",
      "Codex will run without any guardrails.",
      "Aiur is not a supported product and is presented as-is.",
      "To proceed, start with `--i-understand-that-this-will-be-running-without-the-usual-guardrails` CLI argument"
    ]

    width = Enum.max(Enum.map(lines, &String.length/1))
    border = String.duplicate("─", width + 2)
    top = "╭" <> border <> "╮"
    bottom = "╰" <> border <> "╯"
    spacer = "│ " <> String.duplicate(" ", width) <> " │"

    content =
      [
        top,
        spacer
        | Enum.map(lines, fn line ->
            "│ " <> String.pad_trailing(line, width) <> " │"
          end)
      ] ++ [spacer, bottom]

    [
      IO.ANSI.red(),
      IO.ANSI.bright(),
      Enum.join(content, "\n"),
      IO.ANSI.reset()
    ]
    |> IO.iodata_to_binary()
  end

  defp set_logs_root(logs_root) do
    Application.put_env(:aiur, :log_file, LogFile.default_log_file(logs_root))
    :ok
  end

  defp maybe_set_server_port(opts, deps) do
    case Keyword.get_values(opts, :port) do
      [] ->
        :ok

      values ->
        port = List.last(values)

        if is_integer(port) and port >= 0 do
          :ok = deps.set_server_port_override.(port)
        else
          {:error, usage_message()}
        end
    end
  end

  defp set_server_port_override(port) when is_integer(port) and port >= 0 do
    Application.put_env(:aiur, :server_port_override, port)
    :ok
  end

  defp maybe_set_server_host(opts, deps) do
    case Keyword.get_values(opts, :host) do
      [] ->
        :ok

      values ->
        host = values |> List.last() |> String.trim()

        if host == "" do
          {:error, usage_message()}
        else
          :ok = deps.set_server_host_override.(host)
        end
    end
  end

  defp set_server_host_override(host) when is_binary(host) and host != "" do
    Application.put_env(:aiur, :server_host_override, host)
    :ok
  end

  defp maybe_set_interactive(opts) do
    if Keyword.get(opts, :interactive, false) do
      Application.put_env(:aiur, :interactive_cli, true)
    end

    :ok
  end

  # Detached `--bg` mode skips terminal-only supervised work (chat panes and
  # the interactive CLI block). The engine injects `--headless` for `--bg`;
  # dashboard supervision is controlled independently by `--no-dashboard`.
  defp maybe_set_headless(opts) do
    if Keyword.get(opts, :headless, false) do
      Application.put_env(:aiur, :headless, true)
    end

    :ok
  end

  defp maybe_disable_dashboard(opts) do
    if Keyword.get(opts, :no_dashboard, false) do
      Application.put_env(:aiur, :no_dashboard, true)
    end

    :ok
  end

  # `--pause` cold-starts the daemon globally paused: no agents provision even
  # with `agent:todo` tickets, until the operator unpauses. Read once in
  # `Orchestrator.init/1` via `Slots.launch_globally_paused?/0`.
  defp maybe_set_pause(opts) do
    if Keyword.get(opts, :pause, false) do
      Application.put_env(:aiur, :launch_globally_paused, true)
    end

    :ok
  end

  # Override `agent.max_concurrent_agents` at launch without editing
  # `.aiur/config`. Stored as the orchestrator's session override (highest
  # precedence; survives config refresh) and read once in `Orchestrator.init/1`.
  defp maybe_set_max_agents(opts) do
    case Keyword.get_values(opts, :max_agents) do
      [] ->
        :ok

      values ->
        case List.last(values) do
          n when is_integer(n) and n > 0 ->
            Application.put_env(:aiur, :max_concurrent_agents_override, n)
            :ok

          _ ->
            {:error, usage_message()}
        end
    end
  end

  @spec wait_for_shutdown() :: no_return()
  defp wait_for_shutdown do
    case Process.whereis(Aiur.Supervisor) do
      nil ->
        IO.puts(:stderr, "Aiur supervisor is not running")
        Aiur.Shutdown.shutdown(1)

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            case reason do
              :normal -> Aiur.Shutdown.shutdown(0)
              _ -> Aiur.Shutdown.shutdown(1)
            end
        end
    end
  end
end
