defmodule Aiur.Orchestrator.ResumeExecutorOwnedTest do
  use ExUnit.Case, async: true

  alias Aiur.Issue
  alias Aiur.Orchestrator.{PauseResume, State}

  test "resume names the Executor ownership refusal" do
    issue = %Issue{id: "52", identifier: "MT-52", title: "Held", state: "todo", executor_owner: "codex"}
    assert PauseResume.resume_decline_reason(:executor_owned, issue, %State{}) == :ticket_executor_owned
  end
end
