defmodule Aiur.GitHub.Quota.ShellObservations do
  @moduledoc false

  alias Aiur.Config
  alias Aiur.Workspace.Layout

  @primary_resources ~w(core graphql)
  @attribution_window_seconds 60 * 60
  @shell_refresh_interval_seconds 60
  @unattributed "unattributed"
  @agent_shell_caller "agent-shell:gh"
  # Written by the agent `gh` guard exactly once per stale period: by
  # `budget_acquire` when the ledger's schema trigger or version stamp refuses
  # the workspace broker's write, or by `budget_reconcile_response` when the
  # broker cannot reconcile 304s. This process turns it into one fleet alert per
  # workspace and rearms when the guard clears it (a refreshed broker
  # self-heals). See #2307.
  @stale_broker_marker "broker-reconcile-stale"
  @stale_broker_alert_topic "system.github.budget.broker_reconcile_stale"

  @spec refresh_shell_observations(map(), DateTime.t()) :: map()
  def refresh_shell_observations(%{shell_refreshed_at: %DateTime{} = refreshed_at} = state, now) do
    if DateTime.diff(now, refreshed_at, :second) < @shell_refresh_interval_seconds do
      state
    else
      load_shell_observations(state, now)
    end
  end

  def refresh_shell_observations(state, now), do: load_shell_observations(state, now)

  defp load_shell_observations(state, now) do
    %{state | shell_observations: shell_observations(state.shell_log_path, now), shell_refreshed_at: now}
  end

  defp shell_observations(nil, _now), do: []

  defp shell_observations(path, now) when is_binary(path) do
    cutoff = DateTime.add(now, -@attribution_window_seconds, :second)

    # `match_dot: true` is mandatory, not defensive: the log lives under each
    # workspace's `.aiur-runtime/`, and without it `Path.wildcard/1` refuses to
    # descend through a dot directory and silently matches nothing. Together
    # with the unexpanded `~` above, that left every agent `gh` call outside
    # attribution while the meter still billed them (#1805).
    [path <> ".1", path]
    |> Enum.flat_map(&Path.wildcard(&1, match_dot: true))
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

  # The resource column was added with cost-weighted attribution; rows written
  # before it are still valid and are read as core (see `observation_resource/1`).
  # The credential fingerprint and wrapper pid columns came with #2255 so the
  # agent record answers "which pool" and names the exact subprocess; rows
  # written before them simply have no value in those columns. An agent shell
  # cannot see what a GraphQL query cost, so its rows carry one point and are
  # marked estimated rather than silently counted as exact.
  @doc false
  @spec parse_shell_observation(String.t()) :: map() | nil
  def parse_shell_observation(line) do
    with [unix, consumer, direction | rest] <- line |> String.trim() |> String.split("\t"),
         {unix, ""} <- Integer.parse(unix),
         {:ok, observed_at} <- DateTime.from_unix(unix),
         true <- direction in ["read", "write"],
         true <- consumer == @unattributed or Regex.match?(~r/^ticket:\d+$/, consumer) do
      resource = shell_resource(rest)

      %{
        consumer: consumer,
        # Every row in this file was written by the agent `gh` wrapper, so the
        # call site is known exactly even though the ticket varies. The caller
        # names that call site (`agent-shell:gh pr view`) so `github-cost` can
        # rank the agent-side spend by gh subcommand rather than folding the
        # whole fleet into one `agent-shell:gh` row (#2299). A row written
        # before the call-site column falls back to the undifferentiated name.
        caller: shell_caller(rest),
        direction: String.to_existing_atom(direction),
        resource: resource,
        cost: 1,
        cost_source: if(resource == "graphql", do: :assumed, else: :reported),
        token_key: shell_column(rest, 2),
        pid: shell_pid(rest),
        observed_at: observed_at
      }
    else
      _invalid -> nil
    end
  end

  defp shell_resource([resource | _rest]) when resource in @primary_resources, do: resource
  defp shell_resource(_columns), do: "core"

  # The fifth column is the gh subcommand the guard recorded (`pr view`, `issue
  # list`, `api graphql`, ...). Rows that predate it have no call-site column.
  # The guard allowlists the value, and the reader re-checks it: a row that
  # somehow carries a character outside the safe set (a forged spend row, say)
  # is not named — it falls back to the undifferentiated caller so an injected
  # call site can never appear as its own ranked row.
  defp shell_caller([_resource, call_site | _]) when is_binary(call_site) and call_site != "" do
    if Regex.match?(~r/\A[a-zA-Z0-9 _-]+\z/, call_site),
      do: @agent_shell_caller <> " " <> call_site,
      else: @agent_shell_caller
  end

  defp shell_caller(_columns), do: @agent_shell_caller

  # The credential fingerprint (column 6) and the wrapper pid (column 7) ride
  # after the call site so a request is attributable to its pool and to the
  # exact subprocess that made it (#2255). Rows written before either column
  # degrade to nil.
  defp shell_column(columns, index), do: Enum.at(columns, index) |> shell_blank()

  defp shell_pid(columns) do
    case Enum.at(columns, 3) do
      pid when is_binary(pid) ->
        case Integer.parse(pid) do
          {value, ""} when value > 0 -> value
          _invalid -> nil
        end

      _missing ->
        nil
    end
  end

  defp shell_blank(nil), do: nil
  defp shell_blank(""), do: nil
  defp shell_blank(value), do: value

  # `Path.wildcard/1` does not expand a leading `~`, so a configured workspace
  # root written in tilde form matched nothing and every agent-shell call went
  # uncounted while the meter still billed them (#1805).
  @spec default_shell_log_path() :: String.t() | nil
  def default_shell_log_path do
    Config.workspace_root()
    |> Path.expand()
    |> Layout.issue_workspace_path("__github_quota_probe__")
    |> Path.dirname()
    |> Path.join("*/.aiur-runtime/github-quota/agent-requests.tsv")
  rescue
    _unavailable -> nil
  end

  # Same workspace glob as `default_shell_log_path/0`, matching the stale-broker
  # marker the agent `gh` guard writes next to its request log. `match_dot: true`
  # is mandatory for the same reason as the request log: the marker lives under
  # each workspace's dot-directory.
  @spec default_stale_broker_path() :: String.t() | nil
  def default_stale_broker_path do
    Config.workspace_root()
    |> Path.expand()
    |> Layout.issue_workspace_path("__github_quota_probe__")
    |> Path.dirname()
    |> Path.join("*/.aiur-runtime/github-quota/#{@stale_broker_marker}")
  rescue
    _unavailable -> nil
  end

  # A workspace running a broker that cannot coordinate with the current shared
  # ledger writes exactly one marker per stale period (the guard's own dedup:
  # it is written on the first structural acquire/reconcile failure and cleared
  # on recovery). Turn each distinct marker into one fleet alert, latch on the
  # marker path so a persistent marker does not re-alert on every refresh, and
  # rearm once the marker disappears (a refreshed broker has recovered).
  @spec refresh_stale_broker_alerts(map()) :: map()
  def refresh_stale_broker_alerts(state) do
    found = stale_broker_markers(state.stale_broker_path)
    seen = state.stale_broker_alerts

    seen =
      Enum.reduce(seen, seen, fn path, acc ->
        if Enum.member?(found, path), do: acc, else: MapSet.delete(acc, path)
      end)

    seen =
      Enum.reduce(found, seen, fn path, acc ->
        if MapSet.member?(acc, path) do
          acc
        else
          emit_stale_broker_alert(state, path)
          MapSet.put(acc, path)
        end
      end)

    %{state | stale_broker_alerts: seen}
  end

  # The marker list, not a MapSet: a MapSet built here and passed to
  # `MapSet.member?/2` at the call site would cross a function boundary with an
  # opaque type dialyzer cannot keep opaque (`call_without_opaque`). The seen-set
  # stays a MapSet inside `refresh_stale_broker_alerts/1`, where its opaque type
  # is tracked through the state field.
  @spec stale_broker_markers(String.t() | nil) :: [String.t()]
  defp stale_broker_markers(nil), do: []

  defp stale_broker_markers(path) when is_binary(path) do
    path |> Path.wildcard(match_dot: true)
  end

  defp emit_stale_broker_alert(state, marker_path) do
    consumer = marker_consumer(marker_path)
    workspace = marker_workspace(marker_path)

    message =
      "Agent workspace #{workspace} (#{consumer}) is running a GitHub budget broker that cannot reconcile 304 responses " <>
        "or write to the current shared ledger (stale broker); its budget accounting is disabled until the current broker is installed"

    state.emit_fun.(@stale_broker_alert_topic,
      message: message,
      reason: message,
      severity: "warning",
      needs_attention: true
    )

    :ok
  end

  defp marker_consumer(path) do
    case File.read(path) do
      {:ok, content} -> content |> String.split("\n", trim: true) |> List.first() || path
      {:error, _reason} -> path
    end
  end

  # `<workspace_root>/<workspace>/.aiur-runtime/github-quota/<marker>` — three
  # dirnames land on the workspace directory itself.
  defp marker_workspace(path) do
    path |> Path.dirname() |> Path.dirname() |> Path.dirname() |> Path.basename()
  end
end
