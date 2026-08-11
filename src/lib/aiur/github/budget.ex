defmodule Aiur.GitHub.Budget do
  @moduledoc """
  Coordinates GitHub request admission across local Aiur instances.

  The broker is host-local and keyed by a one-way token fingerprint. It shares
  rate ceilings, global and endpoint-family in-flight leases, jittered request
  starts, and rate-limit cooldowns with the agent `gh` wrapper.
  """

  alias Aiur.Config
  alias Aiur.GitHub.{GraphQLErrors, Transport}

  require Logger

  @broker_path Path.expand("../../../priv/github_budget.py", __DIR__)
  @external_resource @broker_path
  @default_max_inflight 4
  @default_max_inflight_per_endpoint 2
  @default_requests_per_minute 120
  @default_stagger_ms 75
  @default_timeout_ms 30_000
  @lease_grace_ms 5_000
  @retry_floor_ms 5

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

  @spec broker_path() :: Path.t()
  def broker_path, do: @broker_path

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
      _unavailable -> :bypass
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
    with true <- enabled?(opts),
         token when is_binary(token) <- Map.get(request, :token),
         key when is_binary(key) <- token_key(token) do
      headers = Map.get(response, :headers, [])
      resource = response_resource(headers, request)

      cond do
        remaining(headers) == 0 ->
          with reset when is_integer(reset) and reset > 0 <- reset_after_ms(headers) do
            hold(key, :resource, resource, reset, opts)
          else
            _missing -> :ok
          end

        Map.get(response, :status) in [403, 429] and secondary_limit?(response) ->
          hold(key, :token, resource, retry_after_ms(response), opts)

        true ->
          :ok
      end
    else
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
    case command(acquire_args(request, opts), key, Keyword.put(opts, :python, python)) do
      {:ok, "granted " <> id} ->
        {:ok, %{id: String.trim(id), token_key: key}}

      {:ok, "wait " <> milliseconds} ->
        case Integer.parse(String.trim(milliseconds)) do
          {delay, ""} when delay > 0 ->
            if System.monotonic_time(:millisecond) + delay >= deadline_at do
              {:hold, hold(request, delay)}
            else
              Process.sleep(max(delay, @retry_floor_ms))
              do_acquire(request, key, python, opts, deadline_at)
            end

          _invalid ->
            :bypass
        end

      _unavailable ->
        :bypass
    end
  end

  defp acquire_args(request, opts) do
    settings = settings(opts)

    [
      "acquire",
      "--resource",
      request_resource(request),
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
      {output, status} =
        System.cmd(python, [broker_path() | args] ++ ["--db", database_path(opts), "--token-key", key], stderr_to_stdout: true)

      if status == 0, do: {:ok, output}, else: broker_unavailable(status, output)
    else
      _unavailable -> :bypass
    end
  rescue
    error -> broker_unavailable(:exception, Exception.message(error))
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
      lease_ttl_ms: positive(timeout_ms, @default_timeout_ms) + @lease_grace_ms
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

  defp hold(request, delay_ms) do
    %{resource: request_resource(request), reset_at: DateTime.add(DateTime.utc_now(), ceil(delay_ms / 1_000), :second), reason: :shared_budget}
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
    case Transport.header(headers, "x-ratelimit-reset") do
      value when is_binary(value) ->
        with {reset, ""} <- Integer.parse(value) do
          max(reset * 1_000 - System.system_time(:millisecond), 1)
        else
          _invalid -> nil
        end

      value when is_integer(value) ->
        max(value * 1_000 - System.system_time(:millisecond), 1)

      _missing ->
        nil
    end
  end

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

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default
  defp nonnegative(value, _default) when is_integer(value) and value >= 0, do: value
  defp nonnegative(_value, default), do: default
end
