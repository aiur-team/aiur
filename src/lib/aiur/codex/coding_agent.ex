defmodule Aiur.Codex.CodingAgent do
  @moduledoc """
  Minimal client for the Codex app-server JSON-RPC 2.0 stream over stdio.
  """

  @behaviour Aiur.CodingAgent.Backend
  @behaviour Aiur.AppServer.Adapter

  require Logger
  alias Aiur.AppServer.{Adapter, Messages, Rpc}
  alias Aiur.Codex.{AppServerPort, Frames, Handshake, Interrupts, OperatorDelivery, TurnLoop}
  alias Aiur.Config
  alias Aiur.Protocol.MapAccess
  alias Aiur.TokenUsage

  @non_interactive_tool_input_answer "This is a non-interactive session. Operator input is unavailable."

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

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
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

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
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

  @spec stop_session(session()) :: :ok
  @impl Aiur.CodingAgent.Backend
  def stop_session(%{port: port}) when is_port(port) do
    AppServerPort.stop_port(port)
  end

  @spec send_operator_message(session(), Aiur.CodingAgent.operator_payload()) ::
          {:ok, integer()} | {:error, term()}
  @impl Aiur.CodingAgent.Backend
  def send_operator_message(session, payload), do: OperatorDelivery.send_operator_message(session, payload)

  defp session_policies(workspace, nil) do
    Config.codex_runtime_settings(workspace)
  end

  defp session_policies(workspace, worker_host) when is_binary(worker_host) do
    Config.codex_runtime_settings(workspace, remote: true)
  end

  @impl Aiur.AppServer.Adapter
  @doc false
  @spec start_turn(session(), String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def start_turn(session, prompt, issue), do: Handshake.start_turn(session, prompt, issue)

  @impl Aiur.AppServer.Adapter
  @doc false
  @spec backend_label() :: String.t()
  def backend_label, do: "Codex"

  @impl Aiur.AppServer.Adapter
  @doc false
  @spec loop_state_extras(session()) :: map()
  def loop_state_extras(session) do
    %{auto_approve_requests: session.auto_approve_requests, turn_started?: false}
  end

  @impl Aiur.AppServer.Adapter
  @doc false
  @spec handle_interrupt_error(map(), term()) :: {:continue, map()} | {:error, term()}
  def handle_interrupt_error(state, error), do: Interrupts.handle_interrupt_error(state, error)

  @impl Aiur.AppServer.Adapter
  @doc false
  @spec handle_method(map(), map(), map(), String.t(), String.t()) :: term()
  def handle_method(session, state, payload, payload_string, method),
    do: TurnLoop.handle_method(session, state, payload, payload_string, method)

  @impl Aiur.AppServer.Adapter
  @doc false
  @spec handle_malformed(map(), String.t(), port()) :: {:continue, map()}
  def handle_malformed(state, payload_string, port), do: TurnLoop.handle_malformed(state, payload_string, port)

  @doc false
  @spec checkpoint_for_method(String.t()) :: map()
  def checkpoint_for_method("item/tool/call"), do: %{kind: :tool_result, method: "item/tool/call"}
  def checkpoint_for_method(method), do: %{kind: :notification, method: method}

  @doc false
  @spec thread_idle_status?(String.t(), map()) :: boolean()
  def thread_idle_status?("thread/status/changed", %{"params" => %{"status" => %{"type" => "idle"}}}), do: true
  def thread_idle_status?("thread/status/changed", %{"status" => %{"type" => "idle"}}), do: true
  def thread_idle_status?(_method, _payload), do: false

  @doc false
  @spec turn_started_method?(String.t()) :: boolean()
  def turn_started_method?("turn/started"), do: true
  def turn_started_method?(_method), do: false

  @doc false
  @spec maybe_handle_approval_request(
          port(),
          String.t(),
          map(),
          String.t(),
          (map() -> term()),
          map(),
          (term(), term() -> term()),
          boolean()
        ) :: :approved | :approval_required | :input_required | :unhandled
  def maybe_handle_approval_request(
        port,
        "item/commandExecution/requestApproval",
        %{"id" => id} = payload,
        payload_string,
        on_message,
        metadata,
        _tool_executor,
        auto_approve_requests
      ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  def maybe_handle_approval_request(
        port,
        "item/tool/call",
        %{"id" => id, "params" => params} = payload,
        payload_string,
        on_message,
        metadata,
        tool_executor,
        _auto_approve_requests
      ) do
    tool_name = Messages.tool_call_name(params)
    arguments = Messages.tool_call_arguments(params)

    result = Messages.normalize_tool_result(tool_executor.(tool_name, arguments))

    send_message(port, %{
      "id" => id,
      "result" => result
    })

    event =
      case result do
        %{"success" => true} -> :tool_call_completed
        _ when is_nil(tool_name) -> :unsupported_tool_call
        _ -> :tool_call_failed
      end

    Messages.emit_message(on_message, event, %{payload: payload, raw: payload_string}, metadata)

    :approved
  end

  def maybe_handle_approval_request(
        port,
        "execCommandApproval",
        %{"id" => id} = payload,
        payload_string,
        on_message,
        metadata,
        _tool_executor,
        auto_approve_requests
      ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  def maybe_handle_approval_request(
        port,
        "applyPatchApproval",
        %{"id" => id} = payload,
        payload_string,
        on_message,
        metadata,
        _tool_executor,
        auto_approve_requests
      ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  def maybe_handle_approval_request(
        port,
        "item/fileChange/requestApproval",
        %{"id" => id} = payload,
        payload_string,
        on_message,
        metadata,
        _tool_executor,
        auto_approve_requests
      ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  def maybe_handle_approval_request(
        port,
        "item/tool/requestUserInput",
        %{"id" => id, "params" => params} = payload,
        payload_string,
        on_message,
        metadata,
        _tool_executor,
        auto_approve_requests
      ) do
    maybe_auto_answer_tool_request_user_input(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  def maybe_handle_approval_request(
        _port,
        _method,
        _payload,
        _payload_string,
        _on_message,
        _metadata,
        _tool_executor,
        _auto_approve_requests
      ) do
    :unhandled
  end

  defp approve_or_require(
         port,
         id,
         decision,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    send_message(port, %{"id" => id, "result" => %{"decision" => decision}})

    Messages.emit_message(
      on_message,
      :approval_auto_approved,
      %{payload: payload, raw: payload_string, decision: decision},
      metadata
    )

    :approved
  end

  defp approve_or_require(
         _port,
         _id,
         _decision,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         false
       ) do
    :approval_required
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    case tool_request_user_input_approval_answers(params) do
      {:ok, answers, decision} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        Messages.emit_message(
          on_message,
          :approval_auto_approved,
          %{payload: payload, raw: payload_string, decision: decision},
          metadata
        )

        :approved

      :error ->
        reply_with_non_interactive_tool_input_answer(
          port,
          id,
          params,
          payload,
          payload_string,
          on_message,
          metadata
        )
    end
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         false
       ) do
    reply_with_non_interactive_tool_input_answer(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata
    )
  end

  defp tool_request_user_input_approval_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_approval_answer(question) do
          {:ok, question_id, answer_label} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [answer_label]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map, "Approve this Session"}
      _ -> :error
    end
  end

  defp tool_request_user_input_approval_answers(_params), do: :error

  defp reply_with_non_interactive_tool_input_answer(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata
       ) do
    case tool_request_user_input_unavailable_answers(params) do
      {:ok, answers} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        Messages.emit_message(
          on_message,
          :tool_input_auto_answered,
          %{payload: payload, raw: payload_string, answer: @non_interactive_tool_input_answer},
          metadata
        )

        :approved

      :error ->
        :input_required
    end
  end

  defp tool_request_user_input_unavailable_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_question_id(question) do
          {:ok, question_id} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [@non_interactive_tool_input_answer]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map}
      _ -> :error
    end
  end

  defp tool_request_user_input_unavailable_answers(_params), do: :error

  defp tool_request_user_input_question_id(%{"id" => question_id}) when is_binary(question_id),
    do: {:ok, question_id}

  defp tool_request_user_input_question_id(_question), do: :error

  defp tool_request_user_input_approval_answer(%{"id" => question_id, "options" => options})
       when is_binary(question_id) and is_list(options) do
    case tool_request_user_input_approval_option_label(options) do
      nil -> :error
      answer_label -> {:ok, question_id, answer_label}
    end
  end

  defp tool_request_user_input_approval_answer(_question), do: :error

  defp tool_request_user_input_approval_option_label(options) do
    options
    |> Enum.map(&tool_request_user_input_option_label/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      labels ->
        Enum.find(labels, &(&1 == "Approve this Session")) ||
          Enum.find(labels, &(&1 == "Approve Once")) ||
          Enum.find(labels, &approval_option_label?/1)
    end
  end

  defp tool_request_user_input_option_label(%{"label" => label}) when is_binary(label), do: label
  defp tool_request_user_input_option_label(_option), do: nil

  defp approval_option_label?(label) when is_binary(label) do
    normalized_label =
      label
      |> String.trim()
      |> String.downcase()

    String.starts_with?(normalized_label, "approve") or String.starts_with?(normalized_label, "allow")
  end

  @spec normalize_event(map()) :: map()
  @impl Aiur.CodingAgent.Backend
  def normalize_event(event) when is_map(event) do
    event
    |> normalize_usage()
    |> normalize_rate_limits()
  end

  defp normalize_usage(event) do
    payloads = [
      event[:usage],
      Map.get(event, "usage"),
      event[:payload],
      Map.get(event, "payload"),
      event
    ]

    usage =
      Enum.find_value(payloads, &absolute_token_usage/1) ||
        Enum.find_value(payloads, &turn_completed_usage/1) ||
        Enum.find_value(payloads, &direct_token_map/1)

    Map.put(event, :usage, TokenUsage.canonicalize(usage))
  end

  defp normalize_rate_limits(event) do
    raw =
      find_rate_limits(event[:rate_limits]) ||
        find_rate_limits(Map.get(event, "rate_limits")) ||
        find_rate_limits(event[:payload]) ||
        find_rate_limits(Map.get(event, "payload")) ||
        find_rate_limits(event)

    Map.put(event, :rate_limits, raw)
  end

  defp absolute_token_usage(payload) when is_map(payload) do
    paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    Enum.find_value(paths, fn path ->
      value = MapAccess.dig(payload, path)
      if is_map(value) and TokenUsage.token_field?(value), do: value
    end)
  end

  defp absolute_token_usage(_), do: nil

  defp turn_completed_usage(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") || Map.get(payload, :usage) ||
          MapAccess.dig(payload, ["params", "usage"]) || MapAccess.dig(payload, [:params, :usage])

      if is_map(direct) and TokenUsage.token_field?(direct), do: direct
    end
  end

  defp turn_completed_usage(_), do: nil

  defp direct_token_map(payload) when is_map(payload) do
    if TokenUsage.token_field?(payload), do: payload
  end

  defp direct_token_map(_), do: nil

  defp find_rate_limits(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) -> direct
      rate_limits_map?(payload) -> payload
      true -> search_rate_limits(payload)
    end
  end

  defp find_rate_limits(_), do: nil

  defp search_rate_limits(payload) when is_map(payload) do
    Enum.find_value(Map.values(payload), fn
      value when is_map(value) -> find_rate_limits(value)
      _ -> nil
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    has_id =
      !is_nil(
        Map.get(payload, "limit_id") || Map.get(payload, :limit_id) ||
          Map.get(payload, "limit_name") || Map.get(payload, :limit_name)
      )

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    has_id and has_buckets
  end

  defp rate_limits_map?(_), do: false

  @impl Aiur.AppServer.Adapter
  @doc false
  @spec metadata_from_message(port(), term()) :: map()
  def metadata_from_message(port, payload) do
    port |> AppServerPort.port_metadata() |> maybe_set_usage(payload)
  end

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    usage = Map.get(payload, "usage") || Map.get(payload, :usage)

    if is_map(usage) do
      Map.put(metadata, :usage, usage)
    else
      metadata
    end
  end

  defp maybe_set_usage(metadata, _payload), do: metadata

  @impl Aiur.AppServer.Adapter
  @doc false
  @spec send_frame(port(), map()) :: :ok | {:error, :port_closed}
  def send_frame(port, frame) do
    Rpc.send_line(port, frame)
    :ok
  rescue
    ArgumentError -> {:error, :port_closed}
  end

  defp send_message(port, message) do
    Aiur.Codex.Rpc.send_message(port, message)
  end

  @doc false
  @spec needs_input?(String.t(), map()) :: boolean()
  def needs_input?(method, payload)
      when is_binary(method) and is_map(payload) do
    String.starts_with?(method, "turn/") && input_required_method?(method, payload)
  end

  def needs_input?(_method, _payload), do: false

  # Identify error-class notifications that should be surfaced at info
  # level with their payload, not buried at debug. Codex sends "error"
  # as a top-level method when the API itself fails (rate limit, auth,
  # transport timeout). It also sends `*/error`-suffixed methods for
  # subsystem failures. Without these surfacing rules an operator
  # debugging a stuck agent has to enable debug logging globally and
  # then grep through 1000s of lines of routine MCP notifications.
  @doc false
  @spec codex_error_method?(String.t()) :: boolean()
  def codex_error_method?(method) when is_binary(method) do
    method == "error" or String.ends_with?(method, "/error")
  end

  defp input_required_method?(method, payload) when is_binary(method) do
    method in [
      "turn/input_required",
      "turn/needs_input",
      "turn/need_input",
      "turn/request_input",
      "turn/request_response",
      "turn/provide_input",
      "turn/approval_required"
    ] || request_payload_requires_input?(payload)
  end

  defp request_payload_requires_input?(payload) do
    params = Map.get(payload, "params")
    needs_input_field?(payload) || needs_input_field?(params)
  end

  defp needs_input_field?(payload) when is_map(payload) do
    Map.get(payload, "requiresInput") == true or
      Map.get(payload, "needsInput") == true or
      Map.get(payload, "input_required") == true or
      Map.get(payload, "inputRequired") == true or
      Map.get(payload, "type") == "input_required" or
      Map.get(payload, "type") == "needs_input"
  end

  defp needs_input_field?(_payload), do: false

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
    timeout_ms = Aiur.Codex.Rpc.startup_response_timeout_ms(read_timeout_ms)

    apply(Rpc, function, [port, request_id, timeout_ms, "", "Codex"])
  end

  @doc false
  @spec startup_response_timeout_ms_for_test(pos_integer()) :: pos_integer()
  def startup_response_timeout_ms_for_test(read_timeout_ms), do: Aiur.Codex.Rpc.startup_response_timeout_ms(read_timeout_ms)

  @doc false
  @spec parse_thread_response_for_test({:ok, map()} | {:error, term()}) :: {:ok, String.t()} | {:error, term()}
  def parse_thread_response_for_test(response), do: Handshake.parse_thread_response(response)

  @doc false
  @spec unretryable_codex_error_for_test(map()) :: boolean()
  def unretryable_codex_error_for_test(payload) when is_map(payload), do: unretryable_codex_error?(payload)

  @doc false
  @spec codex_error_reason_for_test(map(), String.t()) :: String.t()
  def codex_error_reason_for_test(payload, method) when is_map(payload) and is_binary(method) do
    codex_error_reason(payload, method)
  end

  @doc false
  @spec usage_limit_exceeded_for_test(map()) :: boolean()
  def usage_limit_exceeded_for_test(payload) when is_map(payload), do: usage_limit_exceeded?(payload)

  @doc false
  @spec usage_limit_reset_hint_for_test(map()) :: String.t() | nil
  def usage_limit_reset_hint_for_test(payload) when is_map(payload), do: usage_limit_reset_hint(payload)

  # Routing-only helper for quota-pause and unretryable-error branches.
  @doc false
  @spec notification_outcome_for_test(String.t(), map()) :: tuple()
  def notification_outcome_for_test(method, payload) when is_binary(method) and is_map(payload) do
    port =
      Port.open(
        {:spawn_executable, System.find_executable("cat") |> String.to_charlist()},
        [:binary, :exit_status, {:line, 64_000}]
      )

    try do
      payload = Map.put(payload, "method", method)

      state = %{
        on_message: fn _message -> :ok end,
        tool_executor: fn _tool, _arguments -> %{} end,
        auto_approve_requests: false,
        pending_operator_requests: %{},
        turn_started?: false
      }

      TurnLoop.handle_method(%{port: port}, state, payload, Jason.encode!(payload), method)
    after
      Port.close(port)
    end
  end

  @doc false
  @spec codex_quota_exhausted_for_test(String.t(), map()) :: boolean()
  def codex_quota_exhausted_for_test(method, payload) when is_binary(method) and is_map(payload) do
    codex_quota_exhausted?(method, payload)
  end

  # The flag can ride on the notification root or inside `params`, and
  # codex has used both camelCase and snake_case across versions, so
  # check all four positions (mirrors `request_payload_requires_input?`).
  @doc false
  @spec unretryable_codex_error?(map()) :: boolean()
  def unretryable_codex_error?(payload) do
    will_retry_false?(payload) || will_retry_false?(Map.get(payload, "params"))
  end

  defp will_retry_false?(payload) when is_map(payload) do
    Map.get(payload, "willRetry") == false or Map.get(payload, "will_retry") == false
  end

  defp will_retry_false?(_payload), do: false

  # Quota exhaustion is the subset of *unretryable* error-method turn failures
  # (codex sets willRetry:false when the account quota is gone) whose detail
  # names a usage limit. Gating on `unretryable_codex_error?` as well keeps a
  # merely transient error that happens to mention "usage limit" from stranding
  # the agent in a pause — a pause has no auto-resume timer, so such errors must
  # fall through to the normal retry path instead.
  @doc false
  @spec codex_quota_exhausted?(String.t(), map()) :: boolean()
  def codex_quota_exhausted?(method, payload) do
    codex_error_method?(method) and unretryable_codex_error?(payload) and
      usage_limit_exceeded?(payload)
  end

  # A `usageLimitExceeded` turn error means the codex/ChatGPT account quota is
  # exhausted (it resets at a stated time) — NOT a transient rate limit, so
  # immediate retries cannot help and only burn the agent's retry budget into
  # `agent:error`. Detect it robustly (codex stashes the marker under different
  # keys across versions) and route the turn to a pause + operator alert. The
  # inspected-payload scan mirrors the agent runner's `more_tokens_reason?` and
  # survives field-name drift. Kept total (no `is_map` guard) so a malformed
  # non-map payload degrades to `false` rather than crashing the receive loop.
  defp usage_limit_exceeded?(payload) do
    payload
    |> inspect()
    |> String.downcase()
    |> String.contains?(["usagelimitexceeded", "usage limit"])
  end

  # Pause payload for a quota-exhaustion turn error. `kind` lets the agent
  # runner emit the operator alert; `reset_hint` carries the human-readable
  # "try again at …" time when codex provides one.
  @doc false
  @spec usage_limit_pause(map(), String.t()) :: map()
  def usage_limit_pause(payload, method) do
    %{
      kind: :usage_limit_exhausted,
      reason: codex_error_reason(payload, method),
      reset_hint: usage_limit_reset_hint(payload)
    }
  end

  # Best-effort: pull the "try again at 11:43 PM" reset time out of whatever
  # human message codex attached. Returns nil when no such phrase is present.
  # Kept total (no `is_map` guard) to match `usage_limit_exceeded?/1`.
  defp usage_limit_reset_hint(payload) do
    case Regex.run(~r/try again at ([^."\n]+)/i, inspect(payload)) do
      [_, when_str] -> String.trim(when_str)
      _ -> nil
    end
  end

  # Best-effort human-readable reason for the failure tuple/log/alert. Control
  # flow keys only on `willRetry`; the detail field name varies across codex
  # versions, so check the known positions (root + params + nested error) and
  # fall back to the method when no recognizable detail is present — never the
  # bare opaque `"error"` when a detail is actually available.
  @doc false
  @spec codex_error_reason(map(), String.t()) :: String.t()
  def codex_error_reason(payload, method) do
    case codex_error_detail(payload) do
      detail when is_binary(detail) and detail != "" -> "#{method}: #{detail}"
      _ -> method
    end
  end

  defp codex_error_detail(payload) do
    params = Map.get(payload, "params") || %{}
    params_error = ensure_map(Map.get(params, "error"))
    root_error = ensure_map(Map.get(payload, "error"))
    nested = Map.merge(params_error, root_error)

    [
      Map.get(params, "message"),
      Map.get(params, "codexErrorInfo"),
      Map.get(nested, "message"),
      Map.get(params, "type"),
      Map.get(params, "code"),
      Map.get(nested, "type"),
      Map.get(nested, "code"),
      Map.get(payload, "message")
    ]
    |> Enum.find(fn value -> is_binary(value) and value != "" end)
  end

  defp ensure_map(value) when is_map(value), do: value
  defp ensure_map(_value), do: %{}
end
