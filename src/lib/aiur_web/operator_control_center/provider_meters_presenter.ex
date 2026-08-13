defmodule AiurWeb.OperatorControlCenter.ProviderMetersPresenter do
  @moduledoc """
  Formats DASH-020 Codex and DASH-013 Claude `Aiur.ProviderMeterSnapshot`
  facts into a named, screen-reader-friendly view for the Units page provider
  meter cards, behind the DASH-021 authorization boundary.

  This presenter is pure: it performs no provider I/O and no aggregate math.
  Protected snapshots are fetched by the LiveView through the DASH-021 facade
  and passed in already loaded. A locked capability produces a content-free
  view carrying only DASH-021's static locked contract — never a snapshot,
  account generation, auth mode, plan/tier, quota value, reset, or freshness.

  ## Identity-scoped facts

  Actual auth mode, plan/tier, and quota windows attach only to a card whose
  snapshot carries an exact known `provider_account_generation`. Unknown,
  awaiting-first-observation, hard-error, and other unavailable identities stay
  explicit and never borrow the current login's tier or another account's
  quota. Each meter window keeps its coverage (`supported`, `unsupported`,
  `empty_supported`), standing, freshness, and reset distinct.
  """

  alias Aiur.CodingAgent
  alias Aiur.ProviderMeterSnapshot
  alias AiurWeb.FinancialDataAccess

  @real_failures [:authentication, :malformed, :timeout, :transport]

  # Failure reasons that mean "no observation is possible *yet*" rather than a
  # hard failure: a provider whose credentials have not been supplied cannot be
  # read, but it is not broken. They render as loading, exactly like a first
  # observation that simply has not arrived.
  @credential_failures [
    :no_credentials,
    :malformed_credentials,
    :missing_api_key,
    :missing_api_key_configuration,
    :disabled
  ]

  # Failure reasons that mean the account is not signed in: an OAuth token that
  # is absent, empty, or expired. Unlike a missing API key, this is a stable,
  # user-actionable state ("sign in to Claude Code"), so it renders honestly as
  # "not signed in" rather than hanging in an eternal loading state.
  @signed_out_failures [:no_oauth_token, :token_expired]

  @window_kind_order %{rate_limit: 0, credit: 1, spend_control: 2}

  @type snapshots :: %{optional(atom()) => ProviderMeterSnapshot.t() | nil}
  @type view :: map()

  @doc """
  Present the provider meter cards for a connection `capability`
  (`AiurWeb.FinancialDataAccess` capability assign) and the already-loaded
  protected `snapshots`.

  A `:locked` capability ignores `snapshots` entirely and returns the
  content-free locked view.
  """
  @spec present(map(), snapshots()) :: view()
  def present(capability, snapshots \\ %{})

  def present(%{state: :authorized}, snapshots) when is_map(snapshots) do
    %{
      state: :authorized,
      locked: nil,
      cards: Enum.map(CodingAgent.provider_families(), &card(&1, Map.get(snapshots, &1)))
    }
  end

  def present(capability, _snapshots) do
    %{state: :locked, locked: locked(capability), cards: []}
  end

  @doc "A single bounded screen-reader announcement summarising the presented `view`."
  @spec announcement(view()) :: String.t()
  def announcement(%{state: :locked}) do
    "Provider account meters are locked. Authentication is required to view provider account meters."
  end

  def announcement(%{state: :authorized, cards: cards}) when is_list(cards) do
    cards
    |> Enum.map_join(" ", &card_sentence/1)
    |> String.trim()
    |> case do
      "" -> "No provider account meters are available."
      sentence -> sentence
    end
  end

  def announcement(_view), do: "Provider account meters are unavailable."

  # --- locked --------------------------------------------------------------

  defp locked(%{state: :locked} = capability) do
    %{
      accessible_name: Map.get(capability, :accessible_name, "Provider meters locked"),
      reason: Map.get(capability, :reason, "Authentication is required to access provider meters."),
      authentication_path: Map.get(capability, :authentication_path)
    }
  end

  defp locked(_capability), do: locked(FinancialDataAccess.locked_capability())

  # --- per-provider card ---------------------------------------------------

  defp card(provider, snapshot) do
    state = card_state(snapshot)
    known? = known_identity?(state)

    %{
      provider: provider,
      provider_label: provider_label(provider),
      backend_label: backend_label(snapshot),
      state: state,
      status_label: status_label(state),
      identity: identity(snapshot, known?),
      auth_mode: auth_mode(snapshot, known?),
      plan: plan(snapshot, known?),
      health: health(snapshot),
      freshness: freshness(snapshot),
      observed_at: observed_at(snapshot),
      ingested_at: ingested_at(snapshot),
      windows: windows(snapshot, known?)
    }
  end

  # A card names quota/tier facts only for identities with an exact known
  # account generation. Loading, unknown, hard-error, and other unavailable
  # cards never borrow another identity's facts.
  defp known_identity?(state) when state in [:healthy, :partial, :stale], do: true
  defp known_identity?(_state), do: false

  # nil snapshot: the LiveView has not yet loaded this provider (mount before
  # the authorized fetch, or a provider whose fetch was isolated after a
  # failure).
  defp card_state(nil), do: :loading

  defp card_state(%ProviderMeterSnapshot{health: %{state: :unavailable, failure: :unknown_account_generation}}), do: :unknown

  defp card_state(%ProviderMeterSnapshot{health: %{state: :unavailable, failure: failure}})
       when failure in @signed_out_failures,
       do: :signed_out

  defp card_state(%ProviderMeterSnapshot{health: %{state: :unavailable, failure: failure}})
       when failure in @credential_failures,
       do: :loading

  defp card_state(%ProviderMeterSnapshot{health: %{state: :unavailable, failure: :no_observation}}), do: :loading
  defp card_state(%ProviderMeterSnapshot{health: %{state: :unavailable}}), do: :unavailable
  defp card_state(%ProviderMeterSnapshot{health: %{state: :healthy}}), do: :healthy
  defp card_state(%ProviderMeterSnapshot{health: %{state: :partial}}), do: :partial

  # A stale health with a real adapter failure and no retained windows is a
  # first-observation hard error; the same failure with retained windows is a
  # last-known-good stale card.
  defp card_state(%ProviderMeterSnapshot{health: %{state: :stale, failure: failure}, windows: windows})
       when failure in @real_failures and map_size(windows) == 0,
       do: :error

  defp card_state(%ProviderMeterSnapshot{health: %{state: :stale}}), do: :stale
  defp card_state(_snapshot), do: :unavailable

  # --- identity / auth mode / plan (identity-scoped) -----------------------

  defp identity(%ProviderMeterSnapshot{provider_account_generation: generation}, true) when is_binary(generation) do
    %{state: :known, generation: generation, generation_label: generation_label(generation)}
  end

  defp identity(_snapshot, _known?), do: %{state: :unknown, generation: nil, generation_label: nil}

  defp auth_mode(%ProviderMeterSnapshot{auth_mode: mode}, true) when mode in [:subscription, :api_key] do
    %{value: mode, label: auth_mode_label(mode)}
  end

  defp auth_mode(_snapshot, _known?), do: %{value: :unknown, label: auth_mode_label(:unknown)}

  defp plan(%ProviderMeterSnapshot{plan: %{} = plan, provider_account_generation: generation}, true) when is_binary(generation) do
    tier = Map.get(plan, :tier, :unknown)

    %{
      state: :known,
      tier: tier,
      tier_label: tier_label(tier),
      source_label: source_label(Map.get(plan, :source)),
      freshness: Map.get(plan, :freshness),
      freshness_label: window_freshness_label(Map.get(plan, :freshness)),
      observed_at: datetime(Map.get(plan, :observed_at)),
      expires_at: datetime(Map.get(plan, :expires_at))
    }
  end

  defp plan(_snapshot, _known?), do: %{state: :none, tier: nil, tier_label: nil}

  # --- health / freshness --------------------------------------------------

  defp health(%ProviderMeterSnapshot{health: %{} = health} = snapshot) do
    state = Map.get(health, :state, :unavailable)
    failure = Map.get(health, :failure)

    %{
      state: state,
      label: health_label(state),
      failure: failure,
      failure_label: failure_label(failure),
      last_observed_at: datetime(Map.get(health, :last_observed_at)),
      last_attempt_at: datetime(Map.get(health, :last_attempt_at)),
      consecutive_failures: Map.get(health, :consecutive_failures, 0),
      age_seconds: snapshot.age_seconds,
      age_label: age_label(snapshot.age_seconds)
    }
  end

  defp health(_snapshot),
    do: %{
      state: :unavailable,
      label: health_label(:unavailable),
      failure: :no_observation,
      failure_label: failure_label(:no_observation),
      last_observed_at: nil,
      last_attempt_at: nil,
      consecutive_failures: 0,
      age_seconds: nil,
      age_label: nil
    }

  defp freshness(%ProviderMeterSnapshot{freshness: freshness}) do
    %{status: freshness, label: freshness_label(freshness)}
  end

  defp freshness(_snapshot), do: %{status: :unknown, label: freshness_label(:unknown)}

  defp observed_at(%ProviderMeterSnapshot{observed_at: value}), do: datetime(value)
  defp observed_at(_snapshot), do: nil

  defp ingested_at(%ProviderMeterSnapshot{ingested_at: value}), do: datetime(value)
  defp ingested_at(_snapshot), do: nil

  # --- windows -------------------------------------------------------------

  defp windows(%ProviderMeterSnapshot{windows: windows}, true) when is_map(windows) and map_size(windows) > 0 do
    windows
    |> Enum.map(fn {limit_id, window} -> window_view(limit_id, window) end)
    |> Enum.sort_by(&{Map.get(@window_kind_order, &1.kind, 9), &1.name, &1.limit_id})
  end

  defp windows(_snapshot, _known?), do: []

  defp window_view(limit_id, window) do
    coverage = Map.get(window, :coverage, :supported)
    kind = Map.get(window, :kind)
    used_percent = Map.get(window, :used_percent)
    standing = Map.get(window, :standing)
    window_freshness = Map.get(window, :freshness)

    %{
      limit_id: to_string(limit_id),
      name: Map.get(window, :name, "Meter"),
      kind: kind,
      kind_label: kind_label(kind),
      coverage: coverage,
      coverage_label: coverage_label(coverage),
      standing: standing,
      standing_label: standing_label(standing),
      used_percent: used_percent,
      remaining_percent: Map.get(window, :remaining_percent),
      used: Map.get(window, :used),
      limit: Map.get(window, :limit),
      remaining: Map.get(window, :remaining),
      duration_minutes: Map.get(window, :duration_minutes),
      resets_at: datetime(Map.get(window, :resets_at)),
      expires_at: datetime(Map.get(window, :expires_at)),
      observed_at: datetime(Map.get(window, :observed_at)),
      credits: credits(Map.get(window, :credits)),
      spend_control: spend_control(Map.get(window, :spend_control)),
      freshness: window_freshness,
      freshness_label: window_freshness_label(window_freshness),
      source_label: source_label(Map.get(window, :source)),
      meter: meter(coverage, used_percent)
    }
  end

  # An exact semantic meter value is exposed only for a supported window with a
  # numeric usage percentage; unsupported and empty-supported windows carry no
  # implied value. Zero is a real exact value, distinct from unknown.
  defp meter(:supported, used_percent) when is_number(used_percent) do
    %{kind: :exact, now: round(clamp_percent(used_percent)), min: 0, max: 100}
  end

  defp meter(_coverage, _used_percent), do: %{kind: :none}

  defp clamp_percent(percent) when percent < 0, do: 0
  defp clamp_percent(percent) when percent > 100, do: 100
  defp clamp_percent(percent), do: percent

  defp credits(%{status: status} = credits) do
    %{status: status, label: credit_status_label(status), amount: Map.get(credits, :amount)}
  end

  defp credits(_credits), do: nil

  defp spend_control(%{status: status} = spend_control) do
    %{status: status, label: spend_control_status_label(status), limit: Map.get(spend_control, :limit)}
  end

  defp spend_control(_spend_control), do: nil

  # --- announcements -------------------------------------------------------

  defp card_sentence(%{provider_label: label, state: :healthy} = card) do
    "#{label}: healthy#{plan_clause(card)}, #{window_clause(card)}."
  end

  defp card_sentence(%{provider_label: label, state: :partial} = card) do
    "#{label}: partial coverage#{plan_clause(card)}, #{window_clause(card)}."
  end

  defp card_sentence(%{provider_label: label, state: :stale} = card) do
    "#{label}: stale last known-good#{plan_clause(card)}, #{window_clause(card)}."
  end

  defp card_sentence(%{provider_label: label, state: :loading}), do: "#{label}: loading account meters."
  defp card_sentence(%{provider_label: label, state: :signed_out}), do: "#{label}: not signed in, no OAuth token."
  defp card_sentence(%{provider_label: label, state: :unknown}), do: "#{label}: no plan or quota available."
  defp card_sentence(%{provider_label: label, state: :error} = card), do: "#{label}: provider error, #{failure_phrase(card)}."
  defp card_sentence(%{provider_label: label}), do: "#{label}: account meters unavailable."

  defp plan_clause(%{plan: %{state: :known, tier_label: tier_label}}) when is_binary(tier_label), do: ", #{tier_label} plan"
  defp plan_clause(_card), do: ""

  defp window_clause(%{windows: []}), do: "no meters reported"
  defp window_clause(%{windows: [_ | _] = windows}), do: "#{length(windows)} #{pluralize(length(windows), "meter", "meters")}"
  defp window_clause(_card), do: "no meters reported"

  defp failure_phrase(%{health: %{failure_label: label}}) when is_binary(label), do: String.downcase(label)
  defp failure_phrase(_card), do: "no last known-good values"

  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_count, _singular, plural), do: plural

  # --- labels --------------------------------------------------------------

  defp provider_label(provider) do
    case CodingAgent.provider_descriptor(provider) do
      %{label: label} -> label
      _ -> provider |> to_string() |> String.capitalize()
    end
  end

  defp backend_label(%ProviderMeterSnapshot{backend: :app_server}), do: "App server"
  defp backend_label(%ProviderMeterSnapshot{backend: :openai_compat}), do: "OpenAI-compatible API"
  defp backend_label(_snapshot), do: "Backend unknown"

  defp status_label(:loading), do: "Loading…"
  defp status_label(:signed_out), do: "Not signed in"
  defp status_label(:unknown), do: ""
  defp status_label(:unavailable), do: "Unavailable"
  defp status_label(:error), do: "Provider error"
  defp status_label(:healthy), do: "Healthy"
  defp status_label(:partial), do: "Partial coverage"
  defp status_label(:stale), do: "Stale (last known-good)"

  defp auth_mode_label(:subscription), do: "Subscription"
  defp auth_mode_label(:api_key), do: "API key"
  defp auth_mode_label(_mode), do: "Unknown"

  defp tier_label(:free), do: "Free"
  defp tier_label(:pro), do: "Pro"
  defp tier_label(:team), do: "Team"
  defp tier_label(:business), do: "Business"
  defp tier_label(:enterprise), do: "Enterprise"
  defp tier_label(_tier), do: "Unknown"

  defp kind_label(:rate_limit), do: "Rate limit"
  defp kind_label(:credit), do: "Credits"
  defp kind_label(:spend_control), do: "Spend control"
  defp kind_label(_kind), do: "Meter"

  defp coverage_label(:supported), do: "Supported"
  defp coverage_label(:unsupported), do: "Not supported"
  defp coverage_label(:empty_supported), do: "Supported, no data reported"
  defp coverage_label(_coverage), do: "Unknown coverage"

  defp standing_label(:allowed), do: "Allowed"
  defp standing_label(:allowed_warning), do: "Approaching limit"
  defp standing_label(:rejected), do: "Rejected"
  defp standing_label(:unknown), do: "Unknown"
  defp standing_label(_standing), do: nil

  defp health_label(:healthy), do: "Healthy"
  defp health_label(:partial), do: "Partial"
  defp health_label(:stale), do: "Stale"
  defp health_label(:unavailable), do: "Unavailable"
  defp health_label(_state), do: "Unknown"

  defp failure_label(:authentication), do: "Authentication failed"
  defp failure_label(:malformed), do: "Malformed provider response"
  defp failure_label(:timeout), do: "Provider timed out"
  defp failure_label(:transport), do: "Transport error"
  defp failure_label(:no_observation), do: "Awaiting first observation"
  defp failure_label(:unknown_account_generation), do: "Account identity unknown"
  defp failure_label(:no_oauth_token), do: "No OAuth token"
  defp failure_label(:token_expired), do: "OAuth token expired"
  defp failure_label(nil), do: nil
  defp failure_label(other), do: other |> to_string() |> String.replace("_", " ")

  defp freshness_label(:fresh), do: "Fresh"
  defp freshness_label(:partial), do: "Partial"
  defp freshness_label(:stale), do: "Stale"
  defp freshness_label(_status), do: "Unknown"

  defp age_label(nil), do: nil
  defp age_label(seconds) when seconds < 60, do: "#{seconds} #{pluralize(seconds, "second", "seconds")} old"

  defp age_label(seconds) when seconds < 3_600 do
    minutes = div(seconds, 60)
    "#{minutes} #{pluralize(minutes, "minute", "minutes")} old"
  end

  defp age_label(seconds) when seconds < 86_400 do
    hours = div(seconds, 3_600)
    "#{hours} #{pluralize(hours, "hour", "hours")} old"
  end

  defp age_label(seconds) do
    days = div(seconds, 86_400)
    "#{days} #{pluralize(days, "day", "days")} old"
  end

  defp window_freshness_label(:fresh), do: "Fresh"
  defp window_freshness_label(:stale), do: "Stale"
  defp window_freshness_label(_freshness), do: "Unknown"

  defp credit_status_label(:available), do: "Available"
  defp credit_status_label(:exhausted), do: "Exhausted"
  defp credit_status_label(:unlimited), do: "Unlimited"
  defp credit_status_label(:unsupported), do: "Not supported"
  defp credit_status_label(_status), do: "Unknown"

  defp spend_control_status_label(:enabled), do: "Enabled"
  defp spend_control_status_label(:disabled), do: "Disabled"
  defp spend_control_status_label(:unsupported), do: "Not supported"
  defp spend_control_status_label(_status), do: "Unknown"

  defp source_label(nil), do: nil
  defp source_label(source), do: source |> to_string() |> String.replace("_", " ")

  # A short, non-reversible display token for the opaque account generation so
  # the card can show that identity changed without printing the full value.
  defp generation_label(generation) when is_binary(generation) do
    generation
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 8)
  end

  defp datetime(%DateTime{} = value), do: value
  defp datetime(_value), do: nil
end
