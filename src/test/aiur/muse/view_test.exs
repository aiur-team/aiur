defmodule Aiur.Muse.ViewTest do
  use ExUnit.Case, async: true

  alias Aiur.Muse.View

  test "native delta gets its item kind, replay emits once, and completion retires deltas" do
    start = item("item/started", 1, "opaque-start")
    delta = %{"method" => "item/delta", "params" => %{"sessionId" => "session", "itemId" => "message", "viewCursor" => "opaque-delta", "field" => "text", "delta" => "hello"}}
    assert {:emit, _, state} = View.ingest(View.new("session"), start)
    assert {:emit, %{muse_item_kind: "agentMessage", payload: ^delta}, state} = View.ingest(state, delta)
    assert {:ignore, ^state} = View.ingest(state, delta)
    completed = item("item/completed", 2, "opaque-completed")
    assert {:emit, _, state} = View.ingest(state, completed)
    assert {:ignore, ^state} = View.ingest(state, completed)
    assert {:ignore, ^state} = View.ingest(state, put_in(delta, ["params", "viewCursor"], "late-delta"))
    assert state.cursor == "opaque-completed"
  end

  test "child sessions cannot contaminate parent item state" do
    state = View.new("parent")
    assert {:ignore, ^state} = View.ingest(state, item("item/started", 1, "child-cursor"))
  end

  test "a missing item or native gap is incomplete evidence rather than a guessed assistant delta" do
    delta = %{"method" => "item/delta", "params" => %{"sessionId" => "session", "itemId" => "missing", "viewCursor" => "c1", "delta" => "text"}}
    assert {:error, :incomplete_native_view} = View.ingest(View.new("session"), delta)
    assert {:error, :incomplete_native_view} = View.ingest(View.new("session"), %{"method" => "view/gap"})
  end

  test "older item revisions never replace completed state or its opaque cursor" do
    assert {:emit, _, state} = View.ingest(View.new("session"), item("item/completed", 3, "head"))
    assert {:ignore, ^state} = View.ingest(state, item("item/started", 1, "earlier"))
  end

  test "approval request aliases emit once without hiding changed requirements" do
    params = %{
      "sessionId" => "session",
      "itemId" => "approval-item",
      "viewCursor" => "approval-1",
      "approvalId" => "approval",
      "currentRequirementId" => %{"approvalId" => "approval", "sourceIndex" => 0}
    }

    request = %{"method" => "approval/request", "params" => params}
    alias_request = %{request | "method" => "approval/requested"}

    for [first, replay] <- [[request, alias_request], [alias_request, request]] do
      assert {:emit, %{payload: ^first}, state} = View.ingest(View.new("session"), first)
      assert {:ignore, ^state} = View.ingest(state, replay)
      updated = %{"method" => "approval/updated", "params" => %{params | "viewCursor" => "approval-2", "currentRequirementId" => %{"approvalId" => "approval", "sourceIndex" => 1}}}
      assert {:emit, %{payload: ^updated}, state} = View.ingest(state, updated)
      assert state.cursor == "approval-2"
    end
  end

  defp item(method, revision, cursor) do
    %{"method" => method, "params" => %{"sessionId" => "session", "viewCursor" => cursor, "item" => %{"itemId" => "message", "kind" => "agentMessage", "revision" => revision, "text" => "hello"}}}
  end
end
