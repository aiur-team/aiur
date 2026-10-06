defmodule AiurWeb.OperatorControlCenter.AddAgentSubmissionTest do
  use Aiur.TestSupport

  alias Aiur.Issue
  alias AiurWeb.Endpoint
  alias AiurWeb.OperatorControlCenter.AddAgentSubmission

  test "a stale backlog preview preserves and reports the current tracker lifecycle" do
    previous = Application.get_env(:aiur, Endpoint)
    on_exit(fn -> Application.put_env(:aiur, Endpoint, previous) end)

    {:ok, tracker} = Agent.start_link(fn -> nil end)

    Application.put_env(
      :aiur,
      Endpoint,
      Keyword.merge(previous || [],
        server: false,
        secret_key_base: String.duplicate("s", 64),
        add_agent_fun: fn _, _, _ -> flunk("current lifecycle and routing must not be rewritten") end,
        add_agent_verify_fun: fn ["2101"] -> {:ok, [Agent.get(tracker, & &1)]} end
      )
    )

    Aiur.TestSupport.start_owned_endpoint!()

    states = [
      {"in-progress", "Labels saved. Ticket remains in-progress."},
      {"human-review", "Labels saved. Ticket remains human-review."},
      {"done", "Labels saved. Ticket remains done."},
      {nil, "Labels saved. Current ticket state is unavailable; Check admission to retry."}
    ]

    for {state, message} <- states do
      issue = %Issue{
        id: "2101",
        identifier: "2101",
        creator_login: "aiur-bot",
        state: state,
        labels: ["agent:" <> (state || "todo"), "model:codex"],
        dispatch_authorized?: true,
        dispatch_authorization: :authorized
      }

      Agent.update(tracker, fn _ -> issue end)

      modal = %{
        identifier: "2101",
        labels: [],
        selection: %{backend: "codex", model: nil, effort: nil, complexity: nil}
      }

      result = AddAgentSubmission.run(modal)
      assert result.state == state
      assert result.authorization == :authorized
      assert result.labels == issue.labels
      assert result.added == []
      assert result.removed == []
      assert AddAgentSubmission.message(result) == message
    end
  end
end
