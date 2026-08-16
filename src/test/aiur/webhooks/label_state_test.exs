defmodule Aiur.Webhooks.LabelStateTest do
  use ExUnit.Case, async: true

  alias Aiur.Webhooks.LabelState

  defp issue_payload(labels, updated_at, action \\ "labeled") do
    %{
      "action" => action,
      "label" => %{"name" => "ignored-delta"},
      "repository" => %{"full_name" => "owner/repo"},
      "issue" => %{
        "number" => 7,
        "updated_at" => updated_at,
        "labels" => Enum.map(labels, &%{"name" => &1})
      }
    }
  end

  test "state comes from the full label list, not from the delta label" do
    payload = issue_payload(["agent:in-progress", "enhancement"], "2026-08-09T10:00:00Z", "unlabeled")

    assert {:ok, state} = LabelState.derive(payload)
    assert state.issue_number == 7
    assert state.labels == ["agent:in-progress", "enhancement"]
    refute "ignored-delta" in state.labels
  end

  test "labels are sorted and deduplicated so equal states compare equal" do
    assert {:ok, first} = LabelState.derive(issue_payload(["b", "a", "a"], "2026-08-09T10:00:00Z"))
    assert {:ok, second} = LabelState.derive(issue_payload(["a", "b"], "2026-08-09T10:00:00Z"))

    assert first.labels == ["a", "b"]
    assert first.labels == second.labels
  end

  test "pull request payloads carry label state too" do
    payload = %{
      "action" => "labeled",
      "pull_request" => %{"number" => 3, "updated_at" => "2026-08-09T10:00:00Z", "labels" => [%{"name" => "x"}]}
    }

    assert {:ok, %{issue_number: 3, labels: ["x"]}} = LabelState.derive(payload)
  end

  test "payloads without usable label state are rejected" do
    assert LabelState.derive(%{"issue" => %{"number" => 7, "updated_at" => "2026-08-09T10:00:00Z"}}) == :error
    assert LabelState.derive(%{"issue" => %{"number" => 7, "labels" => []}}) == :error
    assert LabelState.derive(%{"issue" => %{"number" => 7, "updated_at" => "nonsense", "labels" => []}}) == :error
    assert LabelState.derive("not a map") == :error
  end

  test "out-of-order delivery converges on the state GitHub holds" do
    assert {:ok, older} = LabelState.derive(issue_payload(["agent:todo"], "2026-08-09T10:00:00Z"))
    assert {:ok, newer} = LabelState.derive(issue_payload(["agent:in-progress"], "2026-08-09T10:00:05Z", "unlabeled"))

    # Newest-first arrival: the newer payload applies, the older one is skipped.
    assert {:apply, ^newer} = LabelState.converge(nil, newer)
    assert {:skip, :stale} = LabelState.converge(newer.position, older)

    # Oldest-first arrival converges on the same final labels.
    assert {:apply, ^older} = LabelState.converge(nil, older)
    assert {:apply, ^newer} = LabelState.converge(older.position, newer)
  end

  test "two different label events in the same second demand an API refresh" do
    assert {:ok, first} = LabelState.derive(issue_payload(["a"], "2026-08-09T10:00:00Z"))
    assert {:ok, second} = LabelState.derive(issue_payload(["b"], "2026-08-09T10:00:00Z", "unlabeled"))

    assert {:apply, ^first} = LabelState.converge(nil, first)
    assert {:refresh, :ambiguous_timestamp} = LabelState.converge(first.position, second)
  end
end
