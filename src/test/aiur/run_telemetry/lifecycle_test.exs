defmodule Aiur.RunTelemetry.LifecycleTest do
  use ExUnit.Case, async: true

  alias Aiur.RunTelemetry.Lifecycle

  test "attempt identities are unique and ticket-scoped" do
    first = Lifecycle.new_attempt_id("930")
    second = Lifecycle.new_attempt_id("930")

    assert first != second
    assert String.starts_with?(first, "930:")
    assert String.starts_with?(second, "930:")
  end

  test "records a sanitized lifecycle boundary with a stable event key" do
    recorder = recorder(self())

    assert :ok =
             Lifecycle.record("930", "930:attempt", :agent_spinup, :end, %{outcome: :failed, reason_class: :timeout, raw_output: "secret"},
               recorder: recorder,
               timestamp: ~U[2026-07-11 12:00:00Z]
             )

    assert_receive {:recorded, :lifecycle, attributes, opts}
    assert attributes.ticket == "930"
    assert attributes.attempt_id == "930:attempt"
    assert attributes.event == "agent_spinup"
    assert attributes.boundary == "end"
    assert attributes.outcome == "failed"
    assert attributes.reason_class == "timeout"
    assert is_binary(attributes.event_key)
    refute Map.has_key?(attributes, :raw_output)
    assert opts[:timestamp] == ~U[2026-07-11 12:00:00Z]
  end

  test "correlates Codex build/test starts and completions without storing commands" do
    recorder = recorder(self())
    tracker = make_ref()

    started = notification("item/started", %{id: "cmd-1", type: "commandExecution", command: "mix test test/foo_test.exs"})

    completed =
      notification("item/completed", %{
        id: "cmd-1",
        type: "commandExecution",
        command: "mix test test/foo_test.exs",
        exitCode: 0
      })

    assert :ok =
             Lifecycle.observe_backend_message("930", "attempt-1", "codex", started,
               recorder: recorder,
               tracker: tracker
             )

    assert :ok =
             Lifecycle.observe_backend_message("930", "attempt-1", "codex", completed,
               recorder: recorder,
               tracker: tracker
             )

    assert_receive {:recorded, :lifecycle, start_attrs, _opts}
    assert start_attrs.event == "build_test"
    assert start_attrs.boundary == "start"
    assert start_attrs.command_class == "test"
    assert start_attrs.operation_id == "cmd-1"

    assert_receive {:recorded, :lifecycle, end_attrs, _opts}
    assert end_attrs.boundary == "end"
    assert end_attrs.outcome == "success"
    refute Map.has_key?(start_attrs, :command)
    refute Map.has_key?(end_attrs, :command)
  end

  test "correlates Claude Bash calls/results and keeps orphan completions honest" do
    recorder = recorder(self())
    tracker = make_ref()

    call =
      notification("item/created", %{
        id: "tool-1",
        type: "tool_call",
        name: "Bash",
        input: %{command: "mix compile --warnings-as-errors"}
      })

    result = notification("item/created", %{id: "result-1", tool_use_id: "tool-1", type: "tool_result", is_error: false})

    Lifecycle.observe_backend_message("930", "attempt-2", "claude", call,
      recorder: recorder,
      tracker: tracker
    )

    Lifecycle.observe_backend_message("930", "attempt-2", "claude", result,
      recorder: recorder,
      tracker: tracker
    )

    assert_receive {:recorded, :lifecycle, %{boundary: "start", command_class: "build"}, _opts}
    assert_receive {:recorded, :lifecycle, %{boundary: "end", outcome: "success"}, _opts}

    orphan =
      notification("item/completed", %{
        id: "orphan",
        type: "commandExecution",
        command: "mix test",
        exitCode: 1
      })

    Lifecycle.observe_backend_message("930", "attempt-2", "codex", orphan,
      recorder: recorder,
      tracker: tracker
    )

    assert_receive {:recorded, :lifecycle, orphan_attrs, _opts}
    assert orphan_attrs.boundary == "point"
    assert orphan_attrs.outcome == "failed"
    assert orphan_attrs.duration_status == "unavailable"
  end

  test "turns only whitelisted trusted GitHub events into body-free anchors" do
    opened = %{
      id: 41,
      topic: "ticket.930.pr.opened",
      source: :github,
      author: "reviewer",
      pr: %{"number" => 77, "created_at" => "2026-07-11T13:00:00Z", "body" => "private"}
    }

    assert {:ok, opened_attrs, "2026-07-11T13:00:00Z"} = Lifecycle.external_anchor(opened)
    assert opened_attrs.event == "pr_opened"
    assert opened_attrs.ticket == "930"
    assert opened_attrs.pr_number == 77
    refute Map.has_key?(opened_attrs, :pr)
    refute inspect(opened_attrs) =~ "private"

    trusted = %{
      id: 42,
      topic: "ticket.930.issue.commented",
      source: :github,
      author_trusted?: true,
      author: "reviewer",
      comment: %{"id" => 88, "updated_at" => "2026-07-11T14:00:00Z", "body" => "please change the secret"}
    }

    assert {:ok, comment_attrs, "2026-07-11T14:00:00Z"} = Lifecycle.external_anchor(trusted)
    assert comment_attrs.event == "comment_received"
    assert comment_attrs.comment_id == 88
    assert comment_attrs.author_trusted == true
    refute inspect(comment_attrs) =~ "please change"

    assert :skip = Lifecycle.external_anchor(%{trusted | author_trusted?: false})

    benign = put_in(trusted, [:comment, "body"], "[codex] review passed")
    assert :skip = Lifecycle.external_anchor(benign)
  end

  defp notification(method, item) do
    %{
      event: :notification,
      payload: %{method: method, params: %{item: item}},
      timestamp: ~U[2026-07-11 12:00:00Z]
    }
  end

  defp recorder(test_pid) do
    fn kind, attributes, opts ->
      send(test_pid, {:recorded, kind, attributes, opts})
      :ok
    end
  end
end
