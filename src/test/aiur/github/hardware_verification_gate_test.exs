defmodule Aiur.GitHub.HardwareVerificationGateTest do
  use ExUnit.Case, async: true

  alias Aiur.GitHub.HardwareVerificationGate

  test "hydrates the complete authenticated identity for a passing sign-off" do
    issue = %{
      "labels" => [
        %{"name" => "agent:operator-verified"},
        %{"name" => "agent:operator-verification-passed"}
      ]
    }

    request_fun = fn %{method: :get, url: url} ->
      assert url =~ "/issues/1342/timeline?"

      {:ok,
       %{
         status: 200,
         headers: [],
         body: [
           labeled_event(1, "agent:operator-verified", "2026-08-01T00:00:00Z"),
           labeled_event(2, "agent:operator-verification-passed", "2026-08-01T00:01:00Z")
         ]
       }}
    end

    context = %{
      request_fun: request_fun,
      token: "test-token",
      owner: "owner",
      repo: "repo",
      issue_number: 1342,
      prefix: "agent",
      opts: [operator_authorized?: &(&1 == "operator")]
    }

    assert {:ok, identity} = HardwareVerificationGate.passing_operator_signoff_identity(context, issue)
    assert identity.verified.event_id == 1
    assert identity.verified.occurred_at == "2026-08-01T00:00:00Z"
    assert identity.verified.actor == %{"id" => 7, "login" => "operator", "node_id" => "MDQ6VXNlcjc="}
    assert identity.outcome.event_id == 2
    assert identity.outcome.actor["login"] == "operator"
  end

  defp labeled_event(id, label, created_at) do
    %{
      "event" => "labeled",
      "id" => id,
      "created_at" => created_at,
      "actor" => %{"id" => 7, "login" => "operator", "node_id" => "MDQ6VXNlcjc="},
      "label" => %{"name" => label}
    }
  end
end
