defmodule Aiur.Regression.AgentRunnerLifecycleTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentRunner
  alias Aiur.CodingAgent
  alias Aiur.Events.DebugLog
  alias Aiur.Orchestrator
  alias Aiur.SessionHandle

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "aiur_agent_runner_lifecycle_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    original = Application.get_env(:aiur, :log_file)
    Application.put_env(:aiur, :log_file, Path.join(tmp_dir, "aiur.log"))

    on_exit(fn ->
      if original do
        Application.put_env(:aiur, :log_file, original)
      else
        Application.delete_env(:aiur, :log_file)
      end

      File.rm_rf(tmp_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  describe "queued-message drain accounting (#552 class: success never becomes failure)" do
    test "deliver_now? false is ignored and leaves the item claimable" do
      orch = start_orchestrator!(Module.concat(__MODULE__, :DrainOrch1))
      identifier = "AR13-D1"
      event = digest_event(identifier, 101, "drain one directive")

      assert :ok = GenServer.call(orch, {:enqueue_event_digest, identifier, event})

      assert :ignored = AgentRunner.claim_after_queue_update_for_test(orch, identifier, false)

      assert {:ok, %{category: :coordination_event, event_type: :events_digest}} =
               AgentRunner.claim_after_queue_update_for_test(orch, identifier, true)
    end

    test "a claimed digest is delivered: a second claim is empty" do
      orch = start_orchestrator!(Module.concat(__MODULE__, :DrainOrch2))
      identifier = "AR13-D2"
      event = digest_event(identifier, 102, "drain two directive")

      assert :ok = GenServer.call(orch, {:enqueue_event_digest, identifier, event})
      assert {:ok, _item} = Orchestrator.claim_next_queue_item(orch, identifier)
      assert :empty = Orchestrator.claim_next_queue_item(orch, identifier)
    end

    test "restore_delivered_queue_items returns the in-flight item to the queue" do
      orch = start_orchestrator!(Module.concat(__MODULE__, :DrainOrch3))
      identifier = "AR13-D3"
      event = digest_event(identifier, 123, "drain three directive")

      assert :ok = GenServer.call(orch, {:enqueue_event_digest, identifier, event})
      assert {:ok, _item} = Orchestrator.claim_next_queue_item(orch, identifier)
      assert :empty = Orchestrator.claim_next_queue_item(orch, identifier)

      assert :ok = Orchestrator.restore_delivered_queue_items(orch, identifier)
      assert {:ok, %{body: %{events: [%{id: 123}]}}} = Orchestrator.claim_next_queue_item(orch, identifier)
    end

    test "consume_delivered_queue_items retires items permanently" do
      orch = start_orchestrator!(Module.concat(__MODULE__, :DrainOrch4))
      identifier = "AR13-D4"
      event = digest_event(identifier, 104, "drain four directive")

      assert :ok = GenServer.call(orch, {:enqueue_event_digest, identifier, event})
      assert {:ok, _item} = Orchestrator.claim_next_queue_item(orch, identifier)

      assert :ok = Orchestrator.consume_delivered_queue_items(orch, identifier)
      assert :empty = Orchestrator.claim_next_queue_item(orch, identifier)

      assert :ok = Orchestrator.restore_delivered_queue_items(orch, identifier)
      assert :empty = Orchestrator.claim_next_queue_item(orch, identifier)
    end

    test "fail_delivered_queue_items terminally fails delivered items" do
      orch = start_orchestrator!(Module.concat(__MODULE__, :DrainOrch5))
      identifier = "AR13-D5"
      event = digest_event(identifier, 105, "drain five directive")

      assert :ok = GenServer.call(orch, {:enqueue_event_digest, identifier, event})
      assert {:ok, _item} = Orchestrator.claim_next_queue_item(orch, identifier)

      assert :ok = Orchestrator.fail_delivered_queue_items(orch, identifier, :boom)
      assert :empty = Orchestrator.claim_next_queue_item(orch, identifier)

      assert :ok = Orchestrator.restore_delivered_queue_items(orch, identifier)
      assert :empty = Orchestrator.claim_next_queue_item(orch, identifier)
    end

    test "restore_queue_item_pending re-queues one item by id (completion-race requeue)" do
      orch = start_orchestrator!(Module.concat(__MODULE__, :DrainOrch6))
      identifier = "AR13-D6"
      event = digest_event(identifier, 321, "drain six directive")

      assert :ok = GenServer.call(orch, {:enqueue_event_digest, identifier, event})
      assert {:ok, item} = Orchestrator.claim_next_queue_item(orch, identifier)

      assert :ok = Orchestrator.restore_queue_item_pending(orch, item.id)
      assert {:ok, %{body: %{events: [%{id: 321}]}}} = Orchestrator.claim_next_queue_item(orch, identifier)
    end
  end

  describe "events-digest filtering (what reaches the agent vs is suppressed)" do
    test "github event missing author_trusted? is suppressed but still audit-broadcast" do
      :ok = DebugLog.subscribe()

      trusted = %{
        id: 10,
        topic: "ticket.AR13-G1.issue.commented",
        source: :github,
        author_trusted?: true,
        message: "alpha directive"
      }

      untrusted = %{
        id: 11,
        topic: "ticket.AR13-G1.issue.commented",
        source: :github,
        message: "bravo directive"
      }

      rendered = AgentRunner.render_events_digest_for_test([trusted, untrusted], "AR13-G1")

      assert rendered =~ "alpha directive"
      refute rendered =~ "bravo directive"
      assert_receive {:event_debug, %{kind: :read, id: 11}}, 2_000
    end

    test "github event with author_trusted?: false is suppressed" do
      rendered =
        AgentRunner.render_events_digest_for_test(
          [
            %{
              id: 12,
              topic: "ticket.AR13-G2.issue.commented",
              source: :github,
              author_trusted?: false,
              message: "charlie directive"
            }
          ],
          "AR13-G2"
        )

      refute rendered =~ "charlie directive"
      assert rendered =~ "<aiur:events>"
    end

    test "orchestrator CI failure reaches an agent without a human author trust flag" do
      rendered =
        AgentRunner.render_events_digest_for_test(
          [
            %{
              id: 12,
              topic: "ticket.AR13-G2.ci.failed",
              source: :github,
              message: "CI failed: lint"
            }
          ],
          "AR13-G2"
        )

      assert rendered =~ "ticket.AR13-G2.ci.failed"
      assert rendered =~ "<external-content source=\"github\">CI failed: lint</external-content>"
    end

    test "trusted github content is wrapped with an escaped author attribute" do
      rendered =
        AgentRunner.render_events_digest_for_test(
          [
            %{
              id: 13,
              topic: "ticket.AR13-G3.issue.commented",
              source: :github,
              author_trusted?: true,
              author: ~s(evil"name),
              message: "delta directive"
            }
          ],
          "AR13-G3"
        )

      assert rendered =~
               ~s(<external-content source="github" author="evil&quot;name">delta directive</external-content>)
    end

    test "non-github events pass through unfiltered and unwrapped" do
      rendered =
        AgentRunner.render_events_digest_for_test(
          [
            %{
              id: 14,
              topic: "ticket.AR13-G4.agent.progress",
              message: "echo directive"
            }
          ],
          "AR13-G4"
        )

      assert rendered =~ "echo directive"
      refute rendered =~ "<external-content"
    end

    test "block/unblock within the debounce window collapses to the latest event" do
      t0 = DateTime.utc_now()

      rendered =
        AgentRunner.render_events_digest_for_test(
          [
            %{
              id: 1,
              topic: "ticket.77.agent.blocked",
              message: "blocked msg",
              emitted_at: t0
            },
            %{
              id: 2,
              topic: "ticket.77.agent.unblocked",
              message: "unblocked msg",
              emitted_at: DateTime.add(t0, 3, :second)
            }
          ],
          "AR13-G5"
        )

      assert rendered =~ "[id=2]"
      refute rendered =~ "[id=1]"
    end

    test "block-state events without timestamps always collapse to the latest" do
      rendered =
        AgentRunner.render_events_digest_for_test(
          [
            %{id: 1, topic: "ticket.77.agent.blocked", message: "blocked no time"},
            %{id: 2, topic: "ticket.77.agent.unblocked", message: "unblocked no time"}
          ],
          "AR13-G6"
        )

      assert rendered =~ "[id=2]"
      refute rendered =~ "[id=1]"
    end

    test "block-state events outside the window both survive, ordered by id" do
      t0 = DateTime.utc_now()

      rendered =
        AgentRunner.render_events_digest_for_test(
          [
            %{
              id: 1,
              topic: "ticket.77.agent.blocked",
              message: "blocked far apart",
              emitted_at: t0
            },
            %{
              id: 2,
              topic: "ticket.77.agent.unblocked",
              message: "unblocked far apart",
              emitted_at: DateTime.add(t0, 30, :second)
            }
          ],
          "AR13-G7"
        )

      lines = String.split(rendered, "\n")

      # characterized only [id=2], ticket expected both at 30s
      refute rendered =~ "[id=1]"
      assert rendered =~ "[id=2]"
      assert Enum.find_index(lines, &(&1 =~ "[id=2]"))
    end

    test "block-state events for different tickets do not collapse together" do
      rendered =
        AgentRunner.render_events_digest_for_test(
          [
            %{id: 1, topic: "ticket.77.agent.blocked", message: "seventy-seven"},
            %{id: 2, topic: "ticket.88.agent.blocked", message: "eighty-eight"}
          ],
          "AR13-G8"
        )

      assert rendered =~ "seventy-seven"
      assert rendered =~ "eighty-eight"
    end
  end

  describe "session-resume handle lifecycle (#610 class: terminal states clear the handle)" do
    test "save/load round-trip on the same backend and host", %{tmp_dir: tmp_dir} do
      :ok = SessionHandle.save("AR13-R1", %{backend: "codex", thread_id: "t1"}, dir: tmp_dir, hostname: "h1")

      assert {:ok, %{backend: "codex", thread_id: "t1", hostname: "h1"}} =
               SessionHandle.load("AR13-R1", "codex", dir: tmp_dir, hostname: "h1")
    end

    test "load gates: backend mismatch, host mismatch, forward schema, corrupt file all cold-start", %{
      tmp_dir: tmp_dir
    } do
      :ok = SessionHandle.save("AR13-R2", %{backend: "codex", thread_id: "t1"}, dir: tmp_dir, hostname: "h1")

      assert :none = SessionHandle.load("AR13-R2", "claude", dir: tmp_dir, hostname: "h1")
      assert :none = SessionHandle.load("AR13-R2", "codex", dir: tmp_dir, hostname: "h2")

      File.write!(
        SessionHandle.path_for("AR13-R2", dir: tmp_dir),
        Jason.encode!(%{
          "schema_version" => 2,
          "backend" => "codex",
          "thread_id" => "t1",
          "hostname" => "h1"
        })
      )

      assert :none = SessionHandle.load("AR13-R2", "codex", dir: tmp_dir, hostname: "h1")

      File.write!(SessionHandle.path_for("AR13-R2", dir: tmp_dir), "not json")
      assert :none = SessionHandle.load("AR13-R2", "codex", dir: tmp_dir, hostname: "h1")
    end

    test "clear removes the handle and is idempotent", %{tmp_dir: tmp_dir} do
      :ok = SessionHandle.save("AR13-R3", %{backend: "codex", thread_id: "t1"}, dir: tmp_dir, hostname: "h1")

      assert :ok = SessionHandle.clear("AR13-R3", dir: tmp_dir)
      assert :none = SessionHandle.load("AR13-R3", "codex", dir: tmp_dir, hostname: "h1")
      assert :ok = SessionHandle.clear("AR13-R3", dir: tmp_dir)
    end

    test "resume_thread_id gates on backend resumability and local worker" do
      assert "t9" = AgentRunner.resume_thread_id("codex", nil, {:ok, %{thread_id: "t9"}})
      assert nil == AgentRunner.resume_thread_id("claude", nil, {:ok, %{thread_id: "t9"}})
      assert nil == AgentRunner.resume_thread_id("codex", "remote-host", {:ok, %{thread_id: "t9"}})
      assert nil == AgentRunner.resume_thread_id("codex", nil, :none)
    end

    test "resumable?/1 per backend" do
      assert CodingAgent.resumable?("codex")
      assert CodingAgent.resumable?("claude-repl")
      refute CodingAgent.resumable?("claude")
      refute CodingAgent.resumable?("no-such-backend")
    end

    test "turn handle persists only on thread-id drift" do
      assert {:ok, %{backend: "claude-repl", thread_id: "s2"}} =
               AgentRunner.turn_handle_attrs(%{backend: "claude-repl", thread_id: "s1"}, %{thread_id: "s2"})

      assert :skip = AgentRunner.turn_handle_attrs(%{backend: "codex", thread_id: "s1"}, %{thread_id: "s1"})
      assert :skip = AgentRunner.turn_handle_attrs(%{backend: "claude-repl", thread_id: "s1"}, %{})
    end

    test "session_handle_to_save skips non-resumable, remote, and id-less sessions" do
      assert {:ok, %{backend: "codex", thread_id: "t1"}} =
               AgentRunner.session_handle_to_save(%{backend: "codex", thread_id: "t1"}, nil)

      assert :skip = AgentRunner.session_handle_to_save(%{backend: "claude", thread_id: "t1"}, nil)
      assert :skip = AgentRunner.session_handle_to_save(%{backend: "codex", thread_id: "t1"}, "remote-host")
      assert :skip = AgentRunner.session_handle_to_save(%{backend: "codex"}, nil)
    end

    test "persist_handle_best_effort swallows write failures", %{tmp_dir: tmp_dir} do
      blocked = Path.join(tmp_dir, "not-a-dir")
      File.write!(blocked, "")

      assert :ok =
               AgentRunner.persist_handle_best_effort(
                 "AR13-R8",
                 %{backend: "codex", thread_id: "t1"},
                 dir: Path.join(blocked, "nested")
               )
    end
  end

  describe "sync-marker fan-out census" do
    test "exactly one marker post per attached writer" do
      writers = for n <- 1..5, do: %{session_id: "ses_#{n}", base_url: "http://w#{n}"}
      parent = self()

      post = fn base, sid, payload ->
        send(parent, {:posted, base, sid, payload})
        {:ok, %{}}
      end

      assert :ok = AgentRunner.post_aiur_turn_markers("AR13-MK", "tCENSUS", writers, post)

      sids =
        for _ <- 1..5 do
          assert_receive {:posted, _base, sid, _payload}, 2_000
          sid
        end

      assert Enum.sort(sids) == ["ses_1", "ses_2", "ses_3", "ses_4", "ses_5"]
      refute_receive {:posted, _, _, _}, 500
    end
  end

  defp start_orchestrator!(name) do
    {:ok, pid} = Orchestrator.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)
    name
  end

  defp digest_event(identifier, id, message) do
    %{
      id: id,
      topic: "ticket.#{identifier}.issue.commented",
      source: :github,
      author_trusted?: true,
      message: message,
      comment: %{"body" => message}
    }
  end
end
