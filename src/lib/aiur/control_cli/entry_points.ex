defmodule Aiur.ControlCLI.EntryPoints do
  @moduledoc false
  alias Aiur.AnalyticsCLI
  alias Aiur.BuildOrdersCLI
  alias Aiur.CommandsCLI
  alias Aiur.ExecutorCommandCLI
  alias Aiur.GitHubCostCLI
  alias Aiur.GitHubUsageCLI
  alias Aiur.UnitsCLI
  alias Aiur.Workspace.Ownership
  import Aiur.Orchestrator.ControlCLI.Output, only: [print_failure: 3]
  import Aiur.ControlCLI.Protocol, only: [control_error: 1, exit_marker: 1, guarded: 2]

  @spec commands(keyword()) :: :ok
  def commands(opts \\ []) do
    guarded("commands", fn -> CommandsCLI.run(opts) |> exit_marker() end)
  end

  @spec executor_answer(keyword()) :: :ok
  def executor_answer(opts) when is_list(opts) do
    guarded("executor-answer", fn -> opts |> ExecutorCommandCLI.answer(error_fun: &control_error/1) |> exit_marker() end)
  end

  @spec operator_answer(keyword()) :: :ok
  def operator_answer(opts) when is_list(opts) do
    guarded("answer", fn -> opts |> Aiur.OperatorAnswerCLI.answer() |> exit_marker() end)
  end

  @spec operator_answer_preview(keyword()) :: :ok
  def operator_answer_preview(opts) when is_list(opts) do
    guarded("answer preview", fn -> opts |> Aiur.OperatorAnswerCLI.preview() |> exit_marker() end)
  end

  @spec executor_escalate(keyword()) :: :ok
  def executor_escalate(opts) when is_list(opts) do
    guarded("executor-escalate", fn -> opts |> ExecutorCommandCLI.escalate(error_fun: &control_error/1) |> exit_marker() end)
  end

  @spec executor_reclassify(keyword()) :: :ok
  def executor_reclassify(opts) when is_list(opts), do: guarded("executor-reclassify", fn -> opts |> ExecutorCommandCLI.reclassify(error_fun: &control_error/1) |> exit_marker() end)
  @spec executor_moot(keyword()) :: :ok
  def executor_moot(opts) when is_list(opts) do
    guarded("executor-moot", fn -> opts |> ExecutorCommandCLI.moot(error_fun: &control_error/1) |> exit_marker() end)
  end

  @spec units(keyword()) :: :ok
  def units(opts \\ []), do: UnitsCLI.run(opts) |> exit_marker()

  @spec feature(keyword()) :: :ok
  def feature(opts \\ []), do: guarded("feature", fn -> opts |> Keyword.put(:error_fun, &control_error/1) |> Aiur.FeatureCLI.run() |> exit_marker() end)

  @spec epic(keyword()) :: :ok
  def epic(opts \\ []), do: guarded("epic", fn -> opts |> Keyword.put(:error_fun, &control_error/1) |> Aiur.EpicCLI.run() |> exit_marker() end)

  @spec build_orders(keyword()) :: :ok
  def build_orders(opts \\ []), do: guarded("build-orders", fn -> opts |> Keyword.put(:error_fun, &control_error/1) |> BuildOrdersCLI.run() |> exit_marker() end)

  @spec ticket_estimate(keyword()) :: :ok
  def ticket_estimate(opts \\ []), do: guarded("ticket estimate", fn -> opts |> Keyword.put(:error_fun, &control_error/1) |> Aiur.BuildOrder.EstimateCLI.run() |> exit_marker() end)

  @spec queue(keyword()) :: :ok
  def queue(opts \\ []), do: guarded("queue", fn -> opts |> Keyword.put(:error_fun, &control_error/1) |> Aiur.BuildQueueCLI.run() |> exit_marker() end)

  @spec analytics(keyword()) :: :ok
  def analytics(opts \\ []), do: guarded("analytics", fn -> AnalyticsCLI.run(opts) |> exit_marker() end)

  @spec github_cost(keyword()) :: :ok
  def github_cost(opts \\ []), do: guarded("github-cost", fn -> opts |> Keyword.put(:error_fun, &control_error/1) |> GitHubCostCLI.run() |> exit_marker() end)

  @spec experiments(keyword()) :: :ok
  def experiments(opts \\ []), do: guarded("experiments", fn -> opts |> Keyword.put(:error_fun, &control_error/1) |> Aiur.ExperimentsCLI.run() |> exit_marker() end)

  @spec capabilities(keyword()) :: :ok
  def capabilities(opts \\ []), do: guarded("capabilities", fn -> Aiur.CapabilitiesCLI.run(opts) |> exit_marker() end)

  @spec github_usage(keyword()) :: :ok
  def github_usage(opts \\ []), do: guarded("github-usage", fn -> GitHubUsageCLI.run(opts) |> exit_marker() end)

  @doc """
  Releases one workspace ownership generation after the daemon verifies
  independent local provider-exit proof. The caller must name the generation
  shown by status so a stale recovery command cannot release a replacement.
  """
  @spec recover_workspace(String.t(), pos_integer()) :: :ok
  def recover_workspace(ticket, generation) when is_binary(ticket) and is_integer(generation) and generation > 0 do
    guarded("workspace-recover", fn ->
      ticket_key = workspace_recovery_ticket_key(ticket)
      result = Ownership.release_if_held_with_exit_proof(ticket_key, generation)
      status = %{identifier: ticket, issue_id: ticket}

      report_workspace_recovery(result, ticket, generation, status)
    end)
  end

  defp report_workspace_recovery(:ok, ticket, generation, _status) do
    IO.puts("aiur: released workspace hold for #{ticket} generation #{generation}")
    exit_marker(0)
  end

  defp report_workspace_recovery({:error, {:audit_write_failed, reason}}, _ticket, _generation, _status) do
    IO.puts("__AIUR_CONTROL_ERROR__:aiur: workspace recovery was not performed because its durable audit write failed (#{inspect(reason)})")
    exit_marker(1)
  end

  defp report_workspace_recovery(result, _ticket, _generation, status) do
    reason = if result == :not_found, do: :not_found, else: recovery_failure_reason(result)
    print_failure(:workspace_recover, status, reason)
    exit_marker(1)
  end

  defp recovery_failure_reason(:not_held_for_reaping), do: :not_held_for_reaping
  defp recovery_failure_reason({:error, reason}), do: reason

  defp workspace_recovery_ticket_key(ticket) do
    case Regex.run(~r/^(?:[^#\/]+\/[^#\/]+#|#)(\d+)$/, ticket) do
      [_, issue_number] -> issue_number
      _ -> ticket
    end
  end
end
