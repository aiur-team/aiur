defmodule Aiur.GitHub.Quota do
  @moduledoc """
  Fleet-wide view of the primary GitHub API budgets used by Aiur.

  GitHub returns an authoritative budget snapshot on every API response. This
  process retains those snapshots, rejects requests against an exhausted
  resource until its reset, sheds new dispatch at the low-water floor, and
  keeps coarse rolling attribution for the shared credential.
  """

  use GenServer

  alias Aiur.{Alerts, Config}
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.GitHub.Transport
  alias Aiur.RepoBase
  alias Aiur.Workspace.Layout

  @primary_resources ~w(core graphql)
  @low_water_percent 10.0
  @attribution_window_seconds 60 * 60
  @refresh_interval_ms 60_000
  @shell_refresh_interval_seconds 60

  @unknown_snapshot %{state: :unknown, windows: %{}, attribution: []}

  @type request :: map()
  @type hold :: %{resource: String.t(), remaining: non_neg_integer(), limit: pos_integer(), reset_at: DateTime.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @spec observe(GenServer.server(), request(), {:ok, map()} | {:error, term()}) :: :ok
  def observe(server \\ __MODULE__, request, result) do
    GenServer.cast(server, {:observe, request, result})
  catch
    :exit, _reason -> :ok
  end

  @spec snapshot(GenServer.server()) :: map()
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  catch
    :exit, _reason -> @unknown_snapshot
  end

  @spec preflight(GenServer.server(), request()) :: :ok | {:hold, hold()}
  def preflight(server \\ __MODULE__, request) do
    GenServer.call(server, {:preflight, request})
  catch
    :exit, _reason -> :ok
  end

  @spec dispatch_status(GenServer.server()) :: :available | {:hold, hold()}
  def dispatch_status(server \\ __MODULE__) do
    GenServer.call(server, :dispatch_status)
  catch
    :exit, _reason -> :available
  end

  @impl true
  def init(opts) do
    refresh? = Keyword.get(opts, :refresh?, Application.get_env(:aiur, :github_quota_refresh?, true))

    state = %{
      windows: %{},
      observations: [],
      shell_observations: [],
      shell_refreshed_at: nil,
      alerts: MapSet.new(),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      emit_fun: Keyword.get(opts, :emit_fun, &Alerts.emit_system/2),
      shell_log_path: Keyword.get_lazy(opts, :shell_log_path, &default_shell_log_path/0),
      hold_dir: Keyword.get_lazy(opts, :hold_dir, &default_hold_dir/0),
      refresh_fun: Keyword.get(opts, :refresh_fun, &refresh_from_github/0),
      refresh_interval_ms: Keyword.get(opts, :refresh_interval_ms, @refresh_interval_ms),
      refresh_ref: nil
    }

    if refresh?, do: Process.send_after(self(), :refresh, 0)
    {:ok, state}
  end

  @impl true
  def handle_cast({:observe, request, result}, state) do
    now = state.clock.()

    state =
      state
      |> observe_response(result, now)
      |> attribute_request(request, result, now)
      |> maybe_alert()

    {:noreply, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    now = state.clock.()
    state = state |> prune_observations(now) |> refresh_shell_observations(now)

    snapshot = %{
      state: if(map_size(state.windows) == 0, do: :unknown, else: :observed),
      windows: Map.new(state.windows, fn {resource, window} -> {resource, present_window(window)} end),
      attribution: summarize_attribution(state.observations ++ state.shell_observations)
    }

    {:reply, snapshot, state}
  end

  def handle_call({:preflight, request}, _from, state) do
    reply =
      if rate_limit_endpoint?(request) do
        :ok
      else
        case resource_status(state, request_resource(request), 0.0) do
          :available -> :ok
          hold -> hold
        end
      end

    {:reply, reply, state}
  end

  def handle_call(:dispatch_status, _from, state) do
    status =
      Enum.find_value(@primary_resources, :available, fn resource ->
        case resource_status(state, resource, @low_water_percent) do
          :available -> nil
          hold -> hold
        end
      end)

    {:reply, status, state}
  end

  @impl true
  def handle_info(:refresh, %{refresh_ref: nil} = state) do
    refresh_fun = state.refresh_fun
    {_pid, ref} = spawn_monitor(refresh_fun)
    {:noreply, %{state | refresh_ref: ref}}
  end

  def handle_info(:refresh, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{refresh_ref: ref} = state) do
    Process.send_after(self(), :refresh, state.refresh_interval_ms)
    {:noreply, %{state | refresh_ref: nil}}
  end

  defp observe_response(state, {:ok, %{body: %{"resources" => resources}}}, now) when is_map(resources) do
    Enum.reduce(@primary_resources, state, fn resource, acc ->
      case Map.get(resources, resource) do
        %{} = values -> put_window_from_values(acc, resource, values, now)
        _missing -> acc
      end
    end)
  end

  defp observe_response(state, {:ok, response}, now) when is_map(response) do
    headers = Map.get(response, :headers, [])
    resource = Transport.header(headers, "x-ratelimit-resource")

    if resource in @primary_resources do
      values = %{
        "limit" => Transport.header(headers, "x-ratelimit-limit"),
        "remaining" => Transport.header(headers, "x-ratelimit-remaining"),
        "reset" => Transport.header(headers, "x-ratelimit-reset")
      }

      put_window_from_values(state, resource, values, now)
    else
      state
    end
  end

  defp observe_response(state, _result, _now), do: state

  defp put_window_from_values(state, resource, values, now) do
    with {:ok, limit} <- integer_value(Map.get(values, "limit")),
         true <- limit > 0,
         {:ok, remaining} <- integer_value(Map.get(values, "remaining")),
         {:ok, reset_unix} <- integer_value(Map.get(values, "reset")),
         {:ok, reset_at} <- DateTime.from_unix(reset_unix) do
      remaining = remaining |> max(0) |> min(limit)

      window = %{
        resource: resource,
        limit: limit,
        remaining: remaining,
        reset_at: reset_at,
        observed_at: now
      }

      state
      |> Map.put(:windows, Map.put(state.windows, resource, window))
      |> reconcile_resource_alerts(resource, window)
      |> sync_hold_file(resource, window)
    else
      _invalid -> state
    end
  end

  defp maybe_alert(state) do
    Enum.reduce(state.windows, state, fn {resource, window}, acc ->
      cond do
        window.remaining == 0 -> emit_threshold_alert(acc, resource, window, :exhausted)
        below_floor?(window, @low_water_percent) -> emit_threshold_alert(acc, resource, window, :low)
        true -> acc
      end
    end)
  end

  defp emit_threshold_alert(state, resource, window, threshold) do
    key = {resource, window.reset_at, threshold}

    if MapSet.member?(state.alerts, key) do
      state
    else
      topic = alert_topic(resource, threshold)
      reset = DateTime.to_iso8601(window.reset_at)
      message = "GitHub #{resource} quota has #{window.remaining} of #{window.limit} requests remaining; resets at #{reset}"

      state.emit_fun.(topic,
        message: message,
        reason: message,
        severity: if(threshold == :exhausted, do: "critical", else: "warning"),
        needs_attention: true
      )

      %{state | alerts: MapSet.put(state.alerts, key)}
    end
  end

  defp resource_status(state, resource, floor_percent) do
    case Map.get(state.windows, resource) do
      %{reset_at: reset_at} = window ->
        now = state.clock.()

        if DateTime.compare(now, reset_at) == :lt and below_floor?(window, floor_percent) do
          {:hold, Map.take(window, [:resource, :remaining, :limit, :reset_at])}
        else
          :available
        end

      nil ->
        :available
    end
  end

  defp attribute_request(state, request, {:ok, %{status: status}}, now) when is_integer(status) do
    if rate_limit_endpoint?(request) do
      state
    else
      observation = %{consumer: request_consumer(request), direction: request_direction(request), observed_at: now}
      prune_observations(%{state | observations: [observation | state.observations]}, now)
    end
  end

  defp attribute_request(state, _request, _result, _now), do: state

  defp prune_observations(state, now) do
    cutoff = DateTime.add(now, -@attribution_window_seconds, :second)
    %{state | observations: Enum.filter(state.observations, &(DateTime.compare(&1.observed_at, cutoff) != :lt))}
  end

  defp summarize_attribution(observations) do
    observations
    |> Enum.group_by(& &1.consumer)
    |> Enum.map(fn {consumer, entries} ->
      reads = Enum.count(entries, &(&1.direction == :read))
      writes = length(entries) - reads
      %{consumer: consumer, reads: reads, writes: writes, total: length(entries)}
    end)
    |> Enum.sort_by(&{-&1.total, &1.consumer})
  end

  defp refresh_shell_observations(%{shell_refreshed_at: %DateTime{} = refreshed_at} = state, now) do
    if DateTime.diff(now, refreshed_at, :second) < @shell_refresh_interval_seconds do
      state
    else
      load_shell_observations(state, now)
    end
  end

  defp refresh_shell_observations(state, now), do: load_shell_observations(state, now)

  defp load_shell_observations(state, now) do
    %{state | shell_observations: shell_observations(state.shell_log_path, now), shell_refreshed_at: now}
  end

  defp shell_observations(nil, _now), do: []

  defp shell_observations(path, now) when is_binary(path) do
    cutoff = DateTime.add(now, -@attribution_window_seconds, :second)

    [path <> ".1", path]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Stream.flat_map(&shell_file_lines/1)
    |> Stream.map(&parse_shell_observation/1)
    |> Stream.reject(&is_nil/1)
    |> Enum.filter(fn observation ->
      DateTime.compare(observation.observed_at, cutoff) != :lt and DateTime.compare(observation.observed_at, now) != :gt
    end)
  rescue
    _unavailable -> []
  end

  defp shell_file_lines(path) do
    case File.read(path) do
      {:ok, contents} -> String.split(contents, "\n", trim: true)
      {:error, _reason} -> []
    end
  end

  defp default_hold_dir do
    case Aiur.GitHub.Config.repo() do
      repo when is_binary(repo) and repo != "" ->
        repo
        |> RepoBase.repo_path()
        |> Path.join("github-quota")

      _unconfigured ->
        nil
    end
  rescue
    _unavailable -> nil
  end

  defp parse_shell_observation(line) do
    with [unix, consumer, direction] <- line |> String.trim() |> String.split("\t"),
         {unix, ""} <- Integer.parse(unix),
         {:ok, observed_at} <- DateTime.from_unix(unix),
         true <- direction in ["read", "write"],
         true <- consumer == "unattributed" or Regex.match?(~r/^ticket:\d+$/, consumer) do
      %{consumer: consumer, direction: String.to_existing_atom(direction), observed_at: observed_at}
    else
      _invalid -> nil
    end
  end

  defp default_shell_log_path do
    Config.workspace_root()
    |> Layout.issue_workspace_path("__github_quota_probe__")
    |> Path.dirname()
    |> Path.join("*/.aiur-runtime/github-quota/agent-requests.tsv")
  rescue
    _unavailable -> nil
  end

  defp refresh_from_github do
    with token when is_binary(token) and token != "" <- GitHubConfig.token() do
      Transport.default_request_fun(%{
        method: :get,
        url: "https://api.github.com/rate_limit",
        token: token,
        timeout_ms: 10_000
      })
    end

    :ok
  rescue
    _unavailable -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp request_resource(%{url: url}) when is_binary(url) do
    if URI.parse(url).path == "/graphql", do: "graphql", else: "core"
  end

  defp request_resource(_request), do: "core"

  defp request_direction(%{method: :post, url: url, body: %{"query" => query}}) when is_binary(url) and is_binary(query) do
    if URI.parse(url).path == "/graphql" and Regex.match?(~r/^\s*mutation\b/i, query), do: :write, else: :read
  end

  defp request_direction(%{method: method}) when method in [:get, :head], do: :read
  defp request_direction(_request), do: :write

  defp request_consumer(%{consumer: consumer}) when is_binary(consumer) and consumer != "", do: consumer

  defp request_consumer(request) do
    ticket_number_from_url(request) || ticket_number_from_variables(request) || "unattributed"
  end

  defp ticket_number_from_url(%{url: url}) when is_binary(url) do
    case Regex.run(~r{/(?:issues|pulls)/(\d+)(?:/|$)}, URI.parse(url).path || "") do
      [_, number] -> "ticket:#{number}"
      _no_ticket -> nil
    end
  end

  defp ticket_number_from_url(_request), do: nil

  defp ticket_number_from_variables(%{body: %{"variables" => variables}}) when is_map(variables) do
    variables
    |> find_ticket_number()
    |> case do
      nil -> nil
      number -> "ticket:#{number}"
    end
  end

  defp ticket_number_from_variables(_request), do: nil

  defp find_ticket_number(map) when is_map(map) do
    direct = Enum.find_value(~w(number issue_number pull_number), fn key -> valid_ticket_number(Map.get(map, key) || Map.get(map, String.to_atom(key))) end)
    direct || Enum.find_value(Map.values(map), &find_ticket_number/1)
  end

  defp find_ticket_number(list) when is_list(list), do: Enum.find_value(list, &find_ticket_number/1)
  defp find_ticket_number(_value), do: nil

  defp valid_ticket_number(number) when is_integer(number) and number > 0, do: number

  defp valid_ticket_number(number) when is_binary(number) do
    case Integer.parse(number) do
      {parsed, ""} when parsed > 0 -> parsed
      _invalid -> nil
    end
  end

  defp valid_ticket_number(_number), do: nil

  defp present_window(window) do
    used = window.limit - window.remaining

    Map.merge(window, %{
      remaining_percent: percent(window.remaining, window.limit),
      used: used,
      used_percent: percent(used, window.limit)
    })
  end

  defp rate_limit_endpoint?(%{url: url}) when is_binary(url), do: URI.parse(url).path == "/rate_limit"
  defp rate_limit_endpoint?(_request), do: false

  defp integer_value(value) when is_integer(value), do: {:ok, value}

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> {:ok, parsed}
      _invalid -> :error
    end
  end

  defp integer_value(_value), do: :error

  defp percent(value, limit), do: Float.round(value / limit * 100, 1)

  defp below_floor?(window, floor_percent), do: window.remaining * 100 <= window.limit * floor_percent

  defp reconcile_resource_alerts(state, resource, window) do
    Enum.reduce(state.alerts, state, fn
      {^resource, reset_at, threshold} = key, acc ->
        if DateTime.compare(reset_at, window.reset_at) == :eq and threshold_active?(window, threshold) do
          acc
        else
          message = "GitHub #{resource} #{threshold} quota alert cleared; #{window.remaining} of #{window.limit} requests remain"

          acc.emit_fun.(alert_topic(resource, threshold) <> ".resolved",
            message: message,
            reason: message,
            severity: "info",
            needs_attention: false
          )

          %{acc | alerts: MapSet.delete(acc.alerts, key)}
        end

      _other_key, acc ->
        acc
    end)
  end

  defp threshold_active?(%{remaining: 0}, :exhausted), do: true
  defp threshold_active?(%{remaining: remaining} = window, :low) when remaining > 0, do: below_floor?(window, @low_water_percent)
  defp threshold_active?(_window, _threshold), do: false

  defp alert_topic(resource, threshold), do: "system.github.quota.#{resource}.#{threshold}"

  defp sync_hold_file(%{hold_dir: nil} = state, _resource, _window), do: state

  defp sync_hold_file(state, resource, window) do
    path = Path.join(state.hold_dir, "#{resource}-hold")

    if window.remaining == 0 and DateTime.compare(state.clock.(), window.reset_at) == :lt do
      :ok = File.mkdir_p(state.hold_dir)
      temporary = path <> ".#{System.unique_integer([:positive])}.tmp"
      :ok = File.write(temporary, Integer.to_string(DateTime.to_unix(window.reset_at)) <> "\n")
      :ok = File.rename(temporary, path)
    else
      _ = File.rm(path)
    end

    state
  rescue
    _unavailable -> state
  end
end
