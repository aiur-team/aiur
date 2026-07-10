defmodule Aiur.Codex.CodingAgent do
  @moduledoc "Minimal client for the Codex app-server JSON-RPC 2.0 stream over stdio."

  @behaviour Aiur.CodingAgent.Backend
  @behaviour Aiur.AppServer.Adapter

  require Logger
  alias Aiur.AppServer.{Adapter, Rpc}

  alias Aiur.Codex.{
    AppServerPort,
    EventNormalizer,
    Handshake,
    Interrupts,
    OperatorDelivery,
    TurnEvents,
    TurnLoop
  }

  alias Aiur.{Config, ModelAvailability, PauseContainment}

  @type session :: %{
          port: port(),
          metadata: map(),
          approval_policy: String.t() | map(),
          auto_approve_requests: boolean(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map(),
          thread_id: String.t(),
          resumed: boolean(),
          workspace: Path.t()
        }
  @dialyzer {:nowarn_function, run: 4}
  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    case start_session(workspace, opts) do
      {:ok, session} ->
        try do
          run_turn(session, prompt, issue, opts)
        after
          stop_session(session)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Aiur.CodingAgent.Backend
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    model = Keyword.get(opts, :model)
    effort = Keyword.get(opts, :effort)
    resume_thread_id = Keyword.get(opts, :resume_thread_id)

    identifier = Keyword.get(opts, :identifier)

    with {:ok, expanded_workspace} <- AppServerPort.validate_workspace_cwd(workspace, worker_host),
         {:ok, port} <- AppServerPort.start_port(expanded_workspace, worker_host, model, effort) do
      metadata = AppServerPort.port_metadata(port, worker_host)
      containment = register_pause_containment(identifier, metadata, expanded_workspace)

      # Local spawns run bash -lc "codex … app-server"; a remote spawn's
      # local pid is the ssh client, so the cmdline guard expects that.
      reaper_comm = if is_binary(worker_host), do: "ssh", else: "codex"
      Aiur.ProcessReaper.register(:agent, {:os_pid, metadata[:codex_app_server_pid]}, comm: reaper_comm)

      with {:ok, session_policies} <- session_policies(expanded_workspace, worker_host),
           {:ok, thread_id, resumed?, rate_limits_supported?} <-
             Handshake.establish_with_rate_limits(port, expanded_workspace, session_policies, resume_thread_id) do
        maybe_observe_rate_limits(port, rate_limits_supported?)

        {:ok,
         %{
           port: port,
           metadata: metadata,
           approval_policy: session_policies.approval_policy,
           auto_approve_requests: session_policies.approval_policy == "never",
           thread_sandbox: session_policies.thread_sandbox,
           turn_sandbox_policy: session_policies.turn_sandbox_policy,
           thread_id: thread_id,
           resumed: resumed?,
           workspace: expanded_workspace,
           containment: containment,
           worker_host: worker_host,
           model: model
         }}
      else
        {:error, reason} ->
          AppServerPort.stop_port(port)
          PauseContainment.unregister(containment)
          {:error, reason}
      end
    end
  end

  @impl Aiur.CodingAgent.Backend
  def run_turn(
        %{
          auto_approve_requests: auto_approve_requests,
          thread_id: thread_id,
          workspace: workspace
        } = session,
        prompt,
        issue,
        opts \\ []
      )
      when is_boolean(auto_approve_requests) and is_binary(thread_id) and is_binary(workspace) do
    Adapter.run_turn(__MODULE__, session, prompt, issue, opts)
  end

  @impl Aiur.CodingAgent.Backend
  def stop_session(%{port: port} = session) when is_port(port) do
    AppServerPort.stop_port(port)
    PauseContainment.unregister(Map.get(session, :containment))
  end

  @impl Aiur.CodingAgent.Backend
  def send_operator_message(session, payload), do: OperatorDelivery.send_operator_message(session, payload)
  @impl Aiur.CodingAgent.Backend
  def normalize_event(event), do: EventNormalizer.normalize_event(event)

  defp session_policies(workspace, nil), do: Config.codex_runtime_settings(workspace)
  defp session_policies(workspace, worker_host) when is_binary(worker_host), do: Config.codex_runtime_settings(workspace, remote: true)

  # This is deliberately fail-open: an unavailable account endpoint must not
  # prevent a configured backend from starting. A successful read seeds the
  # same durable ledger that rolling rate-limit notifications update later.
  defp observe_rate_limits(port) do
    case Handshake.read_rate_limits(port) do
      {:ok, rate_limits} -> ModelAvailability.observe("codex", rate_limits)
      {:error, reason} -> Logger.debug("Codex account/rateLimits/read unavailable: #{inspect(reason)}")
    end
  end

  defp maybe_observe_rate_limits(port, true), do: observe_rate_limits(port)
  defp maybe_observe_rate_limits(_port, false), do: :ok

  @impl Aiur.AppServer.Adapter
  @doc false
  def start_turn(session, prompt, issue), do: Handshake.start_turn(session, prompt, issue)
  @impl Aiur.AppServer.Adapter
  @doc false
  def backend_label, do: "Codex"
  @impl Aiur.AppServer.Adapter
  @doc false
  def loop_state_extras(session), do: %{auto_approve_requests: session.auto_approve_requests, turn_started?: false}
  @impl Aiur.AppServer.Adapter
  @doc false
  def handle_interrupt_error(state, error), do: Interrupts.handle_interrupt_error(state, error)
  @impl Aiur.AppServer.Adapter
  @doc false
  def handle_method(session, state, payload, payload_string, method),
    do: TurnLoop.handle_method(session, state, payload, payload_string, method)

  @impl Aiur.AppServer.Adapter
  @doc false
  def handle_malformed(state, payload_string, port), do: TurnLoop.handle_malformed(state, payload_string, port)
  @impl Aiur.AppServer.Adapter
  @doc false
  def metadata_from_message(port, payload), do: TurnEvents.metadata_from_message(port, payload)
  @impl Aiur.AppServer.Adapter
  @doc false
  def send_frame(port, frame) do
    Rpc.send_line(port, frame)
    :ok
  rescue
    ArgumentError -> {:error, :port_closed}
  end

  defp register_pause_containment(identifier, metadata, workspace) when is_binary(identifier) do
    with pid when is_binary(pid) <- metadata[:codex_app_server_pid],
         group when is_binary(group) <- metadata[:agent_process_group_id],
         {root_pid, ""} <- Integer.parse(pid),
         {process_group_id, ""} <- Integer.parse(group) do
      case PauseContainment.register(identifier, root_pid, process_group_id, workspace: workspace) do
        {:ok, handle} -> handle
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  defp register_pause_containment(_identifier, _metadata, _workspace), do: nil
end
