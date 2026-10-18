defmodule Aiur.AgentControlCLI do
  @moduledoc false

  defdelegate prepare_handoff(opts \\ []), to: Aiur.Handoff, as: :prepare
  defdelegate status(opts \\ []), to: Aiur.Orchestrator.StatusCLI
  defdelegate main_watch_state(), to: Aiur.MainWatch, as: :state
  defdelegate main_watch_inherited?(check, merge_base), to: Aiur.MainWatch, as: :inherited?
  defdelegate agents(opts \\ []), to: Aiur.Orchestrator.StatusCLI
  defdelegate watch(opts \\ []), to: Aiur.Orchestrator.StatusCLI
  defdelegate alerts(opts \\ []), to: Aiur.ExecutorAttention.CLI
  defdelegate commands(opts \\ []), to: Aiur.ControlCLI.EntryPoints
  defdelegate executor_answer(opts), to: Aiur.ControlCLI.EntryPoints
  defdelegate executor_escalate(opts), to: Aiur.ControlCLI.EntryPoints
  defdelegate executor_reclassify(opts), to: Aiur.ControlCLI.EntryPoints
  defdelegate executor_moot(opts), to: Aiur.ControlCLI.EntryPoints
  defdelegate units(opts \\ []), to: Aiur.ControlCLI.EntryPoints
  defdelegate feature(opts \\ []), to: Aiur.ControlCLI.EntryPoints
  defdelegate epic(opts \\ []), to: Aiur.ControlCLI.EntryPoints
  defdelegate build_orders(opts \\ []), to: Aiur.ControlCLI.EntryPoints
  defdelegate queue(opts \\ []), to: Aiur.ControlCLI.EntryPoints
  defdelegate analytics(opts \\ []), to: Aiur.ControlCLI.EntryPoints
  defdelegate github_cost(opts \\ []), to: Aiur.ControlCLI.EntryPoints
  defdelegate experiments(opts \\ []), to: Aiur.ControlCLI.EntryPoints
  defdelegate capabilities(opts \\ []), to: Aiur.ControlCLI.EntryPoints
  defdelegate github_usage(opts \\ []), to: Aiur.ControlCLI.EntryPoints
  defdelegate executor_emit(topic, payload_json), to: Aiur.ExecutorAttention.CLI
  defdelegate executor_subscribe(topic), to: Aiur.ExecutorAttention.CLI
  defdelegate executor_unsubscribe(topic), to: Aiur.ExecutorAttention.CLI
  defdelegate executor_subscriptions(), to: Aiur.ExecutorAttention.CLI
  defdelegate executor_listen(), to: Aiur.ExecutorAttention.CLI
  defdelegate executor_listen(opts), to: Aiur.ExecutorAttention.CLI
  defdelegate executor_wait(), to: Aiur.ExecutorAttention.CLI
  defdelegate executor_wait(opts), to: Aiur.ExecutorAttention.CLI
  defdelegate executor_fast_forward(wake_id), to: Aiur.ExecutorAttention.CLI
  defdelegate executor_fast_forward(wake_id, opts), to: Aiur.ExecutorAttention.CLI
  defdelegate executor_roster(), to: Aiur.ExecutorAttention.CLI
  defdelegate executor_roster(opts), to: Aiur.ExecutorAttention.CLI
  defdelegate executor_claim(), to: Aiur.ExecutorAttention.CLI
  defdelegate executor_claim(opts), to: Aiur.ExecutorAttention.CLI
  defdelegate executor_release(), to: Aiur.ExecutorAttention.CLI
  defdelegate executor_release(opts), to: Aiur.ExecutorAttention.CLI
  defdelegate executor_revoke(owner_id), to: Aiur.ExecutorAttention.CLI
  defdelegate executor_revoke(owner_id, opts), to: Aiur.ExecutorAttention.CLI
  defdelegate executor_listen_validate(topic), to: Aiur.ExecutorAttention.CLI
  defdelegate todo(issue_ids, opts \\ []), to: Aiur.Orchestrator.TodoCLI
  defdelegate reset_budget(targets), to: Aiur.Orchestrator.ControlCLI
  defdelegate pause_global(), to: Aiur.Orchestrator.ControlCLI
  defdelegate resume_global(), to: Aiur.Orchestrator.ControlCLI
  defdelegate set_max_agents(n), to: Aiur.Orchestrator.ControlCLI
  defdelegate message(issue, text, message_id \\ nil), to: Aiur.Orchestrator.ControlCLI.Message
  defdelegate pause(targets), to: Aiur.Orchestrator.ControlCLI
  defdelegate resume(targets), to: Aiur.Orchestrator.ControlCLI
  defdelegate park(targets), to: Aiur.ControlCLI.Park, as: :run
  defdelegate take(targets, owner), to: Aiur.ControlCLI.ExecutorOwnership, as: :take
  defdelegate release(targets, owner), to: Aiur.ControlCLI.ExecutorOwnership, as: :release
  defdelegate recover_workspace(ticket, generation), to: Aiur.ControlCLI.EntryPoints
  defdelegate usage(server \\ Aiur.ProviderMeterProjection, opts \\ []), to: Aiur.Accounting.CLI
  defdelegate accounts(json, harness \\ nil), to: Aiur.Accounting.CLI
  defdelegate usage_bar(percent), to: Aiur.ProviderMeters.CLI
end
