defmodule Aiur.Ownership.MigrationTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Aiur.Ownership.{MigrateCLI, Migration}

  @map %{"agent" => "PC", "nuc" => "Nook"}
  @pc "aaaaaaaaaaaaaaaaaaaaaaaaaa"

  defp t(n, labels, owner \\ nil), do: %{ticket: to_string(n), labels: labels, owner: owner}
  defp owner(label, state \\ "owned"), do: %{state: state, gateway_id: @pc, gateway_label: label}

  test "plan maps labels to claim, claim, ambiguous, skip" do
    tickets = [t(1, ["agent:todo"]), t(2, ["nuc:in-progress"]), t(3, ["agent:todo", "nuc:done"]), t(4, [])]

    assert Migration.plan(tickets, @map) == [
             {:claim, "1", "PC"},
             {:claim, "2", "Nook"},
             {:ambiguous, "3", ["agent", "nuc"]},
             {:skip, "4", :no_state_label}
           ]
  end

  test "non-state, unmapped and parked labels never claim; case and spaces are tolerated" do
    tickets = [t(1, ["agent:parked", "nuc:parked"]), t(2, ["agent:queued", "agent:merge-queued"]), t(3, ["human:todo"]), t(4, [" Agent:Todo "])]

    assert Migration.plan(tickets, @map) ==
             [{:skip, "1", :no_state_label}, {:skip, "2", :no_state_label}, {:skip, "3", :no_state_label}, {:claim, "4", "PC"}]
  end

  test "existing records: same gateway is already, released is claimable, other is a conflict" do
    tickets = [t(1, ["agent:todo"], owner("PC")), t(2, ["agent:todo"], owner("PC", "released")), t(3, ["agent:todo"], owner("Nook"))]

    assert Migration.plan(tickets, @map) ==
             [{:already, "1", "PC"}, {:claim, "2", "PC"}, {:conflict, "3", labelled: "PC", owner: "Nook"}]
  end

  defp cli_opts(extra) do
    test = self()

    Keyword.merge(
      [
        maps: ["agent=PC"],
        identity_fun: fn -> %{gateway_id: @pc, gateway_label: "PC", daemon_key: "pc"} end,
        list_fun: fn -> {:ok, [%{ticket: "1", labels: ["agent:todo"]}, %{ticket: "2", labels: ["agent:todo"]}, %{ticket: "3", labels: []}]} end,
        owners_fun: fn -> {:ok, [{"2", {:ok, %{record: owner("PC")}}}]} end,
        claim_fun: fn ticket, gateway ->
          send(test, {:claim, ticket, gateway})
          {:won, :record}
        end,
        error_fun: fn m -> send(test, {:error, m}) end,
        repo: "o/r"
      ],
      extra
    )
  end

  test "dry run performs no claims" do
    out = capture_io(fn -> assert MigrateCLI.run(cli_opts([])) == 0 end)
    refute_received {:claim, _, _}
    assert out =~ "1 claim, 1 already"
    assert out =~ "writes: 0"
  end

  test "--apply claims only unowned tickets and reports the write count; a re-run writes nothing" do
    out = capture_io(fn -> assert MigrateCLI.run(cli_opts(apply: true)) == 0 end)
    assert_received {:claim, "1", "PC"}
    refute_received {:claim, _, _}
    assert out =~ "writes: 1"

    rerun = [owners_fun: fn -> {:ok, [{"1", {:ok, %{record: owner("PC")}}}, {"2", {:ok, %{record: owner("PC")}}}]} end]
    out = capture_io(fn -> assert MigrateCLI.run(cli_opts([apply: true] ++ rerun)) == 0 end)
    refute_received {:claim, _, _}
    assert out =~ "writes: 0"
  end

  test "an unknown claim outcome exits 75 and is not counted as a write" do
    out = capture_io(fn -> assert MigrateCLI.run(cli_opts(apply: true, claim_fun: fn _, _ -> {:unknown, :boom} end)) == 75 end)
    assert out =~ "writes: 0"
  end

  test "a peer gateway or missing --map is refused before any read" do
    reader = fn -> flunk("must not read") end
    assert MigrateCLI.run(cli_opts(maps: ["nuc=Nook"], list_fun: reader)) == 64
    assert_received {:error, "aiur: unknown gateway" <> _}
    assert MigrateCLI.run(cli_opts(maps: [], list_fun: reader)) == 64
  end
end
