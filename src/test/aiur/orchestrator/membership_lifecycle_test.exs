defmodule Aiur.Orchestrator.MembershipLifecycleTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Aiur.{Issue, TrackerIdentity}
  alias Aiur.Orchestrator.MembershipLifecycle

  test "does not log recovery artifact contents when an observation fails" do
    sentinel = "ghp_membership_lifecycle_sentinel"
    {:error, decode_error} = Jason.decode(~s({"contents":"#{sentinel}"))

    log =
      capture_log(fn ->
        assert {:error, :membership_observation_failed} =
                 MembershipLifecycle.record(issue(), :completed, fn _identity, _lifecycle ->
                   {:error, decode_error}
                 end)
      end)

    refute log =~ sentinel
  end

  defp issue do
    %Issue{
      id: "membership-lifecycle-test",
      identifier: "42",
      state: "done",
      tracker_identity: %TrackerIdentity{
        version: 1,
        status: :joinable,
        kind: :github,
        owner: "owner",
        repository: "repo",
        provider_id: "I-membership-lifecycle",
        identifier: "42",
        reason: nil
      }
    }
  end
end
