defmodule Aiur.AllowedContributors.Membership do
  @moduledoc """
  Id-verified GitHub org membership, checked over REST with the operator's
  credential and cached briefly.

  The endpoint is `GET /orgs/{org}/memberships/{username}`. It reports both
  public and concealed (private) members when the caller can see the org's
  membership, and its body carries the ids this check binds to. A member
  counts only when **all** of these hold on a `200`:

    * `state == "active"` — an invitation (`pending`) is not membership;
    * `user.id` equals the issue author's numeric id — a login renamed or
      re-registered between the event and this call answers for someone else;
    * `organization.id` equals the id in the allow-list — an org renamed and
      its old name re-registered by a stranger answers for the stranger's org.

  Fail closed everywhere else. A `404` (outside collaborator, non-member, or
  an org the token cannot see) is a negative answer, cached for
  60 seconds so a flood cannot turn into a request per issue. A
  rate limit, `403`, `5xx`, or transport error is `:unverified`: it never
  admits, the issue is deferred and re-evaluated on a later sighting, and the
  answer is held for 60 seconds so an outage is not re-asked once per open
  issue per poll on the shared GitHub budget. A positive answer is
  cached for 300 seconds — that TTL is the longest a user who left the org
  can still count.
  """

  alias Aiur.AllowedContributors.AllowList
  alias Aiur.GitHub.Transport

  @positive_ttl_ms 300_000
  @negative_ttl_ms 60_000
  @unverified_ttl_ms 60_000
  @max_entries 1_000

  @type org :: %{id: pos_integer(), login: String.t()}
  @type author :: %{id: pos_integer(), login: String.t()}
  @type verdict :: :member | {:not_member, atom()} | {:unverified, term()}
  @type cache :: %{optional({pos_integer(), pos_integer()}) => {verdict(), integer()}}

  @doc "Positive-result cache lifetime in milliseconds."
  @spec positive_ttl_ms() :: pos_integer()
  def positive_ttl_ms, do: @positive_ttl_ms

  @doc """
  Checks `author`'s membership of `org`. `get` is a one-argument function
  performing a GitHub GET for a URL; `now_ms` is a monotonic clock reading.
  """
  @spec check(cache(), org(), author(), integer(), (String.t() -> term())) :: {verdict(), cache()}
  def check(cache, org, author, now_ms, get) do
    key = {org.id, author.id}

    case Map.get(cache, key) do
      {verdict, expires_at} when expires_at > now_ms -> {verdict, cache}
      _missing_or_expired -> ask(cache, key, org, author, now_ms, get)
    end
  end

  defp ask(cache, key, org, author, now_ms, get) do
    verdict =
      if AllowList.valid_login?(author.login) and AllowList.valid_login?(org.login),
        do: interpret(get.(url(org.login, author.login)), org, author),
        else: {:not_member, :invalid_login}

    {verdict, store(cache, key, verdict, now_ms)}
  end

  defp url(org_login, user_login), do: "#{Transport.base_url()}/orgs/#{org_login}/memberships/#{user_login}"

  defp interpret({:ok, %{status: 200, body: body}}, org, author) when is_map(body) do
    cond do
      get_in(body, ["organization", "id"]) != org.id -> {:not_member, :org_id_mismatch}
      get_in(body, ["user", "id"]) != author.id -> {:not_member, :user_id_mismatch}
      body["state"] != "active" -> {:not_member, :membership_pending}
      true -> :member
    end
  end

  defp interpret({:ok, %{status: 404}}, _org, _author), do: {:not_member, :not_org_member}
  defp interpret({:ok, %{status: status}}, _org, _author), do: {:unverified, {:http_status, status}}
  defp interpret({:error, reason}, _org, _author), do: {:unverified, {:transport, reason}}
  defp interpret(_other, _org, _author), do: {:unverified, :invalid_response}

  defp store(cache, key, verdict, now_ms) do
    ttl = ttl_for(verdict)
    cache = if map_size(cache) >= @max_entries, do: prune(cache, now_ms), else: cache
    Map.put(cache, key, {verdict, now_ms + ttl})
  end

  defp ttl_for(:member), do: @positive_ttl_ms
  defp ttl_for({:not_member, _reason}), do: @negative_ttl_ms
  defp ttl_for({:unverified, _reason}), do: @unverified_ttl_ms

  defp prune(cache, now_ms) do
    live = Map.filter(cache, fn {_key, {_verdict, expires_at}} -> expires_at > now_ms end)
    if map_size(live) >= @max_entries, do: %{}, else: live
  end
end
