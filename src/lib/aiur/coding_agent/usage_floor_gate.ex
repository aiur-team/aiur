defmodule Aiur.CodingAgent.UsageFloorGate do
  @moduledoc """
  Dispatch-time gate for the remaining-usage floor (#7504).

  `agent.usage_floor_percent` lets an operator leave every login enabled and
  still stop aiur starting work on a route whose allowance is nearly gone.
  This module turns the daemon's existing usage readings into per-candidate and
  per-route verdicts, records which routes are currently held so the floor and
  its recovery are alerted once each, and renders the `held:` lines `aiur
  status` and `aiur usage` print.

  The decision itself is `Aiur.Accounts.UsageFloor`. This module only supplies
  readings and applies the verdict:

  * **Candidates** come from `Aiur.CodingAgent.HeadroomDispatch.expand/3`, the
    same route-to-account expansion headroom dispatch uses, so the gate sees
    exactly the accounts a dispatch could choose.
  * **Readings** come from `HeadroomDispatch.readings/2`: the polled per-account
    meters for Claude and the usage ledger for Codex. A credit-based API key
    (OpenRouter and friends) has neither, so its reading comes from the daemon's
    provider meter projection — and only when that projection knows the key's
    limit. A key without a known limit is never floored.
  * **A route is floored when every account it can reach is floored**, so a
    backend with one free account keeps taking work while its neighbour rests.

  Nothing here stops a running agent. The floor is consulted when a new dispatch
  or a turn handoff chooses a route, so an agent already working keeps its
  account until its own turn ends.
  """

  require Logger

  alias Aiur.Accounts.Headroom
  alias Aiur.Accounts.UsageFloor
  alias Aiur.CodingAgent.HeadroomDispatch
  alias Aiur.CodingAgent.ProvidersView
  alias Aiur.Config
  alias Aiur.ProviderMeterProjection

  @state_key {__MODULE__, :held}
  @alert_topic "system.agent.usage_floor"

  @typedoc "One candidate whose reading is at or below the floor, with the window that floored it."
  @type held_entry :: %{candidate: map(), held: UsageFloor.held()}

  @doc "The route label a held line and its alert name, e.g. `claude/everdred`."
  @spec label(map()) :: String.t()
  def label(candidate), do: Headroom.name(candidate)

  @doc """
  The `; held …` fragment a dispatch record appends to its summary, or `""`.

  A held candidate is not a scored alternative — dispatch could not choose it —
  so it is named after the ranking with the window that floored it. That is the
  dispatch record's evidence for skipping a route that was configured and
  enabled (#7504).
  """
  @spec held_summary([held_entry()]) :: String.t()
  def held_summary([]), do: ""

  def held_summary(held) do
    "; held " <> Enum.map_join(held, ", ", &held_text/1)
  end

  @doc """
  One held candidate as a dispatch-record candidate row, so `aiur status` and
  `aiur agents` show the skipped route beside the scored ones.
  """
  @spec held_view(held_entry()) :: map()
  def held_view(%{candidate: candidate, held: held}) do
    %{
      name: label(candidate),
      backend: candidate.backend,
      account: candidate.account,
      route: candidate.route,
      status: :held,
      remaining_percent: round(held.remaining_percent),
      binding_window: held.window,
      source: held.source,
      age_seconds: held.age_seconds,
      stale: false,
      held: UsageFloor.held_line(held)
    }
  end

  @doc """
  Split candidates into the ones dispatch may use and the ones the floor holds.

  `readings` is keyed by `HeadroomDispatch`'s candidate key, as returned by
  `HeadroomDispatch.readings/2`.
  """
  @spec split_candidates([map()], map(), keyword()) :: {[map()], [held_entry()]}
  def split_candidates(candidates, readings, opts \\ []) when is_list(candidates) and is_map(readings) do
    candidates
    |> Enum.map(&{&1, UsageFloor.decision(reading_for(&1, readings, opts), floor_for(&1, opts))})
    |> Enum.reduce({[], []}, fn
      {candidate, {:held, held}}, {allowed, held_entries} -> {allowed, [%{candidate: candidate, held: held} | held_entries]}
      {candidate, :allow}, {allowed, held_entries} -> {[candidate | allowed], held_entries}
    end)
    |> then(fn {allowed, held_entries} -> {Enum.reverse(allowed), Enum.reverse(held_entries)} end)
  end

  @doc "The candidates of `routes` the floor allows, in input order."
  @spec allowed_candidates([map()], map(), keyword()) :: [map()]
  def allowed_candidates(candidates, readings, opts \\ []), do: candidates |> split_candidates(readings, opts) |> elem(0)

  @doc """
  The routes the floor allows: a route survives while at least one of its
  accounts has more than the floor left. Order is preserved.
  """
  @spec allowed_routes([String.t()], keyword()) :: [String.t()]
  def allowed_routes(routes, opts \\ []) when is_list(routes) do
    routes |> evaluate(opts) |> elem(0)
  end

  @doc """
  The routes the floor allows, recording the floor and its recovery for each
  held route — the dispatch-time variant of `allowed_routes/2`.

  Claim-time selection calls this so `priority` and `balance` raise the same
  floor and recovery alerts `headroom` raises. `allowed_routes/2` stays a pure
  read for surfaces (`aiur status`, `aiur usage`) that must not alert.
  """
  @spec filter_routes([String.t()], keyword()) :: [String.t()]
  def filter_routes(routes, opts \\ []) when is_list(routes) do
    {allowed, held, evaluated} = evaluate(routes, opts)
    record(held, evaluated, opts)
    allowed
  end

  @doc "Whether dispatch would skip this route entirely."
  @spec route_floored?(String.t(), keyword()) :: boolean()
  def route_floored?(route, opts \\ []) when is_binary(route), do: allowed_routes([route], opts) == []

  @doc "Whether every account reachable by this backend is at or below the floor."
  @spec backend_floored?(String.t(), keyword()) :: boolean()
  def backend_floored?(backend, opts \\ []) when is_binary(backend), do: route_floored?(backend, opts)

  @doc """
  Whether one account's reading is at or below the floor. `reading` may be a
  headroom reading, or the `%{"five_hour" => used}` usage map the session
  options read; both normalise inside `Aiur.Accounts.UsageFloor`.
  """
  @spec account_floored?(String.t(), map() | nil, keyword()) :: boolean()
  def account_floored?(backend, reading, opts \\ []) do
    reading
    |> usage_reading()
    |> UsageFloor.held?(floor_for(backend, opts))
  end

  @doc """
  The accounts of one backend dispatch may still use: `usages` is the session
  options' map of account name to usage map. Order is preserved. An account with
  no usage map stays allowed — an unknown reading is never floored.
  """
  @spec allowed_accounts(String.t(), [String.t()], map(), keyword()) :: [String.t()]
  def allowed_accounts(backend, accounts, usages, opts \\ []) when is_list(accounts) and is_map(usages) do
    Enum.reject(accounts, &account_floored?(backend, Map.get(usages, &1), opts))
  end

  @doc """
  The held lines for the routes dispatch would currently skip, one per held
  candidate, e.g. `claude/everdred held: 3% left ≤ 5% floor, resets in 2h`.

  This is a live read: a route that has since reset no longer appears, so
  `aiur status` never reports a hold that has already cleared.
  """
  @spec held_lines(keyword()) :: [String.t()]
  def held_lines(opts \\ []) do
    routes = Keyword.get_lazy(opts, :routes, &configured_routes/0)

    routes
    |> evaluate(opts)
    |> elem(1)
    |> Enum.map(fn %{candidate: candidate, held: held} -> label(candidate) <> " " <> UsageFloor.held_line(held) end)
  end

  @doc """
  A clear, operator-facing reason for holding a claim whose every route is
  floored, or `nil` when the routes are not all floored.
  """
  @spec hold_reason([String.t()], keyword()) :: String.t() | nil
  def hold_reason(routes, opts \\ []) when is_list(routes) do
    case evaluate(routes, opts) do
      {[], held_entries, _evaluated} when held_entries != [] ->
        "every route is held at the usage floor (" <> Enum.map_join(held_entries, "; ", &held_text/1) <> ")"

      _allowed ->
        nil
    end
  end

  # One evaluation of a route list: the routes dispatch may still use, the
  # candidates the floor holds, and every candidate label that was looked at
  # (which is what scopes a recovery in `record/3`). Read-only; callers decide
  # whether the result should be recorded.
  defp evaluate(routes, opts) do
    candidates = candidates(routes, opts)
    {allowed_candidates, held} = split_candidates(candidates, HeadroomDispatch.readings(candidates, opts), opts)
    allowed = MapSet.new(allowed_candidates, & &1.route)

    {Enum.filter(routes, &MapSet.member?(allowed, &1)), held, Enum.map(candidates, &label/1)}
  end

  @doc """
  Record the candidates this evaluation held, alerting once when a route starts
  being floored and once when it recovers.

  `evaluated` is the candidate label of every candidate this call looked at
  (`label/1`), so a candidate that simply was not considered is neither reported
  as recovered nor dropped from the registry. A held candidate whose backend was
  evaluated but whose own label is gone from the set has recovered.
  """
  @spec record([held_entry()], [String.t()], keyword()) :: :ok
  def record(held_entries, evaluated, opts \\ []) do
    now = now_value(opts)
    labels = MapSet.new(evaluated)
    backends = MapSet.new(evaluated, &label_backend/1)
    previous = :persistent_term.get(@state_key, %{})

    current = Map.new(held_entries, fn %{candidate: candidate, held: held} -> {label(candidate), %{held: held, observed_at: now}} end)

    scoped_previous =
      Map.filter(previous, fn {label, _entry} -> MapSet.member?(labels, label) or MapSet.member?(backends, label_backend(label)) end)

    for {label, entry} <- current, not Map.has_key?(scoped_previous, label), do: alert_held(label, entry, opts)
    for {label, _entry} <- scoped_previous, not Map.has_key?(current, label), do: alert_recovered(label, opts)

    merged = Map.merge(Map.drop(previous, Map.keys(scoped_previous)), current)
    # Every dispatch decision records here, and the ordinary case is "nothing is
    # floored". A `:persistent_term` write invalidates every process's copy and
    # triggers a global GC scan, so write only when the held set changed.
    if merged == previous, do: :ok, else: :persistent_term.put(@state_key, merged)
    :ok
  end

  @doc "The routes the last evaluation recorded as held."
  @spec held_state() :: %{optional(String.t()) => map()}
  def held_state, do: :persistent_term.get(@state_key, %{})

  @doc false
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@state_key)
    :ok
  end

  @doc """
  Every candidate a route list can reach, through headroom's expansion, with
  its route preserved. Exposed for the gate's own tests and for callers that
  need the candidate set without scoring it.
  """
  @spec candidates([String.t()], keyword()) :: [map()]
  def candidates(routes, opts \\ []) when is_list(routes) do
    Enum.flat_map(routes, &HeadroomDispatch.expand(&1, &1, opts))
  end

  defp held_text(%{candidate: candidate, held: held}), do: label(candidate) <> " " <> UsageFloor.held_line(held)

  # Callers inject a fixed clock (`now: ~U[...]`) or a zero-arity function.
  defp now_value(opts) do
    case Keyword.get(opts, :now, &DateTime.utc_now/0) do
      fun when is_function(fun, 0) -> fun.()
      %DateTime{} = now -> now
      _other -> DateTime.utc_now()
    end
  end

  # The reading headroom gathered for this candidate, or the provider meter's
  # credit window when the backend has no polled meter and no ledger entry. A
  # Claude or Codex projection carries rate-limit windows, not credit ones, so
  # the fallback never overrides a per-account reading with a host-wide one.
  defp reading_for(candidate, readings, opts) do
    Map.get(readings, Headroom.key(candidate)) || credit_reading(candidate.backend, opts)
  end

  @doc """
  The provider meter's credit reading for a backend whose key reports its
  remaining balance against a known limit, or `nil`.

  Only a window the projection reports as a **credit** window qualifies, and
  only when it carries a used percentage — a key whose limit is unknown has no
  percentage to compare against the floor, so it is never floored. OpenRouter
  publishes `total_credits` through its management key; a key without one stays
  unknown.
  """
  @spec credit_reading(String.t() | nil) :: UsageFloor.reading()
  def credit_reading(backend), do: credit_reading(backend, [])

  @spec credit_reading(String.t() | nil, keyword()) :: UsageFloor.reading()
  def credit_reading(backend, opts) when is_binary(backend) do
    with provider when not is_nil(provider) <- Map.get(ProvidersView.provider_family_map(), backend),
         view when is_map(view) <- provider_view(provider, opts),
         :observed <- Map.get(view, :state),
         used when is_number(used) <- credit_used_percent(view) do
      %{
        windows: %{"credits" => used},
        source: "provider_meter",
        age_seconds: Map.get(view, :age_seconds),
        stale: Map.get(view, :freshness) in [:stale, :unknown]
      }
    else
      _unknown -> nil
    end
  end

  def credit_reading(_backend, _opts), do: nil

  defp provider_view(provider, opts) do
    Keyword.get_lazy(opts, :provider_view_fun, fn -> &ProviderMeterProjection.provider_view/1 end).(provider)
  end

  defp credit_used_percent(%{windows: windows}) when is_map(windows) do
    windows
    |> Enum.map(fn {_id, window} -> window end)
    |> Enum.find_value(fn window ->
      if Map.get(window, :kind) == :credit and is_number(Map.get(window, :used_percent)), do: Map.get(window, :used_percent)
    end)
  end

  defp credit_used_percent(_view), do: nil

  # A held candidate's label is the route's backend plus its account, while a
  # route is the configured string (`claude:opus`). Scoping a recovery by route
  # therefore compares backends.
  defp label_backend(label), do: label |> String.split("/") |> hd()

  defp floor_for(%{backend: backend}, opts), do: floor_for(backend, opts)

  defp floor_for(backend, opts) do
    fun = Keyword.get(opts, :usage_floor_percent_fun, &configured_floor/1)
    fun.(backend)
  end

  defp configured_floor(backend), do: Config.usage_floor_percent_for(backend)

  # A reading already in the headroom shape is passed through; the session
  # options' usage map (`%{"five_hour" => used, "seven_day" => used}`) is
  # wrapped so the same rule applies to both.
  defp usage_reading(%{windows: _windows} = reading), do: reading
  defp usage_reading(usage) when is_map(usage) and map_size(usage) > 0, do: %{windows: usage}
  defp usage_reading(_reading), do: nil

  defp alert_held(route, %{held: held}, opts) do
    message = route <> " " <> UsageFloor.held_line(held)
    Logger.info("usage_floor held route=#{route} window=#{held.window} remaining=#{held.remaining_percent} floor=#{held.floor_percent}")
    alert_fun(opts).(alert_name(route), message, needs_attention: false, severity: "info")
  end

  defp alert_recovered(route, opts) do
    alert_fun(opts).(alert_name(route) <> ".resolved", "#{route} recovered above the usage floor.", needs_attention: false, severity: "info")
  end

  defp alert_fun(opts), do: Keyword.get(opts, :usage_floor_alert_fun, &Aiur.Signal.agent_alert/3)

  # Alert topics are slugs: a route or account name may contain `:` or `/`.
  defp alert_name(route), do: @alert_topic <> "." <> String.replace(route, ~r/[^a-zA-Z0-9_-]+/, "-")

  defp configured_routes do
    case Config.agent_priority() do
      [] -> Config.switch_model_on_ratelimit()
      priority -> priority
    end
  rescue
    _error -> []
  end
end
