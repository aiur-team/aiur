defmodule Aiur.AllowedContributors.MembershipTest do
  use ExUnit.Case, async: true

  alias Aiur.AllowedContributors.Membership

  @org %{id: 9919, login: "acme"}
  @author %{id: 42, login: "alice"}

  defp member_body(overrides \\ %{}) do
    Map.merge(%{"state" => "active", "role" => "member", "user" => %{"id" => 42}, "organization" => %{"id" => 9919}}, overrides)
  end

  # Answers from a list of canned responses and records each URL asked.
  defp scripted(responses) do
    {:ok, agent} = Agent.start_link(fn -> {responses, []} end)

    get = fn url ->
      Agent.get_and_update(agent, fn {[next | rest], urls} -> {next, {rest, [url | urls]}} end)
    end

    {get, fn -> Agent.get(agent, fn {_rest, urls} -> Enum.reverse(urls) end) end}
  end

  test "an active member with matching ids is a member, and the answer is cached" do
    {get, urls} = scripted([{:ok, %{status: 200, body: member_body()}}])

    assert {:member, cache} = Membership.check(%{}, @org, @author, 0, get)
    assert {:member, ^cache} = Membership.check(cache, @org, @author, 299_000, get)
    assert [url] = urls.()
    assert url =~ "/orgs/acme/memberships/alice"
  end

  test "a pending invitation is not membership" do
    {get, _urls} = scripted([{:ok, %{status: 200, body: member_body(%{"state" => "pending"})}}])
    assert {{:not_member, :membership_pending}, _cache} = Membership.check(%{}, @org, @author, 0, get)
  end

  # Independent review of #2958: the memberships endpoint also answers for
  # billing managers (`role: "billing_manager"`, `state: "active"`), who are
  # not members of the org. Only `admin` and `member` count, and a missing or
  # unknown role fails closed.
  test "an org billing manager is not a member" do
    {get, _urls} = scripted([{:ok, %{status: 200, body: member_body(%{"role" => "billing_manager"})}}])
    assert {{:not_member, :not_org_member_role}, _cache} = Membership.check(%{}, @org, @author, 0, get)
  end

  test "a membership answer with no role fails closed" do
    {get, _urls} = scripted([{:ok, %{status: 200, body: Map.delete(member_body(), "role")}}])
    assert {{:not_member, :not_org_member_role}, _cache} = Membership.check(%{}, @org, @author, 0, get)
  end

  test "an org admin is a member" do
    {get, _urls} = scripted([{:ok, %{status: 200, body: member_body(%{"role" => "admin"})}}])
    assert {:member, _cache} = Membership.check(%{}, @org, @author, 0, get)
  end

  test "an outside collaborator (404) is negative, cached briefly, and re-asked after a minute" do
    {get, urls} = scripted([{:ok, %{status: 404}}, {:ok, %{status: 200, body: member_body()}}])

    assert {{:not_member, :not_org_member}, cache} = Membership.check(%{}, @org, @author, 0, get)
    assert {{:not_member, :not_org_member}, cache} = Membership.check(cache, @org, @author, 59_000, get)
    assert {:member, _cache} = Membership.check(cache, @org, @author, 61_000, get)
    assert length(urls.()) == 2
  end

  test "a user who left the org stops counting once the positive TTL expires" do
    {get, _urls} = scripted([{:ok, %{status: 200, body: member_body()}}, {:ok, %{status: 404}}])

    assert {:member, cache} = Membership.check(%{}, @org, @author, 0, get)
    later = Membership.positive_ttl_ms() + 1
    assert {{:not_member, :not_org_member}, _cache} = Membership.check(cache, @org, @author, later, get)
  end

  test "a login now held by a different account fails the user-id binding" do
    {get, _urls} = scripted([{:ok, %{status: 200, body: member_body(%{"user" => %{"id" => 7}})}}])
    assert {{:not_member, :user_id_mismatch}, _cache} = Membership.check(%{}, @org, @author, 0, get)
  end

  test "an org renamed and its old name re-registered fails the org-id binding" do
    {get, _urls} = scripted([{:ok, %{status: 200, body: member_body(%{"organization" => %{"id" => 1}})}}])
    assert {{:not_member, :org_id_mismatch}, _cache} = Membership.check(%{}, @org, @author, 0, get)
  end

  test "rate limits, forbidden, server and transport errors fail closed and are held only briefly" do
    for response <- [{:ok, %{status: 429}}, {:ok, %{status: 403}}, {:ok, %{status: 503}}, {:error, :timeout}, :garbage] do
      {get, urls} = scripted([response, {:ok, %{status: 200, body: member_body()}}])
      assert {{:unverified, _reason}, cache} = Membership.check(%{}, @org, @author, 0, get)
      # Within a minute the outage answer is reused — no request per sighting —
      # and it still never admits.
      assert {{:unverified, _reason}, cache} = Membership.check(cache, @org, @author, 59_000, get)
      assert length(urls.()) == 1, "re-asked during an outage for #{inspect(response)}"
      # After it expires the next sighting asks again and can recover.
      assert {:member, _cache} = Membership.check(cache, @org, @author, 61_000, get)
    end
  end

  test "a login that is not a plain GitHub login is never sent to the API" do
    get = fn _url -> flunk("must not request") end
    author = %{id: 42, login: "../../user"}
    assert {{:not_member, :invalid_login}, _cache} = Membership.check(%{}, @org, author, 0, get)
  end
end
