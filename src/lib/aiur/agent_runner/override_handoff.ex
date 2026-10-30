defmodule Aiur.AgentRunner.OverrideHandoff do
  @moduledoc "Attests the pushed checkout head at an actual worker handoff."

  alias Aiur.{Commands, Shell}
  alias Aiur.Workspace.Remote

  @spec record(String.t(), String.t(), term(), Path.t() | nil, String.t() | nil, keyword()) :: :ok | {:error, term()}
  def record(identifier, state, pr, workspace, worker_host, opts \\ [])

  def record(identifier, state, pr, workspace, worker_host, opts) when state in ["ci-wait", "human-review"] do
    case {pr_head(pr), workspace} do
      {{:ok, _head, _number}, path} when is_binary(path) and path != "" -> record_current(identifier, pr, path, worker_host, opts)
      _missing_evidence -> :ok
    end
  end

  def record(_identifier, _state, _pr, _workspace, _worker_host, _opts), do: :ok

  defp record_current(identifier, pr, workspace, worker_host, opts) do
    store_opts = [server: Keyword.get(opts, :decision_store, Commands.default_store())]

    with {:ok, snapshots} <- Commands.override_handoff_candidates(identifier, store_opts),
         :ok <- attest_if_needed(identifier, snapshots, pr, workspace, worker_host, store_opts, opts) do
      :ok
    else
      {:error, reason} -> {:error, {:override_handoff_unconfirmed, "Cannot persist the worker's Command override receipt: #{inspect(reason)}"}}
    end
  end

  # Empty candidates mean there is no override receipt to write. In that case
  # the DecisionStore is irrelevant to this handoff and need not be available
  # after the read has established the empty set.
  defp attest_if_needed(_identifier, [], _pr, _workspace, _worker_host, _store_opts, _opts), do: :ok

  defp attest_if_needed(identifier, snapshots, pr, workspace, worker_host, store_opts, opts),
    do: attest(identifier, snapshots, pr, workspace, worker_host, store_opts, opts)

  defp attest(identifier, snapshots, pr, workspace, worker_host, store_opts, opts) do
    reader = Keyword.get(opts, :override_handoff_head_reader, &read_head/2)

    with {:ok, head, number} <- pr_head(pr),
         {:ok, %{head_sha: ^head, upstream_sha: ^head, committed_at: %DateTime{} = at}} <- reader.(workspace, worker_host) do
      Commands.record_override_handoff(identifier, snapshots, %{head_sha: head, pr_number: number, at: at}, store_opts)
    else
      _unproven_head -> :ok
    end
  end

  defp pr_head(%{"head" => %{"sha" => head}, "number" => number}) when is_binary(head) and head != "" and is_integer(number) and number > 0, do: {:ok, head, number}
  defp pr_head(%{head_sha: head, number: number}) when is_binary(head) and head != "" and is_integer(number) and number > 0, do: {:ok, head, number}
  defp pr_head(_), do: {:error, :pull_request_head_unavailable}

  @doc false
  @spec read_head(Path.t() | nil, String.t() | nil) :: {:ok, map()} | {:error, term()}
  def read_head(workspace, worker_host) when is_binary(workspace) do
    assignment = if is_nil(worker_host), do: "override_receipt_workspace=#{Shell.escape(workspace)}", else: Remote.remote_shell_assign("override_receipt_workspace", workspace)

    script = """
    set -e
    #{assignment}
    override_receipt_head=$(git -C "$override_receipt_workspace" rev-parse --verify HEAD)
    override_receipt_upstream=$(git -C "$override_receipt_workspace" rev-parse --verify '@{upstream}')
    override_receipt_at=$(git -C "$override_receipt_workspace" log -1 --format=%cI "$override_receipt_head")
    printf '%s\n' "$override_receipt_head" "$override_receipt_upstream" "$override_receipt_at"
    """

    result = if is_nil(worker_host), do: local(script), else: Remote.run_remote_command(worker_host, script, 5_000)

    with {:ok, {output, 0}} <- result,
         [head, upstream, timestamp] <- String.split(String.trim(output), "\n"),
         {:ok, at, _} <- DateTime.from_iso8601(timestamp) do
      {:ok, %{head_sha: head, upstream_sha: upstream, committed_at: at}}
    else
      {:error, _} = error -> error
      _ -> {:error, :worker_checkout_head_unavailable}
    end
  end

  def read_head(_workspace, _worker_host), do: {:error, :worker_checkout_unavailable}

  defp local(script) do
    {:ok, System.cmd("sh", ["-c", script], stderr_to_stdout: true)}
  rescue
    _ -> {:error, :worker_checkout_unavailable}
  end
end
