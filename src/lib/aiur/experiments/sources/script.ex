defmodule Aiur.Experiments.Sources.Script do
  @moduledoc false

  alias Aiur.AgentEnvironment
  alias Aiur.Experiments.Coverage
  alias Aiur.Experiments.Sources.{Common, Ndjson}

  @output_limit 8 * 1_024 * 1_024
  @credential_names ~w(
    GITHUB_TOKEN GH_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN MISE_GITHUB_TOKEN AIUR_SUPERVISOR_TOKEN
    AIUR_CI_READINESS_TOKEN AIUR_DASHBOARD_PASSWORD AIUR_SECRET_KEY_BASE AIUR_LEASE_DATABASE_URL ERL_CRASH_DUMP ERL_CRASH_DUMP_SECONDS
  )

  @spec observations(term(), String.t(), map(), map()) :: map()
  def observations(metric, ref, window, ctx) do
    [command | args] = metric.source["argv"]
    root = Common.repo_path(ctx)

    with {:ok, executable} <- executable(command, root),
         {:ok, body} <- execute(executable, args, root, environment(ref, window), ctx) do
      result = Ndjson.parse(body, metric, window, ctx)
      # A successful script measured this window, even if it found no units.
      coverage = Coverage.classify(metric.requires, Map.get(ctx, :data_facts, Enum.flat_map(result.observations, &Common.facts(&1.attrs))), window, window.start)
      %{result | coverage: Map.merge(Map.take(result.coverage, [:malformed_lines]), coverage)}
    else
      {:error, reason} -> Common.unavailable(reason)
    end
  rescue
    error -> Common.unavailable({:script_failed, Exception.message(error)})
  end

  defp executable(command, root) do
    if String.contains?(command, "/") do
      path = Path.expand(command, root)
      if Path.type(command) == :absolute, do: {:ok, path}, else: contained_executable(root, path)
    else
      case System.find_executable(command) do
        nil -> {:error, :executable_not_found}
        path -> {:ok, path}
      end
    end
  end

  defp contained_executable(root, path) do
    case Aiur.PathSafety.contained?(root, path) do
      {:ok, %{candidate: canonical}} -> {:ok, canonical}
      {:error, reason} -> {:error, reason}
    end
  end

  defp environment(ref, window) do
    names = @credential_names ++ AgentEnvironment.provider_credential_env_names() ++ AgentEnvironment.app_credential_env_names()
    scrubbed = Enum.map(names, &{String.to_charlist(&1), false})

    scrubbed ++
      AgentEnvironment.port_shell_startup_env() ++
      [
        {~c"AIUR_EXPERIMENT_WINDOW_START", String.to_charlist(DateTime.to_iso8601(window.start))},
        {~c"AIUR_EXPERIMENT_WINDOW_END", String.to_charlist(DateTime.to_iso8601(window.end))},
        {~c"AIUR_EXPERIMENT_METRIC", String.to_charlist(ref)}
      ]
  end

  defp execute(executable, args, root, env, ctx) do
    port = Port.open({:spawn_executable, String.to_charlist(executable)}, [:binary, :exit_status, :use_stdio, :stderr_to_stdout, {:args, args}, {:cd, root}, {:env, env}])
    deadline = System.monotonic_time(:millisecond) + timeout(ctx)
    cap = Map.get(ctx, :script_output_limit, @output_limit)

    try do
      collect(port, deadline, cap, [], 0)
    after
      cleanup(port)
    end
  end

  defp collect(port, deadline, cap, chunks, bytes) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining == 0 do
      {:error, :timeout}
    else
      receive do
        {^port, {:data, data}} ->
          if bytes + byte_size(data) > cap,
            do: {:error, :output_too_large},
            else: collect(port, deadline, cap, [data | chunks], bytes + byte_size(data))

        {^port, {:exit_status, 0}} ->
          {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

        {^port, {:exit_status, status}} ->
          {:error, {:exit_status, status, failure_line(chunks)}}
      after
        remaining -> {:error, :timeout}
      end
    end
  end

  # ponytail: stderr shares the bounded stream; separate descriptors if callers need exact stderr attribution.
  defp failure_line(chunks) do
    chunks |> Enum.reverse() |> IO.iodata_to_binary() |> String.split("\n", trim: true) |> Enum.find("script exited unsuccessfully", &(not match?({:ok, _}, Jason.decode(&1))))
  end

  defp cleanup(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        Aiur.ProcessTree.graceful_kill_tree(pid)
        Port.close(port)

      nil ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp timeout(ctx) do
    Map.get_lazy(ctx, :script_timeout_ms, fn ->
      case Aiur.Config.settings() do
        {:ok, %{experiments: %{script_timeout_ms: timeout}}} -> timeout
        _unavailable -> 60_000
      end
    end)
  end
end
