defmodule Aiur.AgentRunner.ModelLabelRefresh do
  @moduledoc """
  Gives a bare `model:<name>` label one chance to resolve before a session
  starts, and tells the Executor when it still cannot.

  The orchestrator resolves labels from the catalogue cache alone, so a model
  released since the last refresh reads as unknown there and the ticket is
  routed by complexity. Here, in the per-issue runner — never on the
  orchestrator's poll — an unresolved bare label triggers one bounded refresh
  of the CLI catalogues. Every reader resolves from that same cache, so once
  it lands the orchestrator, status report and rate-limit fallback agree on
  the backend without the issue being mutated.

  Two things keep the run on the orchestrator's choice even when the label now
  resolves: a backend already selected for the issue (priority selection or
  rate-limit fallback), and a label backend whose worker placement differs
  from the one the orchestrator scheduled. Those runs are pinned and the label
  is reported as applying from the next dispatch.
  """

  require Logger

  alias Aiur.{Alerts, CodingAgent, Config, Issue, ModelDiscovery}

  # One overall budget for refreshing every catalogue concurrently; each probe
  # is itself bounded by `ModelDiscovery.refresh_now/2`.
  @refresh_budget_ms 25_000
  @refreshable [:unknown_name, :catalog_unavailable]

  @type deferred :: {String.t(), CodingAgent.backend()} | nil

  @doc """
  Refreshes the CLI catalogues when the issue carries an unresolvable bare
  label, and returns the issue to run plus the label that resolved too late to
  apply to this run (or nil). Pass `refresh: fun` to replace
  `ModelDiscovery.refresh_now/1` and `catalogue: fun` to replace the cache
  reader.
  """
  @spec prepare(Issue.t(), keyword()) :: {Issue.t(), deferred()}
  def prepare(%Issue{} = issue, opts \\ []) do
    read = Keyword.take(opts, [:catalogue])

    case CodingAgent.model_label_status(issue, read) do
      {label, cause, backends} when cause in @refreshable ->
        before = {CodingAgent.backend_for(issue, read), CodingAgent.model_for(issue, read)}
        refresh(targets(cause, backends), opts)
        settle(issue, label, before, read)

      _resolved_or_ambiguous ->
        {issue, nil}
    end
  end

  defp settle(issue, label, {before_backend, before_model}, read) do
    label_backend = CodingAgent.override_backend(issue, read)

    cond do
      is_nil(label_backend) ->
        {issue, nil}

      is_binary(issue.selected_backend) and issue.selected_backend != label_backend ->
        {issue, {label, label_backend}}

      CodingAgent.remote_worker?(label_backend) != CodingAgent.remote_worker?(before_backend) ->
        {%{issue | selected_backend: before_backend, selected_model: before_model}, {label, label_backend}}

      true ->
        {issue, nil}
    end
  end

  # An unknown name could be new on any CLI backend; a missing catalogue names
  # exactly the backends that were never discovered.
  defp targets(:catalog_unavailable, backends), do: backends

  defp targets(:unknown_name, _backends) do
    Config.agent_backend_configs()
    |> CodingAgent.dispatchable_backends()
    |> Enum.filter(&ModelDiscovery.cli_catalogue?/1)
    |> Enum.uniq_by(&ModelDiscovery.source_key/1)
  end

  defp refresh(backends, opts) do
    refresh_one = Keyword.get(opts, :refresh, &ModelDiscovery.refresh_now/1)

    backends
    |> Task.async_stream(refresh_one, timeout: @refresh_budget_ms, on_timeout: :kill_task, ordered: false)
    |> Stream.run()
  end

  @doc """
  Raises the ticket's `model_label_unresolved` attention when a model label did
  not decide this run — it could not be resolved, or it resolved too late —
  naming the label, why, and the backend and model that ran instead.
  """
  @spec maybe_alert(Issue.t(), Path.t() | nil, String.t() | nil, CodingAgent.backend(), String.t() | nil, deferred(), keyword()) ::
          :ok
  def maybe_alert(issue, workspace, worker_host, backend, model, deferred, opts \\ []) do
    case reason(issue, backend, model, deferred, Keyword.take(opts, [:catalogue])) do
      nil ->
        :ok

      reason ->
        Logger.warning("Model label not applied for #{issue.identifier}: #{reason}")

        Alerts.emit_system("ticket.#{issue.identifier}.agent.attention.model_label_unresolved",
          issue: issue,
          workspace: workspace,
          worker_host: worker_host,
          reason: reason,
          needs_attention: true,
          severity: "warning"
        )

        :ok
    end
  end

  defp reason(_issue, backend, model, {label, label_backend}, _read) do
    "`#{label}` resolves to #{label_backend}, but this run was already placed on #{ran(backend, model)}. " <>
      "The label applies from the next dispatch."
  end

  defp reason(issue, backend, model, nil, read) do
    case CodingAgent.model_label_status(issue, read) do
      nil -> nil
      {label, cause, backends} -> cause_sentence(label, cause, backends) <> " This run used #{ran(backend, model)} instead."
    end
  end

  defp cause_sentence(label, :unknown_name, _backends) do
    "`#{label}` does not name a model any installed agent CLI offers — check the spelling, " <>
      "or pin a backend with `model:<backend>-<model>`."
  end

  defp cause_sentence(label, :ambiguous, backends) do
    "model:" <> name = label
    forms = Enum.map_join(backends, " or ", &"`model:#{&1}-#{name}`")
    "`#{label}` is offered by more than one backend (#{Enum.join(backends, ", ")}); use #{forms}."
  end

  defp cause_sentence(label, :catalog_unavailable, backends) do
    "`#{label}` could not be checked: aiur has never read a model list from #{Enum.join(backends, ", ")} " <>
      "(CLI missing, not signed in, or not answering)."
  end

  defp ran(backend, nil), do: "#{backend} (its default model)"
  defp ran(backend, model), do: "#{backend} #{model}"
end
