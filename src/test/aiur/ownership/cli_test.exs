defmodule Aiur.Ownership.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Aiur.Ownership.{CLI, Record}

  @pc "aaaaaaaaaaaaaaaaaaaaaaaaaa"
  @nook "bbbbbbbbbbbbbbbbbbbbbbbbbb"
  @now ~U[2026-11-06 12:00:05Z]

  defp record(overrides \\ %{}) do
    {:ok, record} =
      Record.new(
        Map.merge(
          %{
            repo: "o/r",
            ticket: "12",
            state: "owned",
            gateway_id: @pc,
            gateway_label: "PC",
            daemon_key: "pc",
            epoch: 4,
            previous_epoch: 3,
            actor: %{kind: "daemon", id: "pc"},
            reason: "dispatch",
            at: "2026-11-06T12:00:00Z"
          },
          overrides
        )
      )

    record
  end

  defp liveness(status, source \\ nil, age \\ nil), do: fn _record -> %{status: status, source: source, age_ms: age} end

  defp base_opts(extra) do
    test = self()
    observed = %{oid: "oid1", repository_id: "R1", record: record()}

    defaults = [
      ticket: "12",
      repo: "o/r",
      now: @now,
      error_fun: fn message -> send(test, {:error, message}) end,
      identity_fun: fn -> %{gateway_id: @nook, gateway_label: "Nook", daemon_key: "nook"} end,
      read_fun: fn "o/r", "12" -> {:ok, observed} end,
      transfer_fun: fn "o/r", "12", ^observed, owner ->
        send(test, {:transfer, owner})

        {:ok, new} =
          Record.new(
            %{
              record()
              | epoch: 5,
                previous_epoch: 4,
                gateway_id: owner.gateway_id,
                gateway_label: owner.gateway_label,
                daemon_key: owner.daemon_key,
                actor: owner.actor,
                reason: "transfer",
                note: owner.note
            }
            |> Map.from_struct()
          )

        {:won, new}
      end,
      open_pr_fun: fn "12" -> {:ok, %{"number" => 9}} end,
      disable_fun: fn number ->
        send(test, {:disable, number})
        {:ok, [:auto_merge_disabled]}
      end
    ]

    Keyword.merge(defaults, extra)
  end

  defp assign_opts(extra), do: base_opts(Keyword.merge([to: "nook", reason: "x", liveness_fun: liveness(:offline, :heartbeat, 600_000)], extra))

  describe "assign" do
    test "offline owner: writes the transfer with a human actor, then disables auto-merge" do
      out = capture_io(fn -> send(self(), {:code, CLI.assign(assign_opts(json: true))}) end)

      assert_received {:code, 0}
      assert_received {:transfer, %{gateway_id: @nook, gateway_label: "Nook", daemon_key: "nook", note: "x", actor: %{kind: "human"}}}
      assert_received {:disable, 9}
      assert %{"epoch" => 5, "previous_epoch" => 4, "auto_merge" => "disabled", "forced" => false, "owner" => %{"gateway_label" => "Nook"}} = Jason.decode!(out)
    end

    test "disables auto-merge only after the transfer" do
      capture_io(fn -> CLI.assign(assign_opts([])) end)

      assert {:messages, [{:transfer, _}, {:disable, 9}]} = Process.info(self(), :messages)
    end

    test "an owner of unknown liveness is refused and nothing is written" do
      opts = assign_opts(liveness_fun: liveness(:unknown))
      assert CLI.assign(opts) == 64
      assert_received {:error, "aiur: owner liveness unknown; treat as online"}
      refute_received {:transfer, _}
    end

    test "a live owner is refused without --force" do
      assert CLI.assign(assign_opts(liveness_fun: liveness(:online, :heartbeat, 20_000))) == 64
      assert_received {:error, "aiur: owner is online; ask it to release"}
      refute_received {:transfer, _}
    end

    test "--force over a live owner writes, with a forced note" do
      out = capture_io(fn -> send(self(), {:code, CLI.assign(assign_opts(liveness_fun: liveness(:online, :heartbeat, 20_000), force: true, json: true))}) end)
      assert_received {:code, 0}
      assert_received {:transfer, %{note: "forced: x"}}
      assert %{"forced" => true} = Jason.decode!(out)
    end

    test "a lost compare-and-set exits 64 naming the new owner and skips auto-merge" do
      lost = record(%{gateway_label: "Other", epoch: 6, previous_epoch: 5})
      assert CLI.assign(assign_opts(transfer_fun: fn _, _, _, _ -> {:lost, lost} end)) == 64
      assert_received {:error, "aiur: ownership changed to Other at epoch 6; re-read with aiur ticket owner"}
      refute_received {:disable, _}
    end

    test "an unknown compare-and-set exits 75 with the retry command and skips auto-merge" do
      assert CLI.assign(assign_opts(transfer_fun: fn _, _, _, _ -> {:unknown, :timeout} end)) == 75
      assert_received {:error, "aiur: transfer outcome unknown" <> _ = message}
      assert message =~ "aiur ticket assign 12 --to nook"
      refute_received {:disable, _}
    end

    test "already owned by the target: no write, auto-merge still checked" do
      mine = record(%{gateway_id: @nook, gateway_label: "Nook", daemon_key: "nook"})
      opts = assign_opts(read_fun: fn _, _ -> {:ok, %{oid: "o", repository_id: "R", record: mine}} end)
      capture_io(fn -> send(self(), {:code, CLI.assign(opts)}) end)
      assert_received {:code, 0}
      refute_received {:transfer, _}
      assert_received {:disable, 9}
    end

    test "no open PR is auto_merge none; a failed mutation is exit 75 with the transfer kept" do
      out = capture_io(fn -> send(self(), {:code, CLI.assign(assign_opts(open_pr_fun: fn _ -> {:skip, :no_open_pr} end, json: true))}) end)
      assert_received {:code, 0}
      assert %{"auto_merge" => "none"} = Jason.decode!(out)

      out = capture_io(fn -> send(self(), {:code, CLI.assign(assign_opts(disable_fun: fn _ -> {:error, :boom, []} end, json: true))}) end)
      assert_received {:code, 75}
      assert_received {:transfer, _}
      assert %{"auto_merge" => "failed: :boom", "epoch" => 5} = Jason.decode!(out)
    end

    test "an unreadable record writes nothing and exits 75" do
      assert CLI.assign(assign_opts(read_fun: fn _, _ -> {:unknown, :timeout} end)) == 75
      refute_received {:transfer, _}
    end

    test "bad input is refused with distinct messages" do
      for {extra, message} <- [
            {[ticket: "abc"], "ticket must be"},
            {[to: nil], "--to"},
            {[to: "nobody"], "unknown gateway"},
            {[reason: ""], "--reason"},
            {[reason: String.duplicate("a", 501)], "--reason"}
          ] do
        assert CLI.assign(assign_opts(extra)) == 64
        assert_received {:error, text}
        assert text =~ message
      end

      refute_received {:transfer, _}
    end
  end

  describe "owner" do
    test "prints owner, epoch, actor and the ages" do
      out = capture_io(fn -> send(self(), {:code, CLI.owner(base_opts(liveness_fun: liveness(:online, :heartbeat, 4000)))}) end)
      assert_received {:code, 0}
      assert out =~ "owned by PC"
      assert out =~ "5s ago"
      assert out =~ "online via heartbeat, last heartbeat 4s ago"
    end

    test "json carries age_ms, freshness and liveness" do
      out = capture_io(fn -> CLI.owner(base_opts(json: true, liveness_fun: liveness(:online, :heartbeat, 4000))) end)

      assert %{
               "schema" => "aiur.ticket-owner/v1",
               "state" => "owned",
               "epoch" => 4,
               "age_ms" => 5000,
               "freshness" => "fresh",
               "liveness" => %{"status" => "online", "source" => "heartbeat", "age_ms" => 4000}
             } =
               Jason.decode!(out)
    end

    test "an unreadable record is unknown with no owner fields, exit 75" do
      out = capture_io(fn -> send(self(), {:code, CLI.owner(base_opts(json: true, read_fun: fn _, _ -> {:unknown, :timeout} end))}) end)
      assert_received {:code, 75}
      assert %{"state" => "unknown", "owner" => nil, "epoch" => nil, "liveness" => nil, "freshness" => "unknown"} = Jason.decode!(out)

      text = capture_io(fn -> CLI.owner(base_opts(read_fun: fn _, _ -> {:unknown, :timeout} end)) end)
      assert text =~ "ownership unknown"
    end

    test "unowned and released have no liveness" do
      out = capture_io(fn -> CLI.owner(base_opts(json: true, read_fun: fn _, _ -> {:ok, %{oid: nil, record: nil, repository_id: "R"}} end)) end)
      assert %{"state" => "unowned", "liveness" => nil} = Jason.decode!(out)

      released = record(%{state: "released"})
      out = capture_io(fn -> CLI.owner(base_opts(json: true, read_fun: fn _, _ -> {:ok, %{oid: "o", record: released, repository_id: "R"}} end)) end)
      assert %{"state" => "released", "epoch" => 4, "liveness" => nil} = Jason.decode!(out)
    end
  end
end
