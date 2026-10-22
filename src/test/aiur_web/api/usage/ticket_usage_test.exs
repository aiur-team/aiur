defmodule AiurWeb.Api.Usage.TicketUsageTest do
  use ExUnit.Case, async: true

  alias Aiur.TestSupport.GroupedScopes, as: GS
  alias AiurWeb.Api.Usage.TicketUsage

  @repository {"its-everdred", "aiur"}

  # Ticket 5692 spends in two runs on two models; ticket 77 and a same-numbered
  # ticket in another repository spend too, so a lookup that keyed on the bare
  # number or ignored the repository would absorb their tokens.
  defp records do
    [
      GS.claude_record(1, ticket: GS.identity(5692), run_id: "run-a", tokens: %{input: 100, output: 20}, cost: GS.money("0.25")),
      GS.codex_record(2, ticket: GS.identity(5692), run_id: "run-b", tokens: %{input: 50}),
      GS.claude_record(3, ticket: GS.identity(77), run_id: "run-a", tokens: %{input: 9_999}, cost: GS.money("9.00")),
      GS.claude_record(4, ticket: GS.identity("someone", "fork", 5692), run_id: "run-a", tokens: %{input: 777}),
      GS.claude_record(5, ticket: nil, run_id: "run-a", tokens: %{input: 5})
    ]
  end

  defp opts(records, overrides \\ []) do
    Keyword.merge(
      [
        scan_fun: fn options -> {:ok, page(records, options)} end,
        cells_snapshot_fun: fn -> GS.source(records) end,
        repository_fun: fn -> {:ok, @repository} end
      ],
      overrides
    )
  end

  defp keys(map), do: map |> Map.keys() |> Enum.sort()

  defp page(records, options) do
    records |> Enum.filter(&(&1.position > Keyword.fetch!(options, :after))) |> Enum.take(Keyword.fetch!(options, :limit))
  end

  test "reports only the asked ticket's ledger numbers, never another ticket's or repository's" do
    assert {:ok, payload} = TicketUsage.fetch("5692", opts(records()))

    assert payload["schema_version"] == 1
    assert payload["ticket"] == %{"owner" => "its-everdred", "repository" => "aiur", "identifier" => "5692"}
    assert payload["totals"]["tokens"] == %{"input" => 150, "output" => 20}
    assert payload["totals"]["provider_reported"] == %{"USD" => "0.25"}
    assert Enum.map(payload["by_model"], & &1["model"]) |> Enum.sort() == ["claude-sonnet-4-6", "gpt-5.6-terra"]
    assert Enum.map(payload["by_provider"], & &1["provider"]) |> Enum.sort() == ["claude", "codex"]
  end

  test "splits usage per session with that session's own models and providers" do
    assert {:ok, payload} = TicketUsage.fetch("5692", opts(records()))
    sessions = Map.new(payload["sessions"], &{&1["run_id"], &1})

    assert Map.keys(sessions) |> Enum.sort() == ["run-a", "run-b"]
    assert sessions["run-a"]["tokens"] == %{"input" => 100, "output" => 20}
    assert [%{"model" => "claude-sonnet-4-6", "tokens" => %{"input" => 100, "output" => 20}}] = sessions["run-a"]["by_model"]
    assert [%{"provider" => "claude"}] = sessions["run-a"]["by_provider"]
    assert [%{"model" => "gpt-5.6-terra", "tokens" => %{"input" => 50}}] = sessions["run-b"]["by_model"]
  end

  test "money stays an exact decimal string and the payload encodes as JSON" do
    assert {:ok, payload} = TicketUsage.fetch("5692", opts(records()))
    assert %{"amount" => %{"USD" => amount}} = payload["totals"]["api_equivalent"]
    assert is_binary(amount)
    assert {:ok, _json} = Jason.encode(payload)
  end

  test "resolves identities found on any ledger page" do
    assert {:ok, payload} = TicketUsage.fetch("5692", opts(records(), scan_page: 1))
    assert payload["totals"]["tokens"] == %{"input" => 150, "output" => 20}
  end

  # The payload is a versioned contract for an external client: every key is
  # pinned so an upstream map growing a field cannot leak into schema 1.
  test "pins the exact schema 1 keys at every level" do
    assert {:ok, payload} = TicketUsage.fetch("5692", opts(records()))
    measure = ~w(api_equivalent provider_reported tokens)

    assert keys(payload) == ~w(authority by_model by_provider currency freshness schema_version sessions state ticket totals)
    assert keys(payload["ticket"]) == ~w(identifier owner repository)
    assert keys(payload["authority"]) == ~w(aggregate_generation price_table_revision schema_version source_generation source_position)
    assert keys(payload["freshness"]) == ~w(ledger_position projected_position status)
    assert keys(payload["totals"]) == measure
    assert keys(payload["totals"]["api_equivalent"]) == ~w(amount coverage)
    assert keys(payload["totals"]["api_equivalent"]["coverage"]) == ~w(known reasons status unknown)
    assert keys(hd(payload["by_model"])) == Enum.sort(["model" | measure])
    assert keys(hd(payload["by_provider"])) == Enum.sort(["provider", "upstream_provider" | measure])

    session = hd(payload["sessions"])
    assert keys(session) == Enum.sort(["by_model", "by_provider", "run_id" | measure])
    assert keys(hd(session["by_model"])) == Enum.sort(["model" | measure])
    assert keys(hd(session["by_provider"])) == Enum.sort(["provider", "upstream_provider" | measure])
  end

  # After compaction retires a prefix, a miss may be a ticket that spent in the
  # retired range, so it must not claim "no usage recorded".
  test "a miss behind a retired ledger prefix is unresolvable, not not-found" do
    retained = Enum.drop(records(), 2)
    assert TicketUsage.fetch("5692", opts(retained, cells_snapshot_fun: fn -> GS.source(records()) end)) == {:error, :usage_unresolvable}

    assert TicketUsage.fetch("5692", opts([], cells_snapshot_fun: fn -> GS.source(records()) end)) == {:error, :usage_unresolvable}
  end

  test "a ticket with no retained ledger records is not found" do
    assert TicketUsage.fetch("4242", opts(records())) == {:error, :usage_not_found}
  end

  test "a ticket recorded only in another repository is not found here" do
    others = [GS.claude_record(1, ticket: GS.identity("someone", "fork", 31))]
    assert TicketUsage.fetch("31", opts(others)) == {:error, :usage_not_found}
  end

  test "rejects identifiers that are not GitHub issue numbers before reading the ledger" do
    refuse = [scan_fun: fn _options -> flunk("ledger read for an invalid identifier") end]

    for identifier <- ["", "0", "abc", "12a", "../1", "-3", nil] do
      assert TicketUsage.fetch(identifier, opts([], refuse)) == {:error, :invalid_identifier}
    end
  end

  test "an unreadable ledger, aggregate or repository is unavailable rather than empty" do
    unavailable = [
      scan_fun: fn _options -> {:error, :corrupt} end,
      cells_snapshot_fun: fn -> :not_running end,
      repository_fun: fn -> {:error, :missing_configured_repository} end
    ]

    for {key, fun} <- unavailable do
      assert TicketUsage.fetch("5692", opts(records(), [{key, fun}])) == {:error, :usage_unavailable}
    end

    exiting = [scan_fun: fn _options -> exit(:noproc) end]
    assert TicketUsage.fetch("5692", opts(records(), exiting)) == {:error, :usage_unavailable}

    down = [cells_snapshot_fun: fn -> exit(:noproc) end]
    assert TicketUsage.fetch("5692", opts(records(), down)) == {:error, :usage_unavailable}

    unhealthy = [cells_snapshot_fun: fn -> GS.source(records(), %{health: {:unavailable, :corrupt}}) end]
    assert TicketUsage.fetch("5692", opts(records(), unhealthy)) == {:error, :usage_unavailable}
  end
end
