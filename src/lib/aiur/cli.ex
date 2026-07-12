defmodule Aiur.CLI do
  @moduledoc """
  Escript entrypoint for running Aiur with an explicit config-file path.
  """

  alias Aiur.LogFile

  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @repo "its-everdred/aiur"
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
    max_agents: :integer,
    force: :boolean,
    todo: :boolean,
    only: :boolean
  ]

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type deps :: %{
          file_regular?: (String.t() -> boolean()),
          set_workflow_file_path: (String.t() -> :ok | {:error, term()}),
          set_logs_root: (String.t() -> :ok | {:error, term()}),
          set_server_port_override: (non_neg_integer() | nil -> :ok | {:error, term()}),
          set_server_host_override: (String.t() | nil -> :ok | {:error, term()}),
          ensure_all_started: (-> ensure_started_result())
        }

  @spec main([String.t()]) :: :ok | no_return()
  def main(args) do
    case evaluate(args) do
      :ok ->
        wait_for_shutdown()

      {:version, version} ->
        IO.puts("aiur #{version} (#{@repo} #{@git_rev})")

      {:init, opts} ->
        case Aiur.Init.run(opts) do
          :ok ->
            :ok

          {:error, message} ->
            IO.puts(:stderr, message)
            Aiur.Shutdown.shutdown(1)
        end

      {:todo, issue_ids, opts} ->
        run_todo_command(issue_ids, opts)

      {:error, message} ->
        IO.puts(:stderr, message)
        Aiur.Shutdown.shutdown(1)
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
          | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps()) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, positional, []} ->
        if todo_switch?(opts) do
          evaluate_todo(opts, positional)
        else
          evaluate_standard(opts, positional, deps)
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
         :ok <- maybe_set_headless(opts) do
      run(workflow_path, deps)
    end
  end

  defp todo_switch?(opts), do: Keyword.has_key?(opts, :todo) or Keyword.has_key?(opts, :only)

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
  def run(workflow_path, deps) do
    expanded_path = Path.expand(workflow_path)

    if deps.file_regular?.(expanded_path) do
      :ok = deps.set_workflow_file_path.(expanded_path)

      case deps.ensure_all_started.() do
        {:ok, _started_apps} ->
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
    "Usage: aiur [--interactive] [--headless] [--max-agents <n>] [--logs-root <path>] [--port <port>] [--host <host>] [config-path]\n       aiur init [--force]\n       aiur --todo <id> [<id> ...] [--only]"
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      file_regular?: &File.regular?/1,
      set_workflow_file_path: &Aiur.Workflow.set_workflow_file_path/1,
      set_logs_root: &set_logs_root/1,
      set_server_port_override: &set_server_port_override/1,
      set_server_host_override: &set_server_host_override/1,
      ensure_all_started: fn -> Application.ensure_all_started(:aiur) end
    }
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

  # Lean `--bg` mode: skip UI-only supervised work (dashboard, chat panes,
  # the interactive CLI block). The engine injects `--headless` for `--bg`;
  # foreground stays interactive and unchanged.
  defp maybe_set_headless(opts) do
    if Keyword.get(opts, :headless, false) do
      Application.put_env(:aiur, :headless, true)
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
