defmodule AiurWeb.StreamdeckChannelCommandsTest do
  use AiurWeb.StreamdeckChannelCase

  describe "Commands" do
    # The channel reads `Endpoint.config(:decision_store)` per call, so each
    # test points it at a fresh fake store. The restore in `on_exit` uses
    # `Application.put_env` — never `Endpoint.config_change`, whose ETS table is
    # torn down before `on_exit` runs. The next test's setup re-applies the full
    # endpoint config, which drops the stale `decision_store` entry.
    setup do
      decision = command_decision("AIUR-1")
      {:ok, store} = FakeDecisionStore.start_link(decision, self())
      previous_config = Application.get_env(:aiur, Endpoint)
      Endpoint.config_change(%{Endpoint => Keyword.put(previous_config, :decision_store, store)}, [])

      on_exit(fn ->
        Application.put_env(:aiur, Endpoint, previous_config)
        Aiur.TestSupport.safe_stop(store)
      end)

      %{decision: decision}
    end

    test "focus pushes the focused agent's Commands page", %{decision: decision} do
      store = Endpoint.config(:decision_store)
      assert is_pid(store) and Process.alive?(store)
      socket = joined_socket()
      assert_reply(push(socket, "focus", %{"identifier" => "AIUR-1"}), :ok, %{"focused" => "AIUR-1"})

      assert_push("commands", payload)
      assert_receive {:fake_decision_query, :hit}, 1000
      assert payload["identifier"] == "AIUR-1"
      assert [item] = payload["items"]
      assert item["decision_id"] == decision.decision_id
      assert item["question"] == "Ship the change?"
      assert item["status"] == "open"
      assert item["answer"] == nil
      # The option projection is the device's allowlist.
      assert item["options"] == [%{"id" => "ship", "label" => "Ship it", "description" => "Merge and deploy now."}]
    end

    test "commands_page replies with the next page" do
      socket = joined_socket()
      assert_reply(push(socket, "focus", %{"identifier" => "AIUR-1"}), :ok, %{"focused" => "AIUR-1"})
      assert_push("commands", _payload)

      # The cursor is the opaque encoding the store hands back on the previous
      # page; a client passes it through untouched.
      cursor =
        Cursor.encode(%{
          created_at: ~U[2026-07-12 10:00:00Z],
          decision_id: command_decision("AIUR-1").decision_id
        })

      assert_reply(push(socket, "commands_page", %{"cursor" => cursor}), :ok, %{"identifier" => "AIUR-1"} = page)
      assert [item] = page["items"]
      assert item["decision_id"] == command_decision("AIUR-1").decision_id
    end

    test "answer_command records an operator-attributed answer" do
      socket = joined_socket()
      assert_reply(push(socket, "focus", %{"identifier" => "AIUR-1"}), :ok, %{"focused" => "AIUR-1"})
      assert_push("commands", _payload)

      assert_reply(
        push(socket, "answer_command", %{
          "decision_id" => command_decision("AIUR-1").decision_id,
          "version" => 1,
          "idempotency_key" => "sd-key-1",
          "option_id" => "ship"
        }),
        :ok,
        %{"status" => "accepted"}
      )

      # The durable record's actor is the operator on the deck, never the
      # Executor — the load-bearing attribution decision of this feature.
      assert_receive {:fake_decision_answer, _decision_id, payload, opts}, 1000
      assert payload["option_id"] == "ship"
      # The exact version the device read is forwarded as `expected_version`,
      # so the store rejects a stale press as a conflict rather than a double
      # answer. This is the option path half of the staleness contract.
      assert payload["expected_version"] == 1
      assert Keyword.get(opts, :actor) == %{kind: :operator, id: "streamdeck"}
    end

    test "answer_command sends a spoken custom response instead of an option" do
      socket = joined_socket()
      assert_reply(push(socket, "focus", %{"identifier" => "AIUR-1"}), :ok, %{"focused" => "AIUR-1"})
      assert_push("commands", _payload)

      assert_reply(
        push(socket, "answer_command", %{
          "decision_id" => command_decision("AIUR-1").decision_id,
          "version" => 1,
          "idempotency_key" => "sd-key-2",
          "custom_response" => "Hold everything — verify first."
        }),
        :ok,
        %{"status" => "accepted"}
      )

      assert_receive {:fake_decision_answer, _decision_id, payload, _opts}, 1000
      assert payload["custom_response"] == "Hold everything — verify first."
      refute Map.has_key?(payload, "option_id")
      # Same staleness forwarding as the option path: `expected_version` is set
      # on the custom-response path too, which is the clause the double mutant
      # proved was unguarded.
      assert payload["expected_version"] == 1
    end

    test "answer_command refuses a Command that is not the focused agent's" do
      decision = command_decision("AIUR-999")
      {:ok, other_store} = FakeDecisionStore.start_link(decision, self())
      previous_config = Application.get_env(:aiur, Endpoint)
      Endpoint.config_change(%{Endpoint => Keyword.put(previous_config, :decision_store, other_store)}, [])

      on_exit(fn ->
        Application.put_env(:aiur, Endpoint, previous_config)
        Aiur.TestSupport.safe_stop(other_store)
      end)

      socket = joined_socket()
      assert_reply(push(socket, "focus", %{"identifier" => "AIUR-1"}), :ok, %{"focused" => "AIUR-1"})
      assert_push("commands", _payload)

      assert_reply(
        push(socket, "answer_command", %{
          "decision_id" => decision.decision_id,
          "version" => 1,
          "idempotency_key" => "sd-key-3",
          "option_id" => "ship"
        }),
        :error,
        %{reason: "command_not_focused"}
      )
    end

    test "answer_command rejects a malformed payload outright" do
      socket = joined_socket()
      assert_reply(push(socket, "focus", %{"identifier" => "AIUR-1"}), :ok, %{"focused" => "AIUR-1"})
      assert_push("commands", _payload)

      # Neither an option nor a custom response.
      assert_reply(
        push(socket, "answer_command", %{
          "decision_id" => command_decision("AIUR-1").decision_id,
          "version" => 1,
          "idempotency_key" => "sd-key-4"
        }),
        :error,
        %{reason: "invalid_answer"}
      )

      # A blank custom response is not an answer.
      assert_reply(
        push(socket, "answer_command", %{
          "decision_id" => command_decision("AIUR-1").decision_id,
          "version" => 1,
          "idempotency_key" => "sd-key-5",
          "custom_response" => "   "
        }),
        :error,
        %{reason: "empty_custom_response"}
      )
    end

    test "answer_command guard refuses a blank idempotency key and a non-positive version" do
      # The `handle_in` guard (`idempotency_key != ""` and `version > 0`) is the
      # first line of the staleness contract: a blank key could never dedupe a
      # retry, and a non-positive version could never match any real Command.
      # Each of these must fall through to `invalid_answer` before touching the
      # store.
      socket = joined_socket()
      assert_reply(push(socket, "focus", %{"identifier" => "AIUR-1"}), :ok, %{"focused" => "AIUR-1"})
      assert_push("commands", _payload)
      decision_id = command_decision("AIUR-1").decision_id

      for bad <- [
            %{"decision_id" => decision_id, "version" => 1, "idempotency_key" => "", "option_id" => "ship"},
            %{"decision_id" => decision_id, "version" => 0, "idempotency_key" => "sd-key-zero", "option_id" => "ship"},
            %{"decision_id" => decision_id, "version" => -1, "idempotency_key" => "sd-key-neg", "option_id" => "ship"}
          ] do
        assert_reply(push(socket, "answer_command", bad), :error, %{reason: "invalid_answer"})
      end
    end

    test "answer_command refuses a dismissed Command as not answerable" do
      # Dismissal is terminal on the device surface too — the TS client renders
      # a dismissed Command read-only, so the server must refuse the answer at
      # the same boundary. Only open and deferred are answerable (allowlisted),
      # so a newly-added status can never silently become answerable.
      dismissed = %{command_decision("AIUR-1") | decision_status: :dismissed}
      {:ok, dismissed_store} = FakeDecisionStore.start_link(dismissed, self())
      previous_config = Application.get_env(:aiur, Endpoint)
      Endpoint.config_change(%{Endpoint => Keyword.put(previous_config, :decision_store, dismissed_store)}, [])

      on_exit(fn ->
        Application.put_env(:aiur, Endpoint, previous_config)
        Aiur.TestSupport.safe_stop(dismissed_store)
      end)

      socket = joined_socket()
      assert_reply(push(socket, "focus", %{"identifier" => "AIUR-1"}), :ok, %{"focused" => "AIUR-1"})
      assert_push("commands", _payload)

      assert_reply(
        push(socket, "answer_command", %{
          "decision_id" => dismissed.decision_id,
          "version" => 1,
          "idempotency_key" => "sd-key-dismissed",
          "option_id" => "ship"
        }),
        :error,
        %{reason: reason}
      )

      assert reason =~ "not_answerable"
    end

    test "answer_command records an operator answer durably through a real store" do
      # The other answer_command tests drive a fake store to assert the wire
      # call; this one goes end to end through a real `DecisionStore` so the
      # durable actor the channel records is asserted exactly as the dashboard
      # would read it back.
      dir = Path.join(System.tmp_dir!(), "aiur-streamdeck-channel-#{System.unique_integer([:positive])}")

      {:ok, store} =
        Aiur.DecisionStore.start_link(
          name: nil,
          state_dir: dir,
          filesystem_sync_fun: fn -> :ok end
        )

      previous_config = Application.get_env(:aiur, Endpoint)
      Endpoint.config_change(%{Endpoint => Keyword.put(previous_config, :decision_store, store)}, [])

      on_exit(fn ->
        Application.put_env(:aiur, Endpoint, previous_config)
        Aiur.TestSupport.safe_stop(store)
        File.rm_rf!(dir)
      end)

      payload = %{
        "source_id" => "streamdeck-e2e",
        "question" => "Ship the e2e change?",
        "blocking" => true,
        "authority" => "human_required",
        "reversibility" => "reversible",
        "options" => [%{"id" => "ship", "label" => "Ship it", "description" => "Merge and deploy now."}]
      }

      assert {:ok, %{decision: decision}} =
               Aiur.DecisionStore.request(
                 payload,
                 [
                   ticket: %{identifier: "984", title: "Stream Deck Commands", url: "https://github.com/its-everdred/aiur/issues/984"},
                   source: %{agent_id: "agent-1", session_id: "session-1", event_id: "evt-e2e"},
                   now: ~U[2026-07-12 10:00:00Z]
                 ],
                 store
               )

      socket = joined_socket()
      assert_reply(push(socket, "focus", %{"identifier" => "984"}), :ok, %{"focused" => "984"}, 1_000)
      assert_push("commands", _payload)

      ref =
        push(socket, "answer_command", %{
          "decision_id" => decision.decision_id,
          "version" => decision.version,
          "idempotency_key" => "sd-e2e-1",
          "option_id" => "ship"
        })

      # The reply is the completion barrier for the real store's fsynced answer.
      # Match only the ref here so an error reply fails the assertions immediately;
      # a missing reply still fails at ExUnit's test timeout.
      reply = receive_barrier(%Phoenix.Socket.Reply{ref: ^ref})
      assert reply.status == :ok
      assert reply.payload["status"] == "accepted"

      assert {:ok, current} = Aiur.DecisionStore.get(decision.decision_id, store)
      assert current.answer.actor == %{kind: :operator, id: "streamdeck"}
      assert current.answer.selected_option_id == "ship"
    end

    test "answer_command rejects a stale custom-response answer as a conflict" do
      # A stale press is a conflict, never a double-answer. This drives a real
      # store so the rejection holds only while BOTH staleness layers are
      # present: the channel's `validate_focused_command/4` version pre-check
      # AND `expected_version` in the `custom_response` clause reaching
      # `DecisionAnswer.normalize/2`. The double mutant that removed both
      # (the gap this ticket closes) lets the answer through as accepted — or
      # as a generic error — so this assertion on `stale_version` fails.
      dir = Path.join(System.tmp_dir!(), "aiur-streamdeck-stale-#{System.unique_integer([:positive])}")

      {:ok, store} =
        Aiur.DecisionStore.start_link(
          name: nil,
          state_dir: dir,
          filesystem_sync_fun: fn -> :ok end
        )

      previous_config = Application.get_env(:aiur, Endpoint)
      Endpoint.config_change(%{Endpoint => Keyword.put(previous_config, :decision_store, store)}, [])

      on_exit(fn ->
        Application.put_env(:aiur, Endpoint, previous_config)
        Aiur.TestSupport.safe_stop(store)
        File.rm_rf!(dir)
      end)

      payload = %{
        "source_id" => "streamdeck-stale",
        "question" => "Ship the stale change?",
        "blocking" => true,
        "authority" => "human_required",
        "reversibility" => "reversible",
        "options" => [%{"id" => "ship", "label" => "Ship it", "description" => "Merge and deploy now."}]
      }

      assert {:ok, %{decision: decision}} =
               Aiur.DecisionStore.request(
                 payload,
                 [
                   ticket: %{identifier: "984", title: "Stream Deck Commands", url: "https://github.com/its-everdred/aiur/issues/984"},
                   source: %{agent_id: "agent-1", session_id: "session-1", event_id: "evt-stale"},
                   now: ~U[2026-07-12 10:00:00Z]
                 ],
                 store
               )

      socket = joined_socket()
      assert_reply(push(socket, "focus", %{"identifier" => "984"}), :ok, %{"focused" => "984"})
      assert_push("commands", _payload)

      # The device answers the version it read; a different version is stale.
      stale_version = decision.version + 1

      assert_reply(
        push(socket, "answer_command", %{
          "decision_id" => decision.decision_id,
          "version" => stale_version,
          "idempotency_key" => "sd-stale-1",
          "custom_response" => "Hold everything — this is stale."
        }),
        :error,
        %{reason: reason}
      )

      assert reason =~ "stale_version"

      # The stale press must not have recorded an answer: it is a conflict,
      # never a double-answer.
      assert {:ok, current} = Aiur.DecisionStore.get(decision.decision_id, store)
      assert current.answer == nil
    end
  end

  test "external projections convert source values to JSON-safe payloads" do
    timestamp = ~U[2026-07-30 12:00:00Z]

    assert %{
             "identifier" => "AIUR-3",
             "status" => "paused",
             "alert_count" => 3,
             "tracker_paused" => true,
             "backend" => "codex"
           } =
             StreamdeckProjection.agent(%{
               "identifier" => "AIUR-3",
               "status" => :paused,
               "alert_count" => 3,
               "tracker_paused" => true,
               "backend" => :codex
             })

    assert %{"identifier" => "AIUR-3", "role" => "assistant", "timestamp" => "2026-07-30T12:00:00Z"} =
             StreamdeckProjection.transcript("AIUR-3", %{role: :assistant, timestamp: timestamp})
  end

  test "a failed control action reports the same bare reason wording as say" do
    test_pid = self()

    put_endpoint_config(
      agent_chat_pause_fun: fn identifier ->
        send(test_pid, {:paused, identifier})
        {:error, :no_running_agent}
      end
    )

    socket = joined_socket()
    control = push(socket, "control", %{"identifier" => "AIUR-1", "action" => "pause"})

    # One wire convention: an atom reason from the AgentChat facade reaches the
    # device as the bare word, never inspect-quoted (`":no_running_agent"`).
    assert_receive {:paused, "AIUR-1"}, 1000
    assert_reply(control, :error, %{reason: "no_running_agent"})
  end
end
