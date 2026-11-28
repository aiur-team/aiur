defmodule Aiur.AgentRunner.NoChangeHandoff do
  @moduledoc "Verifies and records a worker's no-change completion claim."

  alias Aiur.{Issue, Orchestrator.TicketTransition}

  @spec finish(Issue.t(), map(), Path.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def finish(issue, evidence, workspace, opts) do
    with :ok <- verify_on_base(evidence["commit"], workspace, opts),
         state <- if("creator-facing" in (Map.get(issue, :labels, []) || []), do: "human-review", else: "done"),
         :ok <- write_comment(issue.identifier, comment(evidence, state), opts),
         :ok <- write_state(issue.identifier, state, opts) do
      {:ok, %{state: state, evidence_recorded: true, no_op_limit_exempt: true}}
    end
  end

  defp verify_on_base(commit, workspace, opts) when is_binary(workspace) do
    base = Keyword.get(opts, :base_branch, System.get_env("AIUR_BASE_BRANCH"))
    verifier = Keyword.get(opts, :no_change_verifier, &default_verify/3)

    if is_binary(base) and String.trim(base) != "" do
      verifier.(workspace, String.trim(base), commit)
    else
      {:error, :base_branch_unavailable}
    end
  end

  defp verify_on_base(_commit, _workspace, _opts), do: {:error, :workspace_unavailable}

  defp write_comment(identifier, body, opts) do
    case Keyword.get(opts, :no_change_comment_writer) do
      writer when is_function(writer, 2) -> writer.(identifier, body)
      _ -> TicketTransition.write_comment(identifier, body, writer: :turn_loop)
    end
  end

  defp write_state(identifier, state, opts) do
    case Keyword.get(opts, :no_change_state_writer) do
      writer when is_function(writer, 2) -> writer.(identifier, state)
      _ -> TicketTransition.write_state(identifier, state, writer: :turn_loop)
    end
  end

  defp default_verify(workspace, base, commit) do
    remote_ref = "refs/remotes/origin/#{base}"

    with {_, 0} <- System.cmd("git", ["-C", workspace, "fetch", "origin", "#{base}:#{remote_ref}"], stderr_to_stdout: true),
         {_, 0} <- System.cmd("git", ["-C", workspace, "merge-base", "--is-ancestor", commit, remote_ref], stderr_to_stdout: true) do
      :ok
    else
      _ -> {:error, :commit_not_on_current_base}
    end
  rescue
    _ -> {:error, :commit_not_on_current_base}
  end

  defp comment(evidence, state) do
    """
    Worker verified that no code change is needed because the fix is already on the current integration branch.

    - Commit: `#{evidence["commit"]}`
    - Verification command: `#{evidence["command"]}`
    - Output:
    ```text
    #{evidence["output"]}
    ```

    The ticket moved to `#{state}`. This verified no-change completion does not count toward the worker no-op limit.
    """
    |> String.trim()
  end
end
