defmodule Aiur.Webhooks.DeliveryStreamTest do
  @moduledoc """
  Drives a stand-in handler through realistic at-least-once delivery streams.

  These tests assert the *effect* of a stream — how many times a handler ran
  and what label state it converged on — rather than the return value of a
  single admission call, so a regression that admits a duplicate shows up as a
  double-applied side effect.
  """

  use ExUnit.Case, async: false

  alias Aiur.Webhooks.{DeliveryLog, Ingest}

  setup do
    dir = Aiur.TestSupport.tmp_root!("aiur-webhook-stream")
    on_exit(fn -> File.rm_rf!(dir) end)

    name = :"stream_delivery_log_#{System.unique_integer([:positive])}"
    store = start_supervised!({DeliveryLog, name: name, state_dir: dir, alert_fun: fn _t, _m, _o -> :ok end})

    %{dir: dir, store: store}
  end

  # A deliberately non-idempotent handler: every run appends. Anything the
  # admission gate lets through twice is visible as two entries.
  defp run_stream(deliveries, store) do
    Enum.reduce(deliveries, %{applied: [], labels: %{}, refreshed: []}, fn {delivery_id, event, payload}, acc ->
      case Ingest.accept(delivery_id, event, payload, store: store) do
        {:process, %{label_state: nil} = admission} ->
          %{acc | applied: acc.applied ++ [admission.semantic_key || admission.delivery_id]}

        {:process, %{label_state: %{refresh_required?: true} = state} = admission} ->
          %{
            acc
            | applied: acc.applied ++ [admission.semantic_key],
              refreshed: acc.refreshed ++ [state.issue_number]
          }

        {:process, %{label_state: state} = admission} ->
          %{
            acc
            | applied: acc.applied ++ [admission.semantic_key],
              labels: Map.put(acc.labels, state.issue_number, state.labels)
          }

        {:drop, _reason, _meta} ->
          acc
      end
    end)
  end

  defp comment(id \\ 9001) do
    %{
      "action" => "created",
      "repository" => %{"full_name" => "owner/repo"},
      "issue" => %{"number" => 42},
      "comment" => %{"id" => id, "updated_at" => "2026-08-09T10:00:00Z", "body" => "wake up"}
    }
  end

  defp labeled(labels, updated_at, action \\ "labeled") do
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

  test "a retried delivery wakes the handler once", %{store: store} do
    stream = List.duplicate({"delivery-1", "issue_comment", comment()}, 4)

    assert %{applied: applied} = run_stream(stream, store)
    assert length(applied) == 1
  end

  test "a manual redelivery under a fresh delivery id still wakes the handler once", %{store: store} do
    stream = [
      {"delivery-1", "issue_comment", comment()},
      {"delivery-manual-redelivery", "issue_comment", comment()},
      {"delivery-1", "issue_comment", comment()}
    ]

    assert %{applied: applied} = run_stream(stream, store)
    assert length(applied) == 1
  end

  test "an out-of-order labeled/unlabeled pair converges on GitHub's state", %{store: store} do
    # GitHub's own end state: agent:todo was removed and agent:in-progress added.
    stream = [
      {"d-newer", "issues", labeled(["agent:in-progress"], "2026-08-09T10:00:05Z", "unlabeled")},
      {"d-older", "issues", labeled(["agent:todo"], "2026-08-09T10:00:00Z")}
    ]

    assert %{labels: labels} = run_stream(stream, store)
    assert labels == %{7 => ["agent:in-progress"]}
  end

  test "the same stream in the opposite order converges on the same state", %{store: store} do
    stream = [
      {"d-older", "issues", labeled(["agent:todo"], "2026-08-09T10:00:00Z")},
      {"d-newer", "issues", labeled(["agent:in-progress"], "2026-08-09T10:00:05Z", "unlabeled")}
    ]

    assert %{labels: labels} = run_stream(stream, store)
    assert labels == %{7 => ["agent:in-progress"]}
  end

  test "a same-second label pair asks for an API refresh instead of guessing", %{store: store} do
    stream = [
      {"d-1", "issues", labeled(["agent:todo"], "2026-08-09T10:00:00Z")},
      {"d-2", "issues", labeled([], "2026-08-09T10:00:00Z", "unlabeled")}
    ]

    assert %{labels: labels, refreshed: refreshed} = run_stream(stream, store)
    assert labels == %{7 => ["agent:todo"]}
    assert refreshed == [7]
  end

  test "a redelivery arriving after a restart is still dropped", %{dir: dir, store: store} do
    assert %{applied: [_one]} = run_stream([{"d-1", "issue_comment", comment()}], store)

    stop_supervised!(DeliveryLog)

    name = :"stream_delivery_log_restarted_#{System.unique_integer([:positive])}"
    restarted = start_supervised!({DeliveryLog, name: name, state_dir: dir, alert_fun: fn _t, _m, _o -> :ok end})

    assert %{applied: []} = run_stream([{"d-1", "issue_comment", comment()}], restarted)
  end

  test "distinct events in one burst all reach the handler", %{store: store} do
    stream =
      Enum.flat_map(1..25, fn index ->
        delivery = {"d-#{index}", "issue_comment", comment(index)}
        [delivery, delivery]
      end)

    assert %{applied: applied} = run_stream(stream, store)
    assert length(applied) == 25
    assert length(Enum.uniq(applied)) == 25
  end
end
