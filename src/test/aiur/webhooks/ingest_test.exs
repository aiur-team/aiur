defmodule Aiur.Webhooks.IngestTest do
  use ExUnit.Case, async: false

  alias Aiur.Webhooks.{DeliveryLog, Ingest}

  setup do
    dir = Path.join(System.tmp_dir!(), "aiur-webhook-ingest-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    name = :"ingest_delivery_log_#{System.unique_integer([:positive])}"
    store = start_supervised!({DeliveryLog, name: name, state_dir: dir, alert_fun: fn _t, _m, _o -> :ok end})

    %{dir: dir, store: store}
  end

  defp comment_payload(comment_id \\ 9001) do
    %{
      "action" => "created",
      "repository" => %{"full_name" => "owner/repo"},
      "issue" => %{"number" => 42},
      "comment" => %{"id" => comment_id, "updated_at" => "2026-08-09T10:00:00Z", "body" => "hello"}
    }
  end

  defp label_payload(labels, updated_at, action \\ "labeled") do
    %{
      "action" => action,
      "label" => %{"name" => "agent:todo"},
      "repository" => %{"full_name" => "owner/repo"},
      "issue" => %{
        "number" => 7,
        "updated_at" => updated_at,
        "labels" => Enum.map(labels, &%{"name" => &1})
      }
    }
  end

  test "the same delivery id processed twice has effect exactly once", %{store: store} do
    payload = comment_payload()

    assert {:process, admission} = Ingest.accept("delivery-1", "issue_comment", payload, store: store)
    assert admission.delivery_id == "delivery-1"
    assert admission.event == "issue_comment"
    assert is_binary(admission.semantic_key)

    assert {:drop, :duplicate_delivery, meta} = Ingest.accept("delivery-1", "issue_comment", payload, store: store)
    assert meta.delivery_id == "delivery-1"
    assert is_integer(meta.first_seen_at)
  end

  test "two different deliveries carrying the same event do not double-apply", %{store: store} do
    payload = comment_payload()

    assert {:process, _admission} = Ingest.accept("delivery-1", "issue_comment", payload, store: store)

    assert {:drop, :duplicate_event, meta} = Ingest.accept("delivery-2", "issue_comment", payload, store: store)
    assert meta.semantic_key =~ "issue_comment:owner/repo:42:9001"
  end

  test "a genuinely different event under a new delivery is processed", %{store: store} do
    assert {:process, _first} = Ingest.accept("delivery-1", "issue_comment", comment_payload(1), store: store)
    assert {:process, _second} = Ingest.accept("delivery-2", "issue_comment", comment_payload(2), store: store)
  end

  test "an event with no derivable key still dedupes on the delivery id", %{store: store} do
    payload = %{"action" => "added", "repository" => %{"full_name" => "owner/repo"}}

    assert {:process, admission} = Ingest.accept("delivery-1", "membership", payload, store: store)
    assert admission.semantic_key == nil
    assert {:drop, :duplicate_delivery, _meta} = Ingest.accept("delivery-1", "membership", payload, store: store)
  end

  test "a missing delivery header still leaves semantic dedupe in place", %{store: store} do
    assert {:process, admission} = Ingest.accept(nil, "issue_comment", comment_payload(), store: store)
    assert admission.delivery_id == nil

    assert {:drop, :duplicate_event, _meta} = Ingest.accept("  ", "issue_comment", comment_payload(), store: store)
  end

  test "out-of-order labeled and unlabeled deliveries converge on GitHub's state", %{store: store} do
    newer = label_payload(["agent:in-progress"], "2026-08-09T10:00:05Z", "unlabeled")
    older = label_payload(["agent:todo"], "2026-08-09T10:00:00Z")

    assert {:process, admission} = Ingest.accept("delivery-newer", "issues", newer, store: store)
    assert admission.label_state == %{issue_number: 7, labels: ["agent:in-progress"], refresh_required?: false}

    assert {:drop, :stale_state, meta} = Ingest.accept("delivery-older", "issues", older, store: store)
    assert meta.issue_number == 7

    # The watermark still holds the newer position, so a later replay stays dropped.
    assert {:drop, :duplicate_delivery, _meta} = Ingest.accept("delivery-older", "issues", older, store: store)
  end

  test "in-order labeled deliveries each apply the full label list", %{store: store} do
    first = label_payload(["agent:todo"], "2026-08-09T10:00:00Z")
    second = label_payload(["agent:todo", "priority:1"], "2026-08-09T10:00:05Z")

    assert {:process, %{label_state: %{labels: ["agent:todo"]}}} = Ingest.accept("d-1", "issues", first, store: store)

    assert {:process, %{label_state: %{labels: ["agent:todo", "priority:1"], refresh_required?: false}}} =
             Ingest.accept("d-2", "issues", second, store: store)
  end

  test "two label events inside the same second ask the caller to refresh from the API", %{store: store} do
    first = label_payload(["agent:todo"], "2026-08-09T10:00:00Z")
    second = label_payload([], "2026-08-09T10:00:00Z", "unlabeled")

    assert {:process, %{label_state: %{refresh_required?: false}}} = Ingest.accept("d-1", "issues", first, store: store)

    assert {:process, %{label_state: %{refresh_required?: true, issue_number: 7}}} =
             Ingest.accept("d-2", "issues", second, store: store)
  end

  test "non-label actions do not advance the ordering watermark", %{store: store} do
    opened = %{
      "action" => "opened",
      "repository" => %{"full_name" => "owner/repo"},
      "issue" => %{"number" => 7, "updated_at" => "2026-08-09T10:00:00Z", "labels" => []}
    }

    assert {:process, %{label_state: nil}} = Ingest.accept("d-open", "issues", opened, store: store)

    # A label event at the same timestamp is still applied, not reported stale.
    labeled = label_payload(["agent:todo"], "2026-08-09T10:00:00Z")
    assert {:process, %{label_state: %{refresh_required?: false}}} = Ingest.accept("d-1", "issues", labeled, store: store)
  end

  test "an unusable payload is reported rather than crashing the receiver", %{store: store} do
    assert {:drop, :unusable_payload, %{event: "issues"}} = Ingest.accept("d-1", "issues", "not a map", store: store)
  end
end
