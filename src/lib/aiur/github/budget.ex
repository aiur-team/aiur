defmodule Aiur.GitHub.Budget do
  @moduledoc """
  Coordinates GitHub request admission across local Aiur instances.

  The broker is host-local and keyed by one-way token and consumer fingerprints. It shares
  rate ceilings, global and endpoint-family in-flight leases, jittered request
  starts, and rate-limit cooldowns with the agent `gh` wrapper.
  """

  alias Aiur.Config
  alias Aiur.GitHub.{GraphQLErrors, Transport}

  require Logger

  # Keep this source-tree path strictly compile-time-only so changes to the
  # broker invalidate the module. Runtime calls resolve `priv/` from the
  # installed application because release layouts do not retain this checkout.
  @broker_source_path Path.expand("../../../priv/github_budget.py", __DIR__)
  @external_resource @broker_source_path
  @default_max_inflight 4
  @default_max_inflight_per_endpoint 2
  @default_requests_per_minute 120
  @default_stagger_ms 75
  @default_timeout_ms 30_000
  @lease_grace_ms 5_000
  @broker_failure_backoff_ms 5_000
  @retry_floor_ms 5
  @command_cleanup_ms 25

  @type lease :: %{id: String.t(), token_key: String.t()}
  @type hold :: %{resource: String.t(), reset_at: DateTime.t(), reason: atom()}

  @spec enabled?(keyword()) :: boolean()
  def enabled?(opts \\ []) do
    Keyword.get(opts, :enabled?, Application.get_env(:aiur, :github_budget_enabled?, true))
  end

  @spec token_key(String.t()) :: String.t()
  def token_key(token) when is_binary(token) and token != "" do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end

  @spec token_key(String.t() | nil) :: String.t() | nil
  def token_key(_token), do: nil

  @spec state_dir(keyword()) :: Path.t()
  def state_dir(opts \\ []) do
    case Keyword.get(opts, :state_dir, Application.get_env(:aiur, :github_budget_dir)) do
      path when is_binary(path) and path != "" -> Path.expand(path)
      _ -> Path.join(System.user_home!(), ".aiur/github-budget")
    end
  end

  @spec database_path(keyword()) :: Path.t()
  def database_path(opts \\ []), do: Path.join(state_dir(opts), "budget.sqlite3")

  @spec ensure_state_dir(keyword()) :: :ok | {:error, term()}
  def ensure_state_dir(opts \\ []) do
    path = state_dir(opts)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, %File.Stat{type: type}} -> {:error, {:unsafe_budget_state_dir, path, type}}
      {:error, :enoent} -> create_state_dir(path)
      {:error, reason} -> {:error, {:budget_state_dir_unavailable, path, reason}}
    end
  end

  defp create_state_dir(path) do
    case File.mkdir_p(path) do
      :ok ->
        case File.lstat(path) do
          {:ok, %File.Stat{type: :directory}} -> :ok
          {:ok, %File.Stat{type: type}} -> {:error, {:unsafe_budget_state_dir, path, type}}
          {:error, reason} -> {:error, {:budget_state_dir_unavailable, path, reason}}
        end

      {:error, reason} ->
        {:error, {:budget_state_dir_unavailable, path, reason}}
    end
  end

  @spec broker_path() :: Path.t()
  def broker_path do
    :aiur
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("github_budget.py")
  end

  @doc "Configuration exported to the agent-side `gh` wrapper."
  @spec guard_settings(keyword()) :: map()
  def guard_settings(opts \\ []), do: settings(opts)

  @spec acquire(map(), keyword()) :: {:ok, lease()} | {:hold, hold()} | :bypass
  def acquire(request, opts \\ []) do
    with true <- enabled?(opts),
         token when is_binary(token) <- Map.get(request, :token),
         key when is_binary(key) <- token_key(token),
         python when is_binary(python) <- python_executable(opts) do
      do_acquire(request, key, python, opts, deadline(opts))
    else
      false -> :bypass
      _unavailable -> {:hold, hold(request, @broker_failure_backoff_ms)}
    end
  end

  @spec release(lease(), keyword()) :: :ok
  def release(lease, opts \\ [])

  def release(%{id: id, token_key: key}, opts) when is_binary(id) and is_binary(key) do
    _ = command(["release", "--lease-id", id], key, opts)
    :ok
  end

  def release(_lease, _opts), do: :ok

  @doc "Observes a response before releasing its lease so a rejection is global immediately."
  @spec observe(map(), {:ok, map()} | {:error, term()}, keyword()) :: :ok
  def observe(request, {:ok, %{} = response}, opts) do
    case active_token_key(request, opts) do
      key when is_binary(key) -> observe_response(key, request, response, opts)
      _unavailable -> :ok
    end
  end

  def observe(_request, _result, _opts), do: :ok

  @spec snapshot(String.t(), keyword()) :: map()
  def snapshot(token, opts \\ []) when is_binary(token) do
    key = token_key(token)

    case command(["snapshot"], key, opts) do
      {:ok, output} ->
        case Jason.decode(String.trim(output)) do
          {:ok, snapshot} -> atomize_snapshot(snapshot)
          _invalid -> %{cooldown_until_ms: 0, inflight: %{}, admissions: []}
        end

      _unavailable ->
        %{cooldown_until_ms: 0, inflight: %{}, admissions: []}
    end
  end

  @spec endpoint_family(map()) :: String.t()
  def endpoint_family(%{url: url}) when is_binary(url) do
    case URI.parse(url).path do
      "/graphql" -> "graphql"
      "/repos/" <> path -> path |> String.split("/", trim: true) |> Enum.at(2, "rest")
      _path -> "rest"
    end
  end

  def endpoint_family(_request), do: "rest"

  @spec request_resource(map()) :: String.t()
  def request_resource(%{url: url}) when is_binary(url) do
    if URI.parse(url).path == "/graphql", do: "graphql", else: "core"
  end

  def request_resource(_request), do: "core"

  defp do_acquire(request, key, python, opts, deadline_at) do
    command_opts = opts |> Keyword.put(:python, python) |> Keyword.put(:deadline_at, deadline_at)

    case command(acquire_args(request, opts), key, command_opts) do
      {:ok, "granted " <> id} ->
        grant_or_hold(String.trim(id), request, key)

      {:ok, "wait " <> milliseconds} ->
        retry_admission(request, key, python, opts, deadline_at, milliseconds)

      _unavailable ->
        {:hold, hold(request, @broker_failure_backoff_ms)}
    end
  end

  defp retry_admission(request, key, python, opts, deadline_at, milliseconds) do
    case Integer.parse(String.trim(milliseconds)) do
      {delay, ""} when delay > 0 -> retry_or_hold(request, key, python, opts, deadline_at, delay)
      _invalid -> {:hold, hold(request, @broker_failure_backoff_ms)}
    end
  end

  defp grant_or_hold(id, request, key) do
    if valid_lease_id?(id) do
      {:ok, %{id: id, token_key: key}}
    else
      {:hold, hold(request, @broker_failure_backoff_ms)}
    end
  end

  defp retry_or_hold(request, key, python, opts, deadline_at, delay) do
    if System.monotonic_time(:millisecond) + delay >= deadline_at do
      {:hold, hold(request, delay)}
    else
      Process.sleep(max(delay, @retry_floor_ms))
      do_acquire(request, key, python, opts, deadline_at)
    end
  end

  defp acquire_args(request, opts) do
    settings = settings(opts)

    [
      "acquire",
      "--resource",
      request_resource(request),
      "--consumer-key",
      consumer_key(opts),
      "--endpoint-family",
      endpoint_family(request),
      "--max-inflight",
      Integer.to_string(settings.max_inflight),
      "--max-inflight-per-endpoint",
      Integer.to_string(settings.max_inflight_per_endpoint),
      "--requests-per-minute",
      Integer.to_string(settings.requests_per_minute),
      "--stagger-ms",
      Integer.to_string(settings.stagger_ms),
      "--lease-ttl-ms",
      Integer.to_string(settings.lease_ttl_ms)
    ]
  end

  defp hold(key, scope, resource, delay_ms, opts) do
    _ =
      command(
        ["hold", "--scope", Atom.to_string(scope), "--resource", resource, "--delay-ms", Integer.to_string(delay_ms)],
        key,
        opts
      )

    :ok
  end

  defp command(args, key, opts) when is_binary(key) do
    with true <- enabled?(opts),
         python when is_binary(python) <- Keyword.get(opts, :python, python_executable(opts)) do
      command_args = [broker_path() | args] ++ ["--db", database_path(opts), "--token-key", key]

      case port_command(python, command_args, command_deadline(opts)) do
        {:ok, output, 0} -> {:ok, output}
        {:ok, output, status} -> broker_unavailable(status, output)
        {:error, reason} -> broker_unavailable(:exception, inspect(reason))
        :timeout -> broker_unavailable(:timeout, "deadline exceeded")
      end
    else
      _unavailable -> :bypass
    end
  rescue
    error -> broker_unavailable(:exception, Exception.message(error))
  end

  defp port_command(executable, args, deadline_at) do
    remaining_ms = max(deadline_at - System.monotonic_time(:millisecond), 0)

    if remaining_ms == 0 do
      :timeout
    else
      caller = self()
      result_ref = make_ref()

      {guardian, guardian_ref} =
        spawn_monitor(fn ->
          result = owned_port_command(caller, executable, args, deadline_at)
          send(caller, {result_ref, self(), result})
        end)

      receive do
        {^result_ref, ^guardian, result} ->
          Process.demonitor(guardian_ref, [:flush])
          result

        {:DOWN, ^guardian_ref, :process, ^guardian, reason} ->
          {:error, reason}
      after
        remaining_ms ->
          Process.exit(guardian, :kill)
          :timeout
      end
    end
  end

  defp owned_port_command(caller, executable, args, deadline_at) do
    caller_ref = Process.monitor(caller)

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [:binary, :exit_status, :stderr_to_stdout, :use_stdio, args: Enum.map(args, &String.to_charlist/1)]
      )

    await_port(port, caller, caller_ref, deadline_at, [])
  end

  defp await_port(port, caller, caller_ref, deadline_at, output) do
    remaining_ms = max(deadline_at - System.monotonic_time(:millisecond) - @command_cleanup_ms, 0)

    receive do
      {^port, {:data, data}} ->
        await_port(port, caller, caller_ref, deadline_at, [data | output])

      {^port, {:exit_status, status}} ->
        Process.demonitor(caller_ref, [:flush])
        {:ok, output |> Enum.reverse() |> IO.iodata_to_binary(), status}

      {:DOWN, ^caller_ref, :process, ^caller, _reason} ->
        terminate_port(port, min(deadline_at, System.monotonic_time(:millisecond) + @command_cleanup_ms))
        :timeout
    after
      remaining_ms ->
        Process.demonitor(caller_ref, [:flush])
        terminate_port(port, deadline_at)
        :timeout
    end
  end

  defp terminate_port(port, deadline_at) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
      nil -> :ok
    end

    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      max(deadline_at - System.monotonic_time(:millisecond), 0) -> :ok
    end

    if Port.info(port), do: Port.close(port)
    flush_port(port)
  rescue
    ArgumentError -> :ok
  end

  defp flush_port(port) do
    receive do
      {^port, _message} -> flush_port(port)
    after
      0 -> :ok
    end
  end

  defp broker_unavailable(status, output) do
    Logger.warning("github_budget_broker_unavailable status=#{inspect(status)} output=#{inspect(String.trim(output))}")
    :bypass
  end

  defp python_executable(opts), do: Keyword.get(opts, :python, System.find_executable("python3"))

  defp settings(opts) do
    github = github_settings(opts)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    %{
      max_inflight: positive(Keyword.get(opts, :max_inflight, Map.get(github, :max_inflight, @default_max_inflight)), @default_max_inflight),
      max_inflight_per_endpoint:
        positive(
          Keyword.get(opts, :max_inflight_per_endpoint, Map.get(github, :max_inflight_per_endpoint, @default_max_inflight_per_endpoint)),
          @default_max_inflight_per_endpoint
        ),
      requests_per_minute:
        positive(
          Keyword.get(opts, :requests_per_minute, Map.get(github, :requests_per_minute, @default_requests_per_minute)),
          @default_requests_per_minute
        ),
      stagger_ms: nonnegative(Keyword.get(opts, :stagger_ms, Map.get(github, :stagger_ms, @default_stagger_ms)), @default_stagger_ms),
      lease_ttl_ms: positive(timeout_ms, @default_timeout_ms) * 2 + @lease_grace_ms
    }
  end

  defp github_settings(opts) do
    case Keyword.get(opts, :github_settings, Application.get_env(:aiur, :github_budget_settings_override)) do
      %{max_inflight: _value} = settings ->
        settings

      _ ->
        case Config.settings() do
          {:ok, %{tracker: %{github: settings}}} -> Map.from_struct(settings)
          _unavailable -> %{}
        end
    end
  rescue
    _unavailable -> %{}
  end

  defp deadline(opts), do: System.monotonic_time(:millisecond) + positive(Keyword.get(opts, :timeout_ms, @default_timeout_ms), @default_timeout_ms)

  defp command_deadline(opts) do
    Keyword.get_lazy(opts, :deadline_at, fn -> deadline(opts) end)
  end

  defp consumer_key(opts) do
    identity =
      Keyword.get(opts, :consumer_key) ||
        System.get_env("AIUR_GITHUB_BUDGET_CONSUMER") ||
        "daemon:#{node()}"

    token_key(identity)
  end

  defp hold(request, delay_ms) do
    %{resource: request_resource(request), reset_at: DateTime.add(DateTime.utc_now(), ceil(delay_ms / 1_000), :second), reason: :shared_budget}
  end

  defp active_token_key(request, opts) do
    if enabled?(opts), do: token_key(Map.get(request, :token))
  end

  defp observe_response(key, request, response, opts) do
    headers = Map.get(response, :headers, [])
    resource = response_resource(headers, request)

    case limit_hold(response, headers) do
      {:resource, delay} -> hold(key, :resource, resource, delay, opts)
      {:token, delay} -> hold(key, :token, resource, delay, opts)
      :none -> :ok
    end
  end

  defp limit_hold(response, headers) do
    cond do
      remaining(headers) == 0 -> primary_limit_hold(headers, response)
      Map.get(response, :status) in [403, 429] and secondary_limit?(response) -> {:token, retry_after_ms(response)}
      true -> :none
    end
  end

  defp primary_limit_hold(headers, response) do
    case reset_after_ms(headers) do
      delay when is_integer(delay) and delay > 0 -> {:resource, delay}
      _missing -> {:token, retry_after_ms(response)}
    end
  end

  defp secondary_limit?(response) do
    GraphQLErrors.rate_limited_response?(response, :unknown) and remaining(Map.get(response, :headers, [])) != 0
  end

  defp retry_after_ms(response) do
    case GraphQLErrors.retry_after(response) do
      seconds when is_integer(seconds) and seconds > 0 -> min(seconds * 1_000, 60 * 60 * 1_000)
      _missing -> 60 * 1_000
    end
  end

  defp reset_after_ms(headers) do
    headers
    |> Transport.header("x-ratelimit-reset")
    |> reset_delay_ms()
  end

  defp reset_delay_ms(value) when is_binary(value) do
    case Integer.parse(value) do
      {reset, ""} -> reset_delay_ms(reset)
      _invalid -> nil
    end
  end

  defp reset_delay_ms(value) when is_integer(value), do: max(value * 1_000 - System.system_time(:millisecond), 1)
  defp reset_delay_ms(_missing), do: nil

  defp remaining(headers) do
    case Transport.header(headers, "x-ratelimit-remaining") do
      value when is_binary(value) -> parse_integer(value)
      value when is_integer(value) -> value
      _missing -> nil
    end
  end

  defp response_resource(headers, request) do
    case Transport.header(headers, "x-ratelimit-resource") do
      resource when resource in ["core", "graphql"] -> resource
      _other -> request_resource(request)
    end
  end

  defp parse_integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _invalid -> nil
    end
  end

  defp atomize_snapshot(%{"cooldown_until_ms" => cooldown, "inflight" => inflight, "admissions" => admissions}) do
    %{
      cooldown_until_ms: cooldown,
      inflight: inflight,
      admissions: Enum.map(admissions, &%{endpoint_family: &1["endpoint_family"], admitted_at_ms: &1["admitted_at_ms"]})
    }
  end

  defp atomize_snapshot(_snapshot), do: %{cooldown_until_ms: 0, inflight: %{}, admissions: []}

  defp valid_lease_id?(id), do: String.match?(id, ~r/\A[a-f0-9]{32}\z/)

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default
  defp nonnegative(value, _default) when is_integer(value) and value >= 0, do: value
  defp nonnegative(_value, default), do: default
end
