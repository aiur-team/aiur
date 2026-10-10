defmodule Aiur.CodingAgent.HeadroomDispatch do
  @moduledoc """
  Claim-time selection for `agent.account_selection: headroom` (#3960).

  `Aiur.CodingAgent.select_for_dispatch/2` calls `select/3` when the policy is
  on. This module builds the candidate set, gathers one usage reading per
  candidate, and hands both to the pure ranker `Aiur.Accounts.Headroom`.

  ## Candidates

  * Routes: the complexity level's `agent.routing` value. A list value names
    every route allowed for that level; a single string allows one route,
    which is the behaviour of a routing table before this policy. A level with
    no routing entry uses `agent.priority`.
  * Each route is then filtered by the caller's existing gates (dispatchable
    backend, route credentials, peak pricing), and expanded into one candidate
    per account in `agent.accounts[<backend>]`. A backend with no listed
    accounts is one implicit account.
  * A `model:` label (or a backend that the rate-limit fallback pinned) still
    pins the backend. Headroom then only picks the account.

  ## Readings

  * A backend that the usage ledger (`model-usage.json`) marks as limited is
    exhausted.
  * A named account uses the daemon's polled per-account meter
    (`Aiur.Accounts.UsageReadings`). Today the daemon polls Claude accounts.
  * A backend with one account uses the ledger's usage windows. Codex writes
    these from `account/rateLimits/read` at session start and from the
    background probe, so Codex competes with real numbers. With two or more
    accounts on one backend the ledger cannot tell them apart, so those
    accounts read as unknown.
  * Anything else is unknown. Unknown is never shown as a number.
  """

  require Logger

  alias Aiur.Accounts
  alias Aiur.Accounts.{Headroom, UsageReadings}
  alias Aiur.{CodingAgent, Config, Issue, ModelAvailability}
  alias Aiur.Config.RoutingValue

  @policy "headroom"
  @ledger_windows [{"hourly", "short"}, {"weekly", "weekly"}, {"monthly", "monthly"}]

  @doc "Whether `agent.account_selection` is `headroom`. Pass `account_selection:` to override."
  @spec enabled?(keyword()) :: boolean()
  def enabled?(opts \\ []), do: Keyword.get_lazy(opts, :account_selection, &configured_selection/0) == @policy

  @doc """
  Chooses the backend, route and account for one claim.

  `eligible` applies the caller's route gates to a list of routes. Returns the
  issue with `selected_backend`, `selected_model`, `selected_account` and
  `dispatch_selection` set, or `{:all_limited, routes}` when every candidate
  is exhausted. A pinned backend is never refused here.
  """
  @spec select(Issue.t(), ([String.t()] -> [String.t()]), keyword()) :: {:ok, Issue.t()} | {:all_limited, [String.t()]}
  def select(%Issue{} = issue, eligible, opts \\ []) when is_function(eligible, 1) do
    case pinned_backend(issue, opts) do
      nil -> select_route(issue, eligible, opts)
      backend -> select_pinned_account(issue, backend, opts)
    end
  end

  @doc """
  Routes allowed for a complexity level, or `nil` when routing does not name
  the level. A string value is a one-route list.
  """
  @spec level_routes(Issue.t(), keyword()) :: [String.t()] | nil
  def level_routes(%Issue{} = issue, opts \\ []) do
    with level when is_integer(level) <- CodingAgent.complexity_level(issue),
         [_ | _] = routes <- Map.get(routing_candidates(opts), level) do
      routes
    else
      _ -> nil
    end
  end

  @doc """
  Every routing level's allowed routes as lists. Reads the `routing_candidates`
  that config validation derives from list values, and falls back to the
  single-string routing table.
  """
  @spec routing_candidates(keyword()) :: %{optional(pos_integer()) => [String.t()]}
  def routing_candidates(opts \\ []), do: Keyword.get_lazy(opts, :routing_candidates, &configured_routing_candidates/0)

  @doc """
  Runner options with the account a headroom dispatch chose as
  `account_name`. An `account_name` already present (a rate-limit account
  move) wins. The account applies only when `session_backend` is the backend
  that was scored.
  """
  @spec account_opts(Issue.t(), String.t(), keyword()) :: keyword()
  def account_opts(%Issue{dispatch_selection: %{backend: backend, account: account}}, session_backend, opts)
      when is_binary(account) and is_binary(backend) do
    if account_backend(backend) == account_backend(session_backend), do: Keyword.put_new(opts, :account_name, account), else: opts
  end

  def account_opts(_issue, _session_backend, opts), do: opts

  @doc """
  Puts the headroom summary on the session options as
  `account_selection_reason`, so `aiur status` and `aiur agents` show the
  choice and every alternative's score, also for a backend with one implicit
  account.
  """
  @spec put_selection_reason(keyword(), Issue.t()) :: keyword()
  def put_selection_reason(session_opts, %Issue{dispatch_selection: %{summary: summary}}) when is_binary(summary),
    do: Keyword.put(session_opts, :account_selection_reason, summary)

  def put_selection_reason(session_opts, _issue), do: session_opts

  @doc """
  The usage-ledger reading for a backend, in the ranker's reading shape, or
  `nil` when the ledger has no current usage window for it.

  The ledger is written only when a session of that backend starts or reports
  its limits, or when the background probe runs (only while every candidate is
  limited). A backend that is not getting work can therefore hold a reading
  that is days old, and usage only rises inside a window. A reading older than
  `agent.headroom_reading_max_age_seconds` is returned as `stale: true`, which
  scores as unknown. `age_seconds` carries the age either way.
  """
  @spec backend_reading(String.t(), keyword()) :: Headroom.reading()
  def backend_reading(backend, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    entry = get_in(ledger_state(opts), ["backends", ModelAvailability.backend_key(backend)]) || %{}

    windows =
      for {key, label} <- @ledger_windows, used = window_used(Map.get(entry, key), now), into: %{}, do: {label, used}

    if windows == %{}, do: nil, else: with_age(%{windows: windows, source: "ledger"}, parse_time(entry["observed_at"]), now, opts)
  end

  @doc "Readings older than this many seconds score as unknown. Pass `max_reading_age_seconds:` to override."
  @spec max_reading_age_seconds(keyword()) :: pos_integer()
  def max_reading_age_seconds(opts \\ []), do: Keyword.get_lazy(opts, :max_reading_age_seconds, &configured_max_age/0)

  @doc "Remaining percent of a reading's binding window, or `nil` when unknown (`Aiur.Accounts.Headroom`)."
  @spec remaining_percent(Headroom.reading()) :: non_neg_integer() | nil
  def remaining_percent(reading), do: Headroom.remaining_percent(reading)

  defp select_route(issue, eligible, opts) do
    routes =
      case eligible.(level_routes(issue, opts) || Keyword.get_lazy(opts, :backends, &Config.switch_model_on_ratelimit/0)) do
        [] -> [Keyword.get_lazy(opts, :default_backend, &Config.agent_kind/0)]
        routes -> routes
      end

    candidates = routes |> order_by_priority(opts) |> Enum.flat_map(&expand(&1, &1, opts))

    case Headroom.select(candidates, readings(candidates, opts)) do
      {:ok, chosen, ranked} ->
        {:ok, apply_choice(issue, chosen, ranked, false)}

      {:error, :all_exhausted, ranked} ->
        log(issue, nil, ranked)
        {:all_limited, ranked |> Enum.map(& &1.candidate.route) |> Enum.uniq()}
    end
  end

  # A pin keeps its backend and model. Headroom only picks the account, and a
  # pin whose accounts are all exhausted still dispatches, as a pin did before.
  defp select_pinned_account(issue, backend, opts) do
    candidates = expand(backend, nil, opts)

    case Headroom.select(candidates, readings(candidates, opts)) do
      {:ok, chosen, ranked} ->
        {:ok, apply_choice(issue, chosen, ranked, true)}

      {:error, :all_exhausted, ranked} ->
        log(issue, nil, ranked)
        {:ok, %{issue | selected_account: nil, dispatch_selection: selection(nil, ranked, true)}}
    end
  end

  # The backend the rate-limit fallback (or an operator) already chose is a
  # pin. A backend that an earlier headroom choice set is not: the next
  # dispatch of the ticket scores the candidates again (#3960 item 6).
  defp pinned_backend(%Issue{selected_backend: backend, dispatch_selection: nil}, _opts) when is_binary(backend), do: backend
  defp pinned_backend(%Issue{selected_backend: backend, dispatch_selection: %{pinned: true}}, _opts) when is_binary(backend), do: backend

  defp pinned_backend(issue, opts), do: CodingAgent.override_backend(issue, opts)

  defp apply_choice(issue, %{candidate: candidate} = chosen, ranked, pinned?) do
    log(issue, chosen, ranked)
    issue = %{issue | selected_account: candidate.account, dispatch_selection: selection(chosen, ranked, pinned?)}

    if pinned?,
      do: issue,
      else: %{issue | selected_backend: candidate.backend, selected_model: RoutingValue.routing_model(candidate.route)}
  end

  defp selection(chosen, ranked, pinned?) do
    candidate = if chosen, do: chosen.candidate, else: %{}

    %{
      policy: @policy,
      pinned: pinned?,
      backend: candidate[:backend],
      account: candidate[:account],
      route: candidate[:route],
      summary: Headroom.summary(chosen, ranked),
      candidates: Enum.map(ranked, &candidate_view/1)
    }
  end

  defp candidate_view(%{candidate: candidate} = scored) do
    %{
      name: Headroom.name(candidate),
      backend: candidate.backend,
      account: candidate.account,
      route: candidate.route,
      status: scored.status,
      remaining_percent: scored.remaining && round(scored.remaining * 100),
      binding_window: scored.binding_window,
      source: scored.source,
      age_seconds: scored.age_seconds,
      stale: scored.stale
    }
  end

  defp log(issue, chosen, ranked) do
    Logger.info("headroom_dispatch issue_identifier=#{issue.identifier} " <> Headroom.summary(chosen, ranked))
  end

  defp expand(backend_or_route, route, opts) do
    backend = RoutingValue.routing_backend(backend_or_route)
    Enum.map(account_names(backend, opts), &%{backend: backend, account: &1, route: route})
  end

  # Ties keep `agent.priority` order. A level's route list is stable-sorted by
  # its backend's priority position; backends the priority omits go last.
  defp order_by_priority(routes, opts) do
    priority = Keyword.get_lazy(opts, :priority_backends, &configured_priority_backends/0)
    Enum.sort_by(routes, fn route -> Enum.find_index(priority, &(&1 == RoutingValue.routing_backend(route))) || length(priority) end)
  end

  defp account_names(backend, opts) do
    harness = account_backend(backend)
    configured = opts |> Keyword.get_lazy(:accounts, &configured_accounts/0) |> Map.get(harness, [])
    list_accounts = Keyword.get(opts, :account_list_fun, &Accounts.list/1)

    names =
      if configured != [] and multi_account?(harness, opts) do
        registered = MapSet.new(list_accounts.(harness), & &1.name)
        Enum.filter(configured, &MapSet.member?(registered, &1))
      else
        []
      end

    if names == [], do: [nil], else: names
  end

  defp multi_account?(harness, opts) do
    case Keyword.get(opts, :account_capability_fun, &Accounts.capability/1).(harness) do
      {:ok, capability} -> Accounts.supported?(capability)
      _ -> false
    end
  end

  defp readings(candidates, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    state = ledger_state(opts)
    opts = Keyword.put(opts, :max_reading_age_seconds, max_reading_age_seconds(opts))
    meters = account_meters(candidates, now, opts)
    per_backend = candidates |> Enum.uniq_by(&{&1.backend, &1.account}) |> Enum.frequencies_by(& &1.backend)

    Map.new(candidates, fn candidate ->
      {Headroom.key(candidate), reading(candidate, state, meters, per_backend, now, opts)}
    end)
  end

  defp reading(%{backend: backend, account: account}, state, meters, per_backend, now, opts) do
    cond do
      not ModelAvailability.available?(backend, state: state, now: now) -> %{limited: true, source: "ledger"}
      reading = Map.get(meters, {account_backend(backend), account || "default"}) -> reading
      Map.get(per_backend, backend) == 1 -> backend_reading(backend, Keyword.merge(opts, state: state, now: now))
      true -> nil
    end
  end

  defp account_meters(candidates, now, opts) do
    snapshot = Keyword.get(opts, :usage_snapshot, &UsageReadings.snapshot/2)

    candidates
    |> Enum.group_by(&account_backend(&1.backend), &(&1.account || "default"))
    |> Enum.flat_map(fn {harness, names} ->
      for {name, entry} <- snapshot.(harness, names), reading = meter_reading(entry, now, opts), do: {{harness, name}, reading}
    end)
    |> Map.new()
  end

  defp meter_reading(%{reading: %{windows: windows}} = entry, now, opts) when is_list(windows) do
    used = for %{window: window, used_percent: percent} when window in ["five_hour", "seven_day"] and is_number(percent) <- windows, into: %{}, do: {window, percent}
    if used == %{}, do: nil, else: with_age(%{windows: used, source: "meter"}, parse_time(entry[:observed_at]), now, opts)
  end

  defp meter_reading(_entry, _now, _opts), do: nil

  # A reading with no observation time cannot be shown as current.
  defp with_age(reading, nil, _now, _opts), do: Map.put(reading, :stale, true)

  defp with_age(reading, %DateTime{} = observed_at, now, opts) do
    age = max(DateTime.diff(now, observed_at, :second), 0)

    if age > max_reading_age_seconds(opts),
      do: %{stale: true, age_seconds: age, source: reading.source},
      else: Map.put(reading, :age_seconds, age)
  end

  defp parse_time(%DateTime{} = value), do: value

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _offset} -> time
      _ -> nil
    end
  end

  defp parse_time(_value), do: nil

  defp window_used(%{"used" => used, "limit" => limit} = window, now) when is_number(used) and is_number(limit) and limit > 0 do
    if reset_passed?(Map.get(window, "reset_at"), now), do: nil, else: used / limit * 100
  end

  defp window_used(_window, _now), do: nil

  defp reset_passed?(nil, _now), do: false
  defp reset_passed?(value, now) when is_integer(value), do: value <= DateTime.to_unix(now)

  defp reset_passed?(value, now) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, reset_at, _offset} -> DateTime.compare(reset_at, now) != :gt
      _ -> false
    end
  end

  defp reset_passed?(_value, _now), do: false

  defp ledger_state(opts) do
    Keyword.get_lazy(opts, :state, fn -> ModelAvailability.load(Keyword.get_lazy(opts, :path, &ModelAvailability.path/0)) end)
  rescue
    _ -> %{"backends" => %{}}
  end

  defp account_backend("claude-repl"), do: "claude"
  defp account_backend(backend), do: backend

  defp configured_selection do
    Config.settings!().agent.account_selection
  rescue
    _ -> nil
  end

  defp configured_max_age do
    Config.settings!().agent.headroom_reading_max_age_seconds || 1800
  rescue
    _ -> 1800
  end

  defp configured_accounts do
    Config.settings!().agent.accounts || %{}
  rescue
    _ -> %{}
  end

  defp configured_priority_backends do
    Config.agent_priority_backends()
  rescue
    _ -> []
  end

  defp configured_routing_candidates do
    agent = Config.settings!().agent
    single = Map.new(agent.routing || %{}, fn {level, value} -> {level, List.wrap(value)} end)
    Map.merge(single, Map.get(agent, :routing_candidates) || %{})
  rescue
    _ -> %{}
  end
end
