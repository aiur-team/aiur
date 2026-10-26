defmodule Aiur.Netlify.Usage do
  @moduledoc "Polled, age-aware Netlify usage and audit-anchored credit estimate."
  use GenServer
  alias Aiur.{Accounts.EnvKey, Config, Netlify.Client, Usage.Events}

  @poll_ms 900_000
  @empty %{provider: :netlify, state: :unavailable, reason: :not_observed, observed_at: nil, age_ms: nil, freshness: :unknown, source: "netlify.usage", fields: %{}}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  @spec snapshot(GenServer.server()) :: map()
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)
  @spec refresh(GenServer.server()) :: map()
  def refresh(server \\ __MODULE__), do: GenServer.call(server, :refresh, 120_000)
  @spec topic() :: String.t()
  def topic, do: Events.netlify_topic()

  @impl true
  def init(opts) do
    send(self(), :poll)

    {:ok,
     %{
       snapshot: @empty,
       seen: MapSet.new(),
       client: Keyword.get(opts, :client, &Client.fetch/3),
       clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
       interval: Keyword.get(opts, :interval_ms, poll_ms())
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, age(state.snapshot, state.clock.(), state.interval * 2), state}

  def handle_call(:refresh, _from, state) do
    {snapshot, state} = collect(state)
    {:reply, snapshot, state}
  end

  @impl true
  def handle_info(:poll, state) do
    {_snapshot, state} = collect(state)
    Process.send_after(self(), :poll, state.interval)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @doc false
  @spec calculate(map(), DateTime.t()) :: map()
  def calculate(data, now) do
    start_at = datetime(data.account["current_billing_period_start"])
    days = max(if(start_at, do: DateTime.diff(now, start_at, :second) / 86_400, else: 1), 1)
    sites = calculate_sites(data.sites, days)
    bandwidth = bandwidth_gb(data.bandwidth)
    burn_day = burn_per_day(sites, bandwidth, days)
    anchor = latest_anchor(data.audit)
    estimate = estimate(anchor, burn_day, now)
    purchased = Enum.reduce(data.audit, 0, fn event, sum -> sum + purchase(event, start_at) end)

    %{
      state: if(is_number(estimate.remaining), do: :ready, else: :unavailable),
      reason: if(is_number(estimate.remaining), do: nil, else: :no_valid_audit_anchor),
      account: account_fields(data.account, purchased),
      sites: sites,
      credits: credit_fields(anchor, burn_day, estimate)
    }
  end

  defp calculate_sites(sites, days),
    do:
      Enum.map(sites, fn site ->
        burn = site.production_deploys * 15
        Map.merge(site, %{credits_burn: burn, credits_burn_per_day: burn / days})
      end)

  defp burn_per_day(sites, bandwidth, days), do: (Enum.sum(Enum.map(sites, & &1.credits_burn)) + bandwidth * 20) / days

  defp estimate(nil, _burn, _now), do: %{remaining: nil, age_seconds: nil, runway_days: nil}

  defp estimate(anchor, burn, now) do
    age_seconds = max(DateTime.diff(now, anchor.observed_at, :second), 0)
    remaining = max(anchor.balance - burn * age_seconds / 86_400, 0)
    %{remaining: remaining, age_seconds: age_seconds, runway_days: if(burn > 0, do: remaining / burn)}
  end

  defp account_fields(account, purchased) do
    %{
      type_name: account["type_name"],
      plan_credits: number(account["plan_credits"]),
      purchased_credits: purchased,
      auto_topup_enabled: account["auto_topup_enabled"],
      plan_auto_topup_amount: number(account["plan_auto_topup_amount"]),
      usages_exceeded: account["usages_exceeded"],
      sites_with_usage_exceeded: account["sites_with_usage_exceeded"]
    }
  end

  defp credit_fields(anchor, burn, estimate) do
    %{
      estimated_remaining: estimate.remaining,
      estimate: "Estimated from audit anchor less deploy and bandwidth burn",
      anchor: anchor && Map.drop(anchor, [:balance]),
      anchor_balance: anchor && anchor.balance,
      anchor_age_seconds: estimate.age_seconds,
      burn_credits_per_day: burn,
      runway_days: estimate.runway_days
    }
  end

  @doc false
  @spec age(map(), DateTime.t(), non_neg_integer()) :: map()
  def age(snapshot, now, stale_after) do
    case snapshot.observed_at do
      %DateTime{} = observed ->
        ms = max(DateTime.diff(now, observed, :millisecond), 0)
        Map.merge(snapshot, %{age_ms: ms, freshness: if(snapshot.state == :ready and ms > stale_after, do: :stale, else: snapshot.freshness)})

      _ ->
        snapshot
    end
  end

  @doc false
  @spec alert_transition(map(), number(), boolean(), (atom() -> term())) :: boolean()
  def alert_transition(snapshot, threshold, active, emit) do
    remaining = get_in(snapshot, [:fields, :credits, :estimated_remaining])
    low_event = Map.get(snapshot, :low_event?, false)
    transition_alert(alert_condition(remaining, threshold, low_event), active, emit)
  end

  defp alert_condition(_remaining, _threshold, true), do: :low
  defp alert_condition(remaining, threshold, false) when is_number(remaining) and threshold > 0 and remaining <= threshold, do: :low
  defp alert_condition(remaining, threshold, false) when is_number(remaining) and remaining > threshold, do: :healthy
  defp alert_condition(_remaining, _threshold, _event), do: :unknown
  defp transition_alert(:low, false, emit), do: emit.(:low) == :ok
  defp transition_alert(:healthy, true, emit), do: emit.(:resolved) != :ok
  defp transition_alert(_condition, active, _emit), do: active

  defp collect(state) do
    cfg = Aiur.Config.netlify_settings()
    token = netlify_auth_token()

    result =
      if cfg.enabled and is_binary(cfg.account_id) and cfg.account_id != "" and is_binary(token),
        do: state.client.(cfg.account_id, token, request_fun: Application.get_env(:aiur, :netlify_request_fun, &Client.default_request/1), now: state.clock.()),
        else: {:error, :unavailable}

    case result do
      {:ok, data} ->
        fields = calculate(data, state.clock.())
        low_events = Enum.filter(data.audit, &low_event?/1)
        signature = Enum.map(low_events, &{&1["action"], &1["created_at"]}) |> MapSet.new()

        snapshot = %{
          provider: :netlify,
          state: fields.state,
          reason: fields.reason,
          observed_at: data.fetched_at || state.clock.(),
          age_ms: 0,
          freshness: if(fields.state == :ready, do: :fresh, else: :unavailable),
          source: "netlify.usage",
          low_event?: Enum.any?(signature, &(not MapSet.member?(state.seen, &1))),
          fields: fields
        }

        Events.broadcast_netlify(snapshot)
        {snapshot, %{state | snapshot: snapshot, seen: MapSet.union(state.seen, signature)}}

      {:error, _} ->
        snapshot = Map.merge(@empty, %{reason: :unavailable, observed_at: state.clock.(), age_ms: 0, freshness: :unavailable})
        Events.broadcast_netlify(snapshot)
        {snapshot, %{state | snapshot: snapshot}}
    end
  rescue
    _ -> {@empty, state}
  end

  defp latest_anchor(events) do
    events |> Enum.sort_by(&(&1["created_at"] || "")) |> Enum.reduce(nil, fn event, acc -> anchor_event(event, acc) end)
  end

  defp anchor_event(event, acc) do
    action = event["action"] || ""
    traits = event["traits"] || %{}
    at = datetime(event["created_at"] || event["timestamp"])
    balance = number(traits["credit_balance"] || traits["balance"])

    balance_anchor(action, balance, at) || purchase_anchor(action, traits, at, acc) || acc
  end

  defp balance_anchor(action, balance, at) when is_number(balance) and not is_nil(at), do: %{event: action, observed_at: at, balance: balance}
  defp balance_anchor(_action, _balance, _at), do: nil

  defp purchase_anchor(action, traits, at, acc) when is_map(acc) and not is_nil(at) do
    amount = number(traits["purchase_amount"])
    if String.contains?(String.downcase(action), "purchase") and is_number(amount), do: %{event: action, observed_at: at, balance: acc.balance + amount}
  end

  defp purchase_anchor(_action, _traits, _at, _acc), do: nil

  defp purchase(event, start_at) do
    amount = number(get_in(event, ["traits", "purchase_amount"]))
    at = datetime(event["created_at"] || event["timestamp"])
    if String.contains?(String.downcase(event["action"] || ""), "purchase") and is_number(amount) and (is_nil(start_at) or (at && DateTime.compare(at, start_at) in [:eq, :gt])), do: amount, else: 0
  end

  defp bandwidth_gb(bandwidth), do: max(number(bandwidth["total"]) || number(bandwidth["used"]) || 0, 0) / 1_000_000_000
  defp low_event?(event), do: String.contains?(String.downcase(event["action"] || ""), "threshold") or String.contains?(String.downcase(event["action"] || ""), "depleted")

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp datetime(_), do: nil
  defp number(value) when is_number(value), do: value
  defp number(_), do: nil

  defp poll_ms do
    Config.netlify_settings().poll_seconds * 1_000
  rescue
    _ -> @poll_ms
  end

  defp netlify_auth_token do
    case System.get_env("NETLIFY_AUTH_TOKEN") do
      token when is_binary(token) and token != "" -> token
      _unset -> EnvKey.read("NETLIFY_AUTH_TOKEN")
    end
  end
end
