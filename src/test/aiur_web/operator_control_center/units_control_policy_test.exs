defmodule AiurWeb.OperatorControlCenter.UnitsControlPolicyTest do
  use ExUnit.Case, async: true

  alias Aiur.TrackerIdentity
  alias AiurWeb.OperatorControlCenter.UnitsControlPolicy, as: Policy

  describe "affordance/2 eligibility matrix" do
    test "a running, working unit presents pause" do
      assert %{action: :pause, state: :enabled, reason: nil} = Policy.affordance(running_row(), nil)
    end

    test "an applied-paused unit presents resume" do
      row = put_in(running_row(), [:runtime, :work_state], :paused)
      assert %{action: :resume, state: :enabled} = Policy.affordance(row, nil)
    end

    test "a tracker-paused running unit presents resume" do
      row = put_in(running_row(), [:runtime, :tracker_paused?], true)
      assert %{action: :resume, state: :enabled} = Policy.affordance(row, nil)
    end

    test "a terminal unit is disabled with a terminal reason" do
      row = Map.put(running_row(), :terminal?, true)
      assert %{action: nil, state: :disabled, reason: :terminal} = Policy.affordance(row, nil)
    end

    test "a replaced-generation unit is disabled distinctly from terminal" do
      row = running_row() |> Map.put(:terminal?, true) |> Map.put(:replacement_boundary?, true)
      assert %{state: :disabled, reason: :replaced_generation} = Policy.affordance(row, nil)
    end

    test "a queued unit is disabled and not running" do
      row = running_row() |> put_in([:runtime, :bucket], :queued) |> Map.put(:lifecycle, :queued)
      assert %{state: :disabled, reason: :queued} = Policy.affordance(row, nil)
    end

    test "a retrying unit is disabled" do
      row = running_row() |> put_in([:runtime, :bucket], :retrying) |> Map.put(:lifecycle, :retrying)
      assert %{state: :disabled, reason: :retrying} = Policy.affordance(row, nil)
    end

    test "a merging unit is disabled" do
      row = Map.put(running_row(), :lifecycle, :merging)
      assert %{state: :disabled, reason: :merging} = Policy.affordance(row, nil)
    end

    test "a remote-control unit is disabled distinctly" do
      row = Map.put(running_row(), :lifecycle, :remote_control)
      assert %{state: :disabled, reason: :remote_control} = Policy.affordance(row, nil)
    end

    test "a unit without a typed identity cannot be controlled" do
      row = Map.put(running_row(), :identity, %TrackerIdentity{status: :ambiguous, identifier: nil})
      assert %{state: :disabled, reason: :no_identity} = Policy.affordance(row, nil)
    end

    test "an in-flight request disables repeat activation and keeps the pending action" do
      control = %{action: :pause, status: :requested, identifier: "1110"}
      assert %{action: nil, state: :pending, pending_action: :pause} = Policy.affordance(running_row(), control)
    end

    test "an accepted request is still pending" do
      control = %{action: :resume, status: :accepted, identifier: "1110"}
      assert %{state: :pending, pending_action: :resume} = Policy.affordance(running_row(), control)
    end

    test "a settled request no longer suppresses the base affordance" do
      control = %{action: :pause, status: :applied, identifier: "1110"}
      row = put_in(running_row(), [:runtime, :work_state], :paused)
      assert %{action: :resume, state: :enabled} = Policy.affordance(row, control)
    end
  end

  describe "recheck/2 invocation gate" do
    test "pause on a confirmed, working unit is eligible" do
      assert :ok = Policy.recheck(caps(:confirmed, :working, nil), :pause)
    end

    test "resume on a confirmed, paused unit is eligible" do
      assert :ok = Policy.recheck(caps(:confirmed, :paused, nil), :resume)
    end

    test "a pending control debounces the request" do
      assert {:error, :already_pending} = Policy.recheck(caps(:confirmed, :working, %{status: :requested}), :pause)
    end

    test "an unsupported worker is rejected" do
      assert {:error, :unsupported} = Policy.recheck(caps(:unsupported, :working, nil), :pause)
    end

    test "a request-only worker is surfaced distinctly" do
      assert {:error, :request_only} = Policy.recheck(caps(:request_only, :working, nil), :pause)
    end

    test "a concurrent state change cancels the pause" do
      assert {:error, :state_changed} = Policy.recheck(caps(:confirmed, :paused, nil), :pause)
    end

    test "a concurrent state change cancels the resume" do
      assert {:error, :state_changed} = Policy.recheck(caps(:confirmed, :working, nil), :resume)
    end
  end

  describe "presentation/1" do
    test "requested and accepted announce a pending, non-error tone" do
      assert %{tone: :pending, retry?: false} = Policy.presentation(%{action: :pause, status: :requested})
      assert %{tone: :pending} = Policy.presentation(%{action: :pause, status: :accepted})
    end

    test "applied names the resulting state" do
      assert %{label: "Paused", tone: :applied} = Policy.presentation(%{action: :pause, status: :applied})
      assert %{label: "Resumed", tone: :applied} = Policy.presentation(%{action: :resume, status: :applied})
    end

    test "expiry offers a retry" do
      assert %{tone: :error, retry?: true} = Policy.presentation(%{action: :pause, status: :expired})
    end

    test "a superseded rejection is warning, not error, and offers no retry" do
      state = %{action: :pause, status: :rejected, rejection: %{class: :superseded}}
      assert %{tone: :warning, retry?: false} = Policy.presentation(state)
    end

    test "a routing rejection offers a retry" do
      state = %{action: :pause, status: :rejected, rejection: %{class: :control_failed}}
      assert %{tone: :error, retry?: true} = Policy.presentation(state)
    end

    test "a stale-generation rejection cancels without masquerading as applied" do
      state = %{action: :pause, status: :rejected, rejection: %{class: :stale_generation}}
      assert %{tone: :warning, retry?: false} = Policy.presentation(state)
    end

    test "an already-in-state rejection renders the resulting applied state, not an error" do
      assert %{label: "Paused", tone: :applied, retry?: false} =
               Policy.presentation(%{action: :pause, status: :rejected, rejection: %{class: :already_in_state}})
    end

    test "request-only and unsupported are distinct warnings" do
      assert %{tone: :warning} = Policy.presentation(%{action: :pause, status: :request_only})
      assert %{tone: :warning} = Policy.presentation(%{action: :pause, status: :unsupported})
    end

    test "a state change is a non-error warning" do
      assert %{tone: :warning, retry?: false} = Policy.presentation(%{action: :pause, status: :state_changed})
    end
  end

  describe "apply_lifecycle/2 correlation" do
    test "advances a tracked pause on the correlated request id" do
      tracked = %{action: :pause, status: :requested, request_id: 7, identifier: "1110"}
      payload = %{action: :pause, status: :applied, request_id: 7, rejection: nil}
      assert %{status: :applied, request_id: 7} = Policy.apply_lifecycle(tracked, payload)
    end

    test "ignores a mismatched request id so stale intent is never overwritten" do
      tracked = %{action: :pause, status: :requested, request_id: 7, identifier: "1110"}
      payload = %{action: :pause, status: :applied, request_id: 99}
      assert %{status: :requested, request_id: 7} = Policy.apply_lifecycle(tracked, payload)
    end

    test "binds the request id for a resume that had none yet" do
      tracked = %{action: :resume, status: :requested, request_id: nil, identifier: "1110"}
      payload = %{action: :resume, status: :accepted, request_id: 12}
      assert %{status: :accepted, request_id: 12} = Policy.apply_lifecycle(tracked, payload)
    end

    test "nil tracked state stays nil" do
      assert Policy.apply_lifecycle(nil, %{action: :pause, status: :applied}) == nil
    end
  end

  describe "settled?/1 and settle_error/3" do
    test "in-flight states are not settled" do
      refute Policy.settled?(%{status: :requested})
      refute Policy.settled?(%{status: :accepted})
    end

    test "terminal and nil states are settled" do
      assert Policy.settled?(%{status: :applied})
      assert Policy.settled?(nil)
    end

    test "a control rejection carries its class in the rejection map" do
      settled = Policy.settle_error(:pause, {:control_rejected, %{class: :worker_unavailable}}, "1110")
      assert %{status: :rejected, rejection: %{class: :worker_unavailable}} = settled
      assert %{tone: :error, retry?: true} = Policy.presentation(settled)
    end

    test "a control expiry becomes an expired, retryable state" do
      settled = Policy.settle_error(:resume, {:control_expired, %{at: "now"}}, "1110")
      assert %{status: :expired} = settled
      assert %{tone: :error, retry?: true} = Policy.presentation(settled)
    end

    test "an atom reason becomes the status" do
      assert %{status: :unavailable} = Policy.settle_error(:pause, :unavailable, "1110")
    end
  end

  defp caps(unit_control, status, pending) do
    %{unit_control: unit_control, status: status, pending_control: pending}
  end

  defp running_row do
    %{
      identity: %TrackerIdentity{
        status: :joinable,
        kind: :github,
        owner: "acme",
        repository: "aiur",
        provider_id: "NODE-1110",
        database_id: 1110,
        identifier: "1110",
        reason: nil
      },
      lifecycle: :active,
      terminal?: false,
      replacement_boundary?: false,
      reasons: %{pause: nil},
      runtime: %{bucket: :running, work_state: :working, tracker_paused?: false}
    }
  end
end
