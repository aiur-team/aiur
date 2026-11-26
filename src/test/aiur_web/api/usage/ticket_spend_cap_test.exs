defmodule AiurWeb.Api.Usage.TicketSpendCapTest do
  use ExUnit.Case, async: true

  alias Aiur.Issue
  alias Aiur.TestSupport.GroupedScopes, as: GS
  alias AiurWeb.Api.Usage.TicketSpendCap

  test "PUT uses a repository-qualified tracker identity, not a bare issue number" do
    owner = self()
    identity = GS.identity(5693)
    issue = %Issue{id: "node-5693", identifier: "5693", title: "cap", state: "todo", tracker_identity: identity}

    opts = [
      repository_fun: fn -> {:ok, {identity.owner, identity.repository}} end,
      fetch_issue_states_fun: fn ["5693"] -> {:ok, [issue]} end,
      store_put_fun: fn resolved, amount ->
        send(owner, {:stored, resolved, amount})
        {:ok, %{}}
      end
    ]

    assert {:ok, %{}} = TicketSpendCap.put("5693", %{"amount" => "2.50"}, opts)
    assert_receive {:stored, ^identity, "2.50"}, 1_000
  end

  test "a same-numbered ticket from another repository is rejected" do
    identity = GS.identity("someone", "fork", 5693)
    issue = %Issue{id: "fork-node", identifier: "5693", title: "fork", state: "todo", tracker_identity: identity}

    opts = [
      repository_fun: fn -> {:ok, {"its-everdred", "aiur"}} end,
      fetch_issue_states_fun: fn ["5693"] -> {:ok, [issue]} end,
      store_put_fun: fn _, _ -> flunk("foreign identity reached the store") end
    ]

    assert TicketSpendCap.put("5693", %{"amount" => "2.50"}, opts) == {:error, :ticket_unresolvable}
  end

  test "a missing ticket and an unjoinable identity stay distinct" do
    missing = [repository_fun: fn -> {:ok, {"its-everdred", "aiur"}} end, fetch_issue_states_fun: fn ["5693"] -> {:ok, []} end]

    unjoinable = [
      repository_fun: fn -> {:ok, {"its-everdred", "aiur"}} end,
      fetch_issue_states_fun: fn ["5693"] -> {:ok, [%Issue{id: "node-5693", identifier: "5693", title: "cap", state: "todo"}]} end
    ]

    assert TicketSpendCap.put("5693", %{"amount" => "2.50"}, missing) == {:error, :ticket_not_found}
    assert TicketSpendCap.put("5693", %{"amount" => "2.50"}, unjoinable) == {:error, :ticket_unresolvable}
  end
end
