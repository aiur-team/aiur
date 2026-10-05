defmodule Aiur.AllowedContributors.Intake do
  @moduledoc """
  The allowed-contributor admission decision, as a function of the intake
  server's state.

  Order matters and every step fails closed:

    1. an issue that already has a terminal decision is a duplicate;
    2. the shape screen (`Policy.screen/2`) rejects non-users, App-created
       issues, Aiur's own accounts, and malformed candidates;
    3. no allow-list snapshot → deferred; no file → rejected; an unparseable
       file → rejected;
    4. the author's numeric id listed as a user → allowed;
    5. otherwise each listed org, in id order, via `Membership.check/5` —
       the first verified membership admits; an unverifiable answer with no
       admission defers;
    6. the per-author rate limit drops surplus.

  `:deferred` is the only non-terminal outcome: the issue is re-evaluated the
  next time a producer sees it, so a transient GitHub failure never turns
  into a permanent miss — and never into an admission either.
  """

  alias Aiur.AllowedContributors.{Ledger, Membership, Policy, RateLimit}

  @rate_window_ms 3_600_000

  @type outcome :: :duplicate | {:accept, String.t()} | {:reject, term()} | {:deferred, term()}

  @spec decide(map(), map()) :: {outcome(), map()}
  def decide(state, candidate) do
    with :fresh <- freshness(state, candidate),
         :ok <- Policy.screen(candidate, state.aiur_logins_fun.()),
         {:ok, allowlist} <- usable_allowlist(state.snapshot),
         {{:allowed, via}, state} <- admission(state, allowlist, candidate) do
      rate_limit(state, candidate, via)
    else
      :duplicate -> {:duplicate, state}
      {:reject, _reason} = outcome -> {outcome, state}
      {:deferred, _reason} = outcome -> {outcome, state}
      {outcome, %{} = state} -> {outcome, state}
    end
  end

  defp freshness(state, %{number: number}) when is_integer(number) and number > 0 do
    if Ledger.seen?(state.ledger, number), do: :duplicate, else: :fresh
  end

  defp freshness(_state, _candidate), do: :fresh

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
    {verdict, cache} = Membership.check(state.membership, org, author, state.mono_fun.(), membership_get(state))
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
    case RateLimit.admit(state.rate, candidate.author_id, state.mono_fun.(), state.rate_limit, @rate_window_ms) do
      {:ok, rate} -> {{:accept, via}, %{state | rate: rate}}
      {:limited, rate} -> {{:reject, :rate_limited}, %{state | rate: rate}}
    end
  end

  defp membership_get(state) do
    fn url -> state.request_fun.(%{method: :get, url: url, token: state.token_fun.(), caller: "allowed_contributors"}) end
  end
end
