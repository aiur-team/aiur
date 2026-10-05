defmodule Aiur.AllowedContributors.Intake do
  @moduledoc """
  The allowed-contributor admission decision, as a function of the intake
  server's `State`.

  Order matters and every step fails closed:

    1. an issue that already has a terminal decision is a duplicate;
    2. the shape screen (`Policy.screen/2`) rejects non-users, App-created
       issues, Aiur's own accounts, and malformed candidates;
    3. an issue older than the seen-set retention (or with no creation time)
       is refused, so a pruned issue number can never be woken a second time
       by a late webhook redelivery;
    4. no allow-list snapshot → deferred; no file → rejected; an unparseable
       file → rejected;
    5. the author's numeric id listed as a user → allowed;
    6. otherwise each listed org, in id order, via `Membership.check/5` —
       the first verified membership admits; an unverifiable answer with no
       admission defers;
    7. the per-author rate limit drops surplus.

  `:deferred` is the only non-terminal outcome: the issue is re-evaluated the
  next time a producer sees it, so a transient GitHub failure never turns
  into a permanent miss — and never into an admission either.
  """

  alias Aiur.AllowedContributors.{Ledger, Membership, Policy, RateLimit, State}

  @rate_window_ms 3_600_000

  @type outcome :: :duplicate | {:accept, String.t()} | {:reject, term()} | {:deferred, term()}

  @spec decide(State.t(), map()) :: {outcome(), State.t()}
  def decide(%State{} = state, candidate) do
    with :fresh <- freshness(state, candidate),
         :ok <- Policy.screen(candidate, state.aiur_logins_fun.()),
         :ok <- within_horizon(candidate, state.clock_fun.()),
         {:ok, allowlist} <- usable_allowlist(state.snapshot),
         {{:allowed, via}, state} <- admission(state, allowlist, candidate) do
      rate_limit(state, candidate, via)
    else
      :duplicate -> {:duplicate, state}
      {:reject, _reason} = outcome -> {outcome, state}
      {:deferred, _reason} = outcome -> {outcome, state}
      {outcome, %State{} = state} -> {outcome, state}
    end
  end

  defp freshness(state, %{number: number}) when is_integer(number) and number > 0 do
    if Ledger.seen?(state.ledger, number), do: :duplicate, else: :fresh
  end

  defp freshness(_state, _candidate), do: :fresh

  defp within_horizon(%{created_at: %DateTime{} = created_at}, now_ms) do
    if now_ms - DateTime.to_unix(created_at, :millisecond) < Ledger.retention_ms(),
      do: :ok,
      else: {:reject, :stale_issue}
  end

  defp within_horizon(_candidate, _now_ms), do: {:reject, :missing_created_at}

  defp usable_allowlist(nil), do: {:deferred, :allowlist_unavailable}
  defp usable_allowlist(:absent), do: {:reject, :allowlist_absent}
  defp usable_allowlist(%{allowlist: {:invalid, _reason}}), do: {:reject, :allowlist_invalid}
  defp usable_allowlist(%{allowlist: allowlist}), do: {:ok, allowlist}

  defp admission(state, allowlist, candidate) do
    if Policy.user_listed?(allowlist, candidate.author_id) do
      {{:allowed, "user"}, state}
    else
      allowlist.orgs |> Enum.sort() |> check_orgs(state, candidate, :not_allowed)
    end
  end

  defp check_orgs([], state, _candidate, fallback), do: {fallback_outcome(fallback), state}

  defp check_orgs([{org_id, org_login} | rest], state, candidate, fallback) do
    org = %{id: org_id, login: org_login}
    author = %{id: candidate.author_id, login: candidate.author_login || ""}
    {verdict, cache} = Membership.check(state.membership, org, author, state.clock_fun.(), membership_get(state))
    state = %{state | membership: cache}

    case verdict do
      :member -> {{:allowed, "org:#{org_id}"}, state}
      {:unverified, _reason} -> check_orgs(rest, state, candidate, :membership_unverified)
      {:not_member, _reason} -> check_orgs(rest, state, candidate, fallback)
    end
  end

  defp fallback_outcome(:membership_unverified), do: {:deferred, :membership_unverified}
  defp fallback_outcome(reason), do: {:reject, reason}

  defp rate_limit(state, candidate, via) do
    case RateLimit.admit(state.ledger.rate, candidate.author_id, state.clock_fun.(), state.rate_limit, @rate_window_ms) do
      {:ok, rate} -> {{:accept, via}, %{state | ledger: Ledger.put_rate(state.ledger, rate)}}
      {:limited, rate} -> {{:reject, :rate_limited}, %{state | ledger: Ledger.put_rate(state.ledger, rate)}}
    end
  end

  defp membership_get(state) do
    fn url -> state.request_fun.(%{method: :get, url: url, token: state.token_fun.(), caller: "allowed_contributors"}) end
  end
end
