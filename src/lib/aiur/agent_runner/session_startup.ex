defmodule Aiur.AgentRunner.SessionStartup do
  @moduledoc false
  require Logger
  alias Aiur.AgentRunner.CodexUpdateRelay
  alias Aiur.CodingAgent
  alias Aiur.Issue
  alias Aiur.ModelDiscovery
  alias Aiur.Signal
  @type worker_host :: String.t() | nil

  @doc false
  @spec start_with_telemetry(term(), term(), term(), term(), term(), term(), term()) :: term()
  def start_with_telemetry(workspace, issue, worker_host, ownership, session_opts, start_fun, execution_recipient) do
    case prepare_telemetry_launch(issue, worker_host, ownership, session_opts, execution_recipient) do
      {:ok, telemetry_launch} ->
        launch_opts =
          with_telemetry_launch_opts(session_opts, telemetry_launch, issue, worker_host, ownership, execution_recipient)

        case start_agent_session(workspace, launch_opts, start_fun) do
          {:ok, session} ->
            revoke_unclaimed_telemetry_launch(session, telemetry_launch, session_opts)
            {:ok, session}

          {:error, _reason} = error ->
            _ = CodingAgent.revoke_launch_telemetry(Keyword.fetch!(session_opts, :backend), telemetry_launch, session_opts)
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp prepare_telemetry_launch(_issue, _worker_host, nil, _session_opts, _execution_recipient), do: {:ok, nil}

  defp prepare_telemetry_launch(issue, worker_host, ownership, session_opts, execution_recipient) do
    CodingAgent.prepare_launch_telemetry(Keyword.fetch!(session_opts, :backend), issue,
      launch_telemetry_registry: Keyword.get_lazy(session_opts, :launch_telemetry_registry, &CodingAgent.backends/0),
      attempt_id: Keyword.get(session_opts, :attempt_id),
      workspace_ownership: ownership,
      backend: Keyword.get(session_opts, :backend),
      worker_host: worker_host,
      execution_recipient: execution_recipient
    )
  end

  defp with_telemetry_launch_opts(session_opts, nil, _issue, _worker_host, _ownership, _recipient), do: session_opts

  defp with_telemetry_launch_opts(session_opts, telemetry_launch, issue, worker_host, ownership, execution_recipient) do
    fallback_launch_fun = fn fallback_backend ->
      CodingAgent.prepare_launch_telemetry(fallback_backend, issue,
        launch_telemetry_registry: Keyword.get_lazy(session_opts, :launch_telemetry_registry, &CodingAgent.backends/0),
        attempt_id: Keyword.get(session_opts, :attempt_id),
        workspace_ownership: ownership,
        backend: fallback_backend,
        worker_host: worker_host,
        execution_recipient: execution_recipient
      )
    end

    session_opts
    |> Keyword.put(:telemetry_launch, telemetry_launch)
    |> Keyword.put(:telemetry_fallback_launch_fun, fallback_launch_fun)
  end

  defp revoke_unclaimed_telemetry_launch(_session, nil, _opts), do: :ok

  defp revoke_unclaimed_telemetry_launch(%{telemetry_launch: %{id: id}}, %{id: id}, _opts) when is_reference(id), do: :ok

  defp revoke_unclaimed_telemetry_launch(_session, telemetry_launch, opts) do
    # A REPL can fall back to the headless adapter after a failed pane spawn.
    # Never reuse a capability whose trusted backend correlation says REPL for
    # that replacement process; the fallback remains visibly uncovered until a
    # fresh, correctly correlated launch is prepared.
    CodingAgent.revoke_launch_telemetry(Keyword.fetch!(opts, :backend), telemetry_launch, opts)
  end

  @doc false
  # Start the resolved backend's session, tagging it with its backend so
  # later dispatch resolves the right adapter. A backend may declare a
  # registry `fallback_backend` (the persistent REPL can fail to start: no
  # tmux, REPL never ready, RC activation failed — and a tmux/RC problem
  # must never strand an issue); on a start failure the fallback backend
  # is tried once, with `:remote_control` stripped, and the reason
  # recorded. `start_fun` is injectable for tests; production uses
  # `CodingAgent.start_session/2`.
  @spec start_agent_session(Path.t(), keyword(), fun()) :: {:ok, map()} | {:error, term()}
  def start_agent_session(workspace, opts, start_fun \\ &CodingAgent.start_session/2) do
    backend = Keyword.fetch!(opts, :backend)
    adapter_opts = Keyword.delete(opts, :attempt_id)

    case Keyword.fetch(opts, :account_selection_error) do
      {:ok, reason} -> {:error, {:account_selection, reason}}
      :error -> start_selected_session(workspace, opts, adapter_opts, backend, start_fun)
    end
  end

  defp start_selected_session(workspace, opts, adapter_opts, backend, start_fun) do
    case start_fun.(workspace, adapter_opts) do
      {:ok, session} ->
        {:ok, tag_session(session, backend, opts)}

      {:error, :remote_control_requires_dashboard} = error ->
        error

      {:error, {:repl_cleanup_failed, _reason}} = error ->
        error

      {:error, reason} = error ->
        case CodingAgent.fallback_backend(backend) do
          nil -> error
          fallback -> start_fallback_session(workspace, opts, start_fun, backend, fallback, reason)
        end
    end
  end

  defp start_fallback_session(workspace, opts, start_fun, backend, fallback, reason) do
    Aiur.Perf.event(:repl_start_fallback, backend: backend, reason: inspect(reason))

    Logger.warning("#{backend} start_session failed (#{inspect(reason)}); falling back to #{fallback}")

    {telemetry_launch, fallback_opts} = Keyword.pop(opts, :telemetry_launch)
    _ = CodingAgent.revoke_launch_telemetry(backend, telemetry_launch, opts)
    {fallback_launch_fun, fallback_opts} = Keyword.pop(fallback_opts, :telemetry_fallback_launch_fun)

    with {:ok, fallback_launch} <- prepare_fallback_telemetry(fallback_launch_fun, fallback) do
      fallback_opts =
        fallback_opts
        |> Keyword.put(:backend, fallback)
        |> Keyword.delete(:remote_control)
        |> maybe_put_telemetry_launch_opt(fallback_launch)

      case start_fun.(workspace, Keyword.delete(fallback_opts, :attempt_id)) do
        {:ok, session} ->
          {:ok, tag_session(session, fallback, fallback_opts)}

        {:error, _} = error ->
          _ = CodingAgent.revoke_launch_telemetry(fallback, fallback_launch, opts)
          error
      end
    end
  end

  defp prepare_fallback_telemetry(fun, fallback) when is_function(fun, 1), do: fun.(fallback)
  defp prepare_fallback_telemetry(_fun, _fallback), do: {:ok, nil}

  defp maybe_put_telemetry_launch_opt(opts, nil), do: opts
  defp maybe_put_telemetry_launch_opt(opts, launch), do: Keyword.put(opts, :telemetry_launch, launch)

  defp tag_session(session, backend, opts) do
    session
    |> Map.put(:backend, backend)
    |> Map.put(:model, established_model(session, opts))
    |> Map.put(:effort, supported_effort(backend, Keyword.get(opts, :effort)))
    |> maybe_put_attempt_id(Keyword.get(opts, :attempt_id))
    |> maybe_put_telemetry_launch_session(Keyword.get(opts, :telemetry_launch))
  end

  defp established_model(%{model: model}, opts) when is_binary(model) do
    if String.trim(model) == "", do: Keyword.get(opts, :model), else: model
  end

  defp established_model(_session, opts), do: Keyword.get(opts, :model)

  defp supported_effort(backend, effort) when is_binary(effort) do
    if effort in CodingAgent.efforts(backend) do
      effort
    else
      Logger.warning(
        "Ignoring effort #{inspect(effort)} for backend #{backend}: not in its supported efforts " <>
          "#{inspect(CodingAgent.efforts(backend))} (pair a model:<effort> label with model:remote to run on a transport that supports effort)"
      )

      nil
    end
  end

  defp supported_effort(_backend, _effort), do: nil

  # A model aiur doesn't recognize is far more likely to be newer than this
  # build than to be wrong, so it is never blocked and never quietly swapped
  # for the backend default — either would hide the real problem. Instead the
  # Executor gets one attention naming both remediations: wait for the next
  # model-list read to learn the new model, or repoint a retired pin at a
  # generic family tag.
  #
  # "Recognized" spans the curated registry list *and* the provider catalogue
  # cache (`Aiur.ModelDiscovery`), so a model the provider currently serves
  # does not raise an attention just because this build predates it. Reading
  # that set is also what schedules the cache's background refresh; it never
  # blocks this call and an empty cache degrades to the curated list.
  @doc false
  @spec maybe_alert_unsupported_model(Issue.t(), Path.t() | nil, worker_host(), String.t(), String.t() | nil) :: :ok
  def maybe_alert_unsupported_model(issue, workspace, worker_host, backend, model) when is_binary(model) do
    if ModelDiscovery.known_model?(backend, model) do
      :ok
    else
      reason = unsupported_model_reason(backend, model)
      Logger.warning("Unknown model #{inspect(model)} for backend #{backend}: #{reason}")

      Signal.alert("ticket.#{issue.identifier}.agent.attention.unsupported_model",
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

  def maybe_alert_unsupported_model(_issue, _workspace, _worker_host, _backend, _model), do: :ok

  defp unsupported_model_reason(backend, model) do
    generic = List.first(CodingAgent.model_aliases(backend)) || List.first(CodingAgent.seedable_models(backend))

    "Model #{inspect(model)} is not one aiur knows for the #{backend} backend " <>
      "(known: #{Enum.join(CodingAgent.seedable_models(backend), ", ")}). It is being passed to the backend " <>
      "unchanged — aiur is not substituting a different model. If it is a newly released model, aiur recognises " <>
      "it once it next reads the backend's model list from its CLI; no upgrade or new label is needed. If it is a " <>
      "retired version, repoint the issue label or the `agent.routing` entry at a generic tag such as " <>
      "#{inspect(generic)}, which always resolves to the newest model in that family."
  end

  defp maybe_put_attempt_id(session, attempt_id) when is_binary(attempt_id), do: Map.put(session, :attempt_id, attempt_id)
  defp maybe_put_attempt_id(session, _attempt_id), do: session
  defp maybe_put_telemetry_launch_session(session, %{id: id}) when is_reference(id), do: Map.put(session, :telemetry_launch, %{id: id})
  defp maybe_put_telemetry_launch_session(session, _launch), do: session
  @doc false
  @spec record_session_start_failure(term(), term(), term()) :: term()
  def record_session_start_failure(issue, session_context, reason) do
    observed_at = DateTime.utc_now()

    Signal.lifecycle(
      issue.identifier,
      session_context.lifecycle_attempt_id,
      :agent_spinup,
      :end,
      %{
        operation_id: "session",
        backend: session_context.session_backend,
        outcome: :failed,
        reason_class: Signal.reason_class(reason),
        exit_status: startup_exit_status(reason)
      },
      timestamp: observed_at
    )

    if is_pid(session_context.update_recipient) and match?({:port_exit, status} when is_integer(status), reason) do
      CodexUpdateRelay.relay(session_context.update_recipient, issue.id, %{
        event: :startup_failed,
        reason: reason,
        timestamp: observed_at
      })
    end
  end

  defp startup_exit_status({:port_exit, status}) when is_integer(status), do: status
  defp startup_exit_status(_reason), do: nil
end
