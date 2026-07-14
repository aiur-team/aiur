defmodule Aiur.Codex.CodingAgent do
  @moduledoc "Minimal client for the Codex app-server JSON-RPC 2.0 stream over stdio."

  @behaviour Aiur.CodingAgent.Backend
  @behaviour Aiur.AppServer.Adapter

  require Logger
  alias Aiur.AppServer.{Adapter, Messages, Rpc}

  alias Aiur.Codex.{
    AccountGeneration,
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
          workspace: Path.t(),
          account_generation_binding: reference()
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
    on_message = Keyword.get(opts, :on_message, &Messages.default_on_message/1)
    account_generation_server = Keyword.get(opts, :account_generation_server, Aiur.ProviderAccountGeneration)

    with {:ok, expanded_workspace} <- AppServerPort.validate_workspace_cwd(workspace, worker_host),
         {:ok, port} <- AppServerPort.start_port(expanded_workspace, worker_host, model, effort) do
      metadata = AppServerPort.port_metadata(port, worker_host)
      containment = register_pause_containment(identifier, metadata, expanded_workspace)

      account_generation = AccountGeneration.new_binding(account_generation_server)

      lifecycle_session = %{
        port: port,
        metadata: metadata,
        account_generation_binding: account_generation.binding,
        account_generation_authority: account_generation.authority,
        account_generation_context: account_generation.context,
        account_generation_server: account_generation_server
      }

      notification_handler = lifecycle_notification_handler(lifecycle_session, on_message)
      handshake_opts = [on_notification: notification_handler]

      # Local spawns run bash -lc "codex … app-server"; a remote spawn's
      # local pid is the ssh client, so the cmdline guard expects that.
      reaper_comm = if is_binary(worker_host), do: "ssh", else: "codex"

      Aiur.ProcessReaper.register(:agent, {:os_pid, metadata[:codex_app_server_pid]},
        comm: reaper_comm,
        ticket: identifier,
        backend: "codex",
        worker_host: worker_host,
        remote: is_binary(worker_host)
      )

      with {:ok, session_policies} <- session_policies(expanded_workspace, worker_host),
           {:ok, thread_id, resumed?, supports_account_reads?} <-
             Handshake.establish_with_rate_limits(
               port,
               expanded_workspace,
               session_policies,
               resume_thread_id,
               handshake_opts
             ) do
        maybe_observe_rate_limits(port, supports_account_reads?, handshake_opts)
        maybe_seed_account(port, lifecycle_session, supports_account_reads?, handshake_opts)

        {:ok,
         lifecycle_session
         |> Map.merge(%{
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
           model: model,
           account_generation_notification_handler: notification_handler
         })}
      else
        {:error, reason} ->
          AccountGeneration.process_stopped(lifecycle_session)
          cleanup_session_port(port, containment)
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
    AccountGeneration.process_stopped(session)
  after
    cleanup_session_port(port, Map.get(session, :containment))
  end

  @impl Aiur.CodingAgent.Backend
  def send_operator_message(session, payload), do: OperatorDelivery.send_operator_message(session, payload)
  @impl Aiur.CodingAgent.Backend
  def normalize_event(event), do: EventNormalizer.normalize_event(event)

  defp session_policies(workspace, nil), do: Config.codex_runtime_settings(workspace)
  defp session_policies(workspace, worker_host) when is_binary(worker_host), do: Config.codex_runtime_settings(workspace, remote: true)

  # This is deliberately fail-open: a rate-limit endpoint cannot prevent a
  # configured backend from starting.
  defp observe_rate_limits(port, handshake_opts) do
    case Handshake.read_rate_limits(port, handshake_opts) do
      {:ok, rate_limits} -> ModelAvailability.observe("codex", rate_limits)
      {:error, _reason} -> Logger.debug("Codex account/rateLimits/read unavailable")
    end
  end

  defp maybe_observe_rate_limits(port, true, handshake_opts), do: observe_rate_limits(port, handshake_opts)
  defp maybe_observe_rate_limits(_port, false, _handshake_opts), do: :ok

  defp maybe_seed_account(port, lifecycle_session, true, handshake_opts) do
    case Handshake.read_account(port, handshake_opts) do
      {:ok, account_response} -> AccountGeneration.seed_from_account_read(lifecycle_session, account_response)
      {:error, _reason} -> Logger.debug("Codex account/read unavailable")
    end
  end

  defp maybe_seed_account(_port, _lifecycle_session, false, _handshake_opts), do: :ok

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

  defp cleanup_session_port(port, containment) do
    AppServerPort.stop_port(port)
  after
    PauseContainment.unregister(containment)
  end

  defp lifecycle_notification_handler(session, on_message) do
    fn
      %{"method" => method} = payload when is_binary(method) ->
        case AccountGeneration.handle_notification(session, method, payload) do
          {:redacted, details} ->
            Messages.emit_message(on_message, :notification, details, TurnEvents.metadata_from_message(session.port, details.payload))
            :handled

          :ignore ->
            :ignore
        end

      _payload ->
        :ignore
    end
  end
end
