defmodule Aiur.Codex.CodingAgent do
  @moduledoc "Minimal client for the Codex app-server JSON-RPC 2.0 stream over stdio."

  @behaviour Aiur.CodingAgent.Backend
  @behaviour Aiur.AppServer.Adapter

  require Logger
  alias Aiur.AppServer.{Adapter, Rpc}

  alias Aiur.Codex.{
    AppServerPort,
    EventNormalizer,
    Frames,
    Handshake,
    Interrupts,
    OperatorDelivery,
    TurnEvents,
    TurnLoop
  }

  alias Aiur.Config

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

    with {:ok, expanded_workspace} <- AppServerPort.validate_workspace_cwd(workspace, worker_host),
         {:ok, port} <- AppServerPort.start_port(expanded_workspace, worker_host, model, effort) do
      metadata = AppServerPort.port_metadata(port, worker_host)

      # Local spawns run bash -lc "codex … app-server"; a remote spawn's
      # local pid is the ssh client, so the cmdline guard expects that.
      reaper_comm = if is_binary(worker_host), do: "ssh", else: "codex"
      Aiur.ProcessReaper.register(:agent, {:os_pid, metadata[:codex_app_server_pid]}, comm: reaper_comm)

      with {:ok, session_policies} <- session_policies(expanded_workspace, worker_host),
           {:ok, thread_id, resumed?} <-
             Handshake.establish(port, expanded_workspace, session_policies, resume_thread_id) do
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
           worker_host: worker_host,
           model: model
         }}
      else
        {:error, reason} ->
          AppServerPort.stop_port(port)
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
  def stop_session(%{port: port}) when is_port(port), do: AppServerPort.stop_port(port)
  @impl Aiur.CodingAgent.Backend
  def send_operator_message(session, payload), do: OperatorDelivery.send_operator_message(session, payload)
  @impl Aiur.CodingAgent.Backend
  def normalize_event(event), do: EventNormalizer.normalize_event(event)

  defp session_policies(workspace, nil), do: Config.codex_runtime_settings(workspace)
  defp session_policies(workspace, worker_host) when is_binary(worker_host), do: Config.codex_runtime_settings(workspace, remote: true)

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

  @doc false
  @spec resume_outcome({:ok, String.t()} | {:error, term()}, String.t()) ::
          {:resumed, String.t()} | {:fresh, String.t()} | {:fallback, term()}
  def resume_outcome(response, resume_thread_id), do: Handshake.resume_outcome(response, resume_thread_id)
  @doc false
  @spec codex_command_for_test(String.t() | nil, String.t() | nil) :: String.t()
  def codex_command_for_test(model, effort \\ nil), do: AppServerPort.codex_command_for_test(model, effort)
  @doc false
  @spec thread_init_frame_for_test(String.t() | nil, Path.t(), map()) :: map()
  def thread_init_frame_for_test(resume_thread_id, workspace, session_policies) do
    Frames.thread_init_frame(resume_thread_id, workspace, session_policies)
  end

  @doc false
  @spec send_thread_init_for_test(port(), map()) :: {:ok, String.t()} | {:error, term()}
  def send_thread_init_for_test(port, frame), do: Handshake.send_thread_init(port, frame)

  @doc false
  @spec await_startup_response_for_test(port(), integer(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def await_startup_response_for_test(port, request_id, read_timeout_ms) do
    function = String.to_atom("with_timeout_" <> "response")
    apply(Rpc, function, [port, request_id, Aiur.Codex.Rpc.startup_response_timeout_ms(read_timeout_ms), "", "Codex"])
  end

  @doc false
  @spec startup_response_timeout_ms_for_test(pos_integer()) :: pos_integer()
  def startup_response_timeout_ms_for_test(read_timeout_ms), do: Aiur.Codex.Rpc.startup_response_timeout_ms(read_timeout_ms)

  @doc false
  @spec parse_thread_response_for_test({:ok, map()} | {:error, term()}) :: {:ok, String.t()} | {:error, term()}
  def parse_thread_response_for_test(response), do: Handshake.parse_thread_response(response)
end
