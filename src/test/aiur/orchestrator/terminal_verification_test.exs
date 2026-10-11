defmodule Aiur.Orchestrator.TerminalVerificationTest do
  use Aiur.TestSupport

  alias Aiur.{CurrentRunMembership, Issue, TrackerIdentity}
  alias Aiur.CurrentRunMembership.Store
  alias Aiur.Events.Exchange
  alias Aiur.Orchestrator.{IssueSync, State}

  for {name, identity} <- [{"nil", nil}, {"unjoinable", TrackerIdentity.unjoinable(:missing_provider_id)}] do
    test "#{name} identity terminal ticket skips the store without degrading membership health" do
      identity = unquote(Macro.escape(identity))
      dir = Aiur.TestSupport.tmp_root!("terminal-verification-guard")
      on_exit(fn -> File.rm_rf!(dir) end)
      store = start_supervised!({Store, name: nil, state_dir: dir, run_id: "guard-test"})
      parent = self()

      marker = fn identity, pending? ->
        send(parent, :store_touched)
        Store.set_terminal_verification_pending(identity, pending?, store)
      end

      assert Store.health(store) == :healthy
      assert CurrentRunMembership.set_terminal_verification_pending(marker, identity, false) == :skipped
      previous = %{issue("guard-#{unquote(name)}", "in-progress") | tracker_identity: identity}

      result =
        IssueSync.sync_polled_issue_state(
          %State{last_polled_issues: %{previous.id => previous}},
          [],
          fn [_id] -> {:ok, [%{previous | state: "done"}]} end,
          fn _, _ -> flunk("unjoinable identity must not be observed") end,
          MapSet.new(["done"]),
          fn _ -> flunk("skipped marker must not make membership unavailable") end,
          marker
        )

      assert result.last_polled_issues == %{}
      assert Store.health(store) == :healthy
      refute_received :store_touched
    end
  end

  test "future regression: guarded terminal marker preserves errors and store exits" do
    identity = issue("42", "done").tracker_identity
    assert CurrentRunMembership.set_terminal_verification_pending(fn _, _ -> :ok end, identity, false) == :ok
    assert CurrentRunMembership.set_terminal_verification_pending(fn _, _ -> {:error, :disk_full} end, identity, false) == :error
    assert CurrentRunMembership.set_terminal_verification_pending(fn _, _ -> raise "store down" end, identity, false) == :error
    assert CurrentRunMembership.set_terminal_verification_pending(fn _, _ -> exit(:noproc) end, identity, false) == :error
  end

  for failure <- [:missing, :tracker_unavailable, :store_down] do
    test "terminal verification #{failure} is dropped after five attempts with one alert" do
      failure = unquote(failure)
      previous = issue(Integer.to_string(System.unique_integer([:positive])), "in-progress")
      topic = "ticket.#{previous.identifier}.terminal_verification_abandoned"
      :ok = Exchange.subscribe(topic)

      tick = fn state ->
        IssueSync.sync_polled_issue_state(
          state,
          [],
          fn [_] ->
            terminal_verification_result(failure, previous)
          end,
          fn _, _ -> :ok end,
          MapSet.new(["done"]),
          fn _ -> :ok end,
          fn _, _ -> terminal_verification_marker(failure) end
        )
      end

      retained =
        Enum.reduce(1..4, %State{last_polled_issues: %{previous.id => previous}}, fn count, state ->
          next = tick.(state)
          assert next.last_polled_issues == %{previous.id => previous}
          assert next.terminal_verification_attempts == %{previous.id => count}
          mailbox_barrier()
          refute_received {:event, %{topic: ^topic}}
          next
        end)

      abandoned = tick.(retained)
      assert abandoned.last_polled_issues == %{}
      assert abandoned.terminal_verification_attempts == %{}
      receive_barrier({:event, %{topic: ^topic} = alert})
      assert alert["source_ticket_id"] == previous.identifier
      assert alert["reason"] =~ "unresolved after 5 attempts"
      assert alert["needs_attention"] == true
      assert tick.(abandoned).last_polled_issues == %{}
      mailbox_barrier()
      refute_received {:event, %{topic: ^topic}}
      :ok = Exchange.unsubscribe(topic)
    end
  end

  test "terminal verification attempts reset when the active poll returns the id" do
    previous = issue("returned", "in-progress")

    tick = fn state, issues ->
      IssueSync.sync_polled_issue_state(state, issues, fn [_] -> {:ok, []} end, fn _, _ -> :ok end, MapSet.new(["done"]), fn _ -> :ok end, fn _, _ -> :ok end)
    end

    pending = tick.(%State{last_polled_issues: %{previous.id => previous}}, [])
    assert pending.terminal_verification_attempts == %{previous.id => 1}
    returned = tick.(pending, [previous])
    assert returned.terminal_verification_attempts == %{}
    assert tick.(returned, []).terminal_verification_attempts == %{previous.id => 1}
  end

  test "chunks disappearing idle verification across polls" do
    previous_issues =
      for id <- 1..250, into: %{}, do: {Integer.to_string(id), issue(Integer.to_string(id), "in-progress")}

    parent = self()
    state = %State{last_polled_issues: previous_issues}

    result =
      IssueSync.sync_polled_issue_state(
        state,
        [],
        fn ids ->
          send(parent, {:verified_ids, ids})
          {:ok, []}
        end,
        fn _identity, _lifecycle -> flunk("absent tickets cannot be inferred terminal") end,
        MapSet.new(["done", "cancelled"]),
        fn _status -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert_received {:verified_ids, ids}
    assert length(ids) == 25
    assert map_size(result.last_polled_issues) == 250
    assert result.terminal_verification_attempts == Map.new(ids, &{&1, 1})
  end

  defp terminal_verification_marker(:store_down), do: exit(:noproc)
  defp terminal_verification_marker(_failure), do: :ok

  defp terminal_verification_result(failure, previous) do
    case failure do
      :missing -> {:ok, []}
      :tracker_unavailable -> {:error, :temporarily_unavailable}
      :store_down -> {:ok, [%{previous | state: "done"}]}
    end
  end

  defp issue(id, state) do
    %Issue{
      id: id,
      identifier: "its-everdred/aiur##{id}",
      title: "Issue #{id}",
      state: state,
      tracker_identity: %TrackerIdentity{
        version: 1,
        status: :joinable,
        kind: :github,
        owner: "its-everdred",
        repository: "aiur",
        provider_id: "node-#{id}",
        identifier: id,
        reason: nil
      }
    }
  end

  defp mailbox_barrier do
    ref = make_ref()
    send(self(), {:mailbox_barrier, ref})

    receive do
      {:mailbox_barrier, ^ref} -> :ok
    end
  end
end
