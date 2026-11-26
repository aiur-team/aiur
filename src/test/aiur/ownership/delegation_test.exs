defmodule Aiur.Ownership.DelegationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Aiur.Ownership.{CLI, Delegation, PeerState, Record, WaitingLabel}

  @repo "o/r"
  @nook "bbbbbbbbbbbbbbbbbbbbbbbbbb"
  @pc "aaaaaaaaaaaaaaaaaaaaaaaaaa"
  @old "cccccccccccccccccccccccccc"

  defp now, do: ~U[2026-11-06 12:00:00Z]
  defp list(projects, minutes_ago), do: %{projects: projects, observed_at: DateTime.add(now(), -minutes_ago * 60, :second)}

  describe "check_target/4" do
    test "a fresh list that lacks the repo refuses" do
      assert {:refuse, "pc does not run o/r"} = Delegation.check_target(list(["a/b"], 1), @repo, "pc", now())
    end

    test "a list with the repo passes, however old" do
      assert :ok = Delegation.check_target(list([@repo], 1), @repo, "pc", now())
      assert :ok = Delegation.check_target(list([@repo], 120), @repo, "pc", now())
    end

    test "a stale negative warns and never refuses" do
      assert {:warn, message} = Delegation.check_target(list(["a/b"], 120), @repo, "pc", now())
      assert message =~ "last list"
      assert message =~ "lacked o/r"
    end

    test "no list warns that it is unknown" do
      assert {:warn, "pc unreachable; project list unknown; transfer written"} = Delegation.check_target(nil, @repo, "pc", now())
    end
  end

  describe "waiting_action/7" do
    defp record(overrides \\ %{}), do: Map.merge(%{gateway_id: @pc, reason: "transfer", epoch: 4}, overrides)
    defp act(labelled?, ref, delegation, owner_list), do: Delegation.waiting_action(labelled?, ref, @repo, delegation, owner_list, @nook, now())

    test "adds once when the owner's fresh list lacks the repo" do
      assert :add = act(false, {:owned, record()}, %{epoch: 4}, list(["a/b"], 1))
      assert :keep = act(true, {:owned, record()}, %{epoch: 4}, list(["a/b"], 1))
    end

    test "unknown never labels" do
      assert :keep = act(false, {:owned, record()}, %{epoch: 4}, nil)
      assert :keep = act(false, {:owned, record()}, %{epoch: 4}, list(["a/b"], 120))
    end

    test "only the delegator of this epoch labels" do
      assert :keep = act(false, {:owned, record()}, nil, list(["a/b"], 1))
      assert :keep = act(false, {:owned, record(%{epoch: 5})}, %{epoch: 4}, list(["a/b"], 1))
      assert :keep = act(false, {:owned, record(%{reason: "dispatch"})}, %{epoch: 4}, list(["a/b"], 1))
    end

    test "clears when the owner is self, gains the repo, was re-transferred or released" do
      assert :remove = act(true, {:owned, record(%{gateway_id: @nook})}, %{epoch: 4}, nil)
      assert :remove = act(true, {:owned, record()}, %{epoch: 4}, list([@repo], 1))
      assert :remove = act(true, {:owned, record(%{epoch: 5})}, %{epoch: 4}, nil)
      assert :remove = act(true, :unowned, %{epoch: 4}, nil)
    end

    test "an offline owner or stale list keeps a true label" do
      assert :keep = act(true, {:owned, record()}, %{epoch: 4}, list([@repo], 120))
      assert :keep = act(true, {:owned, record()}, %{epoch: 4}, nil)
      assert :keep = act(true, {:unreadable, :x}, %{epoch: 4}, nil)
    end
  end

  describe "assign to a peer" do
    defp owned do
      {:ok, rec} =
        Record.new(%{
          repo: @repo,
          ticket: "12",
          state: "owned",
          gateway_id: @old,
          gateway_label: "Old",
          daemon_key: "old",
          epoch: 4,
          previous_epoch: 3,
          actor: %{kind: "daemon", id: "old"},
          reason: "dispatch",
          at: "2026-11-06T11:59:00Z"
        })

      rec
    end

    defp opts(peer) do
      test = self()
      observed = %{oid: "oid1", repository_id: "R1", record: owned()}

      [
        ticket: "12",
        repo: @repo,
        now: now(),
        to: "pc",
        reason: "x",
        error_fun: &send(test, {:error, &1}),
        identity_fun: fn -> %{gateway_id: @nook, gateway_label: "Nook", daemon_key: "nook"} end,
        peer_fun: fn "pc" -> peer end,
        liveness_fun: fn _ -> %{status: :offline, source: nil, age_ms: nil} end,
        read_fun: fn @repo, "12" -> {:ok, observed} end,
        transfer_fun: fn @repo, "12", ^observed, owner ->
          send(test, {:transfer, owner})
          {:won, %{owned() | epoch: 5, previous_epoch: 4, gateway_id: owner.gateway_id, gateway_label: owner.gateway_label, daemon_key: owner.daemon_key, reason: "transfer"}}
        end,
        delegation_fun: &send(test, {:delegation, &1}),
        open_pr_fun: fn "12" -> {:skip, :no_open_pr} end
      ]
    end

    defp peer(projects, minutes_ago, key \\ "pc") do
      Map.merge(
        %{gateway_id: @pc, label: "PC", daemon_key: key, projects: nil, observed_at: nil},
        if(projects, do: %{projects: projects, observed_at: elem(DateTime.from_unix(DateTime.to_unix(now()) - minutes_ago * 60), 1)}, else: %{})
      )
    end

    test "a peer without the repo exits 64 and writes nothing" do
      assert capture_io(fn -> send(self(), {:code, CLI.assign(opts(peer(["a/b"], 1)))}) end) == ""
      assert_received {:code, 64}
      assert_received {:error, "aiur: pc does not run o/r"}
      refute_received {:transfer, _}
    end

    test "an unreachable peer with no list warns, writes the transfer and records the delegation" do
      capture_io(fn -> send(self(), {:code, CLI.assign(opts(peer(nil, 0)))}) end)
      assert_received {:code, 0}
      assert_received {:error, "aiur: warning: pc unreachable; project list unknown; transfer written"}
      assert_received {:transfer, %{gateway_id: @pc, daemon_key: "pc"}}
      assert_received {:delegation, %{repo: @repo, ticket: "12", gateway_id: @pc, epoch: 5}}
    end

    test "a peer whose daemon key is unknown is refused before writing" do
      assert CLI.assign(opts(peer([@repo], 1, nil))) == 64
      refute_received {:transfer, _}
    end
  end

  describe "WaitingLabel.run/6" do
    setup do
      previous = Application.fetch_env!(:aiur, :ownership_state_dir)
      Application.put_env(:aiur, :ownership_state_dir, Path.join(previous, "waiting-#{System.unique_integer([:positive])}"))
      on_exit(fn -> Application.put_env(:aiur, :ownership_state_dir, previous) end)
      :ok
    end

    test "adds the label once for a delegated ticket whose owner lacks the repo" do
      test = self()
      :ok = PeerState.add_delegation(%{repo: @repo, ticket: "12", gateway_id: @pc, epoch: 4})
      issue = %{identifier: 12, labels: []}

      opts = [
        now: now(),
        peer_fun: fn @pc -> %{projects: ["a/b"], observed_at: DateTime.add(now(), -60)} end,
        ensure_fun: fn -> :ok end,
        write_fun: fn "12", action, label -> send(test, {:write, action, label}) && :ok end
      ]

      ref = {:owned, record()}
      WaitingLabel.run(issue, @repo, "12", ref, @nook, opts)
      assert_received {:write, :add, "gateway-waiting:project-missing"}

      WaitingLabel.run(%{issue | labels: ["gateway-waiting:project-missing"]}, @repo, "12", ref, @nook, opts)
      refute_received {:write, _, _}
    end

    test "clearing the label drops the delegation record" do
      test = self()
      :ok = PeerState.add_delegation(%{repo: @repo, ticket: "12", gateway_id: @pc, epoch: 4})
      issue = %{identifier: 12, labels: ["gateway-waiting:project-missing"]}
      write = fn "12", action, label -> send(test, {:write, action, label}) && :ok end

      WaitingLabel.run(issue, @repo, "12", {:owned, record(%{gateway_id: @nook})}, @nook, now: now(), write_fun: write, peer_fun: fn _ -> nil end)

      assert_received {:write, :remove, "gateway-waiting:project-missing"}
      assert PeerState.delegation(@repo, "12") == nil
    end
  end
end
