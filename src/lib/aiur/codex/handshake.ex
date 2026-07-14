defmodule Aiur.Codex.Handshake do
  @moduledoc """
  Codex initialize, thread establishment, and first-turn sequencing.
  """

  require Logger

  alias Aiur.AppServer.Messages
  alias Aiur.Codex.{Frames, Rpc}
  alias Aiur.Perf

  @account_read_timeout_ms 1_000
  @rate_limits_read_timeout_ms 1_000

  @spec establish(port(), Path.t(), map(), String.t() | nil, keyword()) ::
          {:ok, String.t(), boolean()} | {:error, term()}
  def establish(port, workspace, session_policies, resume_thread_id, opts \\ []) do
    case send_initialize(port, opts) do
      :ok -> start_or_resume_thread(port, workspace, session_policies, resume_thread_id, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec establish_with_rate_limits(
          port(),
          Path.t(),
          map(),
          String.t() | nil,
          keyword()
        ) ::
          {:ok, String.t(), boolean(), boolean()} | {:error, term()}
  def establish_with_rate_limits(port, workspace, session_policies, resume_thread_id, opts \\ []) do
    with {:ok, initialize_response} <- initialize(port, opts),
         {:ok, thread_id, resumed?} <- start_or_resume_thread(port, workspace, session_policies, resume_thread_id, opts) do
      {:ok, thread_id, resumed?, supports_rate_limits?(initialize_response)}
    end
  end

  @spec start_or_resume_thread(port(), Path.t(), map(), nil | String.t(), keyword()) ::
          {:ok, String.t(), boolean()} | {:error, term()}
  def start_or_resume_thread(port, workspace, session_policies, resume_thread_id, opts \\ [])

  def start_or_resume_thread(port, workspace, session_policies, nil, opts) do
    with {:ok, thread_id} <- start_thread(port, workspace, session_policies, opts) do
      {:ok, thread_id, false}
    end
  end

  def start_or_resume_thread(port, workspace, session_policies, resume_thread_id, opts)
      when is_binary(resume_thread_id) do
    case resume_outcome(resume_thread(port, workspace, session_policies, resume_thread_id, opts), resume_thread_id) do
      {:resumed, thread_id} ->
        Logger.info("Codex resumed prior thread thread_id=#{thread_id} (no cold start)")
        {:ok, thread_id, true}

      {:fresh, thread_id} ->
        # codex handed back a thread other than the one we asked to resume, so
        # we did NOT actually rejoin the prior conversation. Report resumed?
        # false so the first turn replays the full cold-start prompt instead of
        # a context-free continuation prompt against an unfamiliar thread.
        Logger.warning("Codex thread/resume returned a different thread_id (requested=#{resume_thread_id} got=#{thread_id}); treating as a clean start")
        {:ok, thread_id, false}

      {:fallback, reason} ->
        Logger.warning("Codex thread/resume failed for thread_id=#{resume_thread_id} (#{inspect(reason)}); falling back to a clean thread/start")
        Perf.event(:codex_resume_fallback, thread_id: resume_thread_id, reason: inspect(reason))

        with {:ok, thread_id} <- start_thread(port, workspace, session_policies, opts) do
          {:ok, thread_id, false}
        end
    end
  end

  @doc false
  @spec resume_outcome({:ok, String.t()} | {:error, term()}, String.t()) ::
          {:resumed, String.t()} | {:fresh, String.t()} | {:fallback, term()}
  def resume_outcome({:ok, resume_thread_id}, resume_thread_id), do: {:resumed, resume_thread_id}
  def resume_outcome({:ok, other_thread_id}, _resume_thread_id), do: {:fresh, other_thread_id}
  def resume_outcome({:error, reason}, _resume_thread_id), do: {:fallback, reason}

  @spec start_thread(port(), Path.t(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def start_thread(port, workspace, session_policies, opts \\ []) do
    send_thread_init(port, Frames.thread_init_frame(nil, workspace, session_policies), opts)
  end

  @spec resume_thread(port(), Path.t(), map(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def resume_thread(port, workspace, session_policies, resume_thread_id, opts \\ []) do
    send_thread_init(port, Frames.thread_init_frame(resume_thread_id, workspace, session_policies), opts)
  end

  @spec send_thread_init(port(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def send_thread_init(port, frame, opts \\ []) do
    Rpc.send_message(port, frame)
    parse_thread_response(Rpc.await_startup_response(port, Frames.thread_start_id(), opts))
  rescue
    ArgumentError -> {:error, :port_closed}
  end

  @spec parse_thread_response({:ok, map()} | {:error, term()}) :: {:ok, String.t()} | {:error, term()}
  def parse_thread_response({:ok, %{"thread" => %{"id" => thread_id}}}), do: {:ok, thread_id}
  def parse_thread_response({:ok, %{"thread" => thread_payload}}), do: {:error, {:invalid_thread_payload, thread_payload}}
  def parse_thread_response(other), do: other

  @spec send_initialize(port(), keyword()) :: :ok | {:error, term()}
  def send_initialize(port, opts \\ []) do
    case initialize(port, opts) do
      {:ok, _response} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp initialize(port, opts) do
    Rpc.send_message(port, Messages.initialize_frame())

    with {:ok, response} <- Rpc.await_startup_response(port, Messages.initialize_id(), opts) do
      Rpc.send_message(port, Messages.initialized_frame())
      {:ok, response}
    end
  rescue
    # The agent process can exit at any point (e.g. it crashed on boot);
    # Port.command/2 then raises ArgumentError on the closed port. Surface it as
    # a handled {:error, :port_closed} — `do_start_session/1` already routes that
    # — instead of crashing the run. Mirrors send_operator_message/interrupt_turn.
    ArgumentError -> {:error, :port_closed}
  end

  # `codexHome` is required by Codex's real initialize response. Small fake
  # app-server fixtures and older wrappers omit it, so avoid sending them a
  # request they cannot consume without changing their startup protocol.
  defp supports_rate_limits?(%{"codexHome" => home}) when is_binary(home), do: true
  defp supports_rate_limits?(_response), do: false

  @doc "Read the authenticated Codex account's current rate-limit windows."
  @spec read_rate_limits(port(), keyword()) :: {:ok, map()} | {:error, term()}
  def read_rate_limits(port, opts \\ []) do
    Rpc.send_message(port, Frames.rate_limits_read_frame())

    case Rpc.await_response(port, Frames.rate_limits_read_id(), @rate_limits_read_timeout_ms, opts) do
      {:ok, %{"rateLimits" => rate_limits}} when is_map(rate_limits) -> {:ok, rate_limits}
      {:ok, payload} -> {:error, {:invalid_rate_limits_payload, payload}}
      {:error, _reason} = error -> error
    end
  rescue
    ArgumentError -> {:error, :port_closed}
  end

  @doc "Read a privacy-reduced account binding seed from the trusted app-server."
  @spec read_account(port(), keyword()) :: {:ok, map()} | {:error, term()}
  def read_account(port, opts \\ []) do
    Rpc.send_message(port, Frames.account_read_frame())
    Rpc.await_response(port, Frames.account_read_id(), @account_read_timeout_ms, opts)
  rescue
    ArgumentError -> {:error, :port_closed}
  end

  @spec start_turn(map(), String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def start_turn(
        %{
          port: port,
          thread_id: thread_id,
          workspace: workspace,
          approval_policy: approval_policy,
          turn_sandbox_policy: turn_sandbox_policy
        } = session,
        prompt,
        issue
      ) do
    frame = Frames.turn_start_frame(thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy)
    Rpc.send_message(port, frame)

    case Rpc.await_startup_response(port, Frames.turn_start_id(), on_notification: Map.get(session, :account_generation_notification_handler, fn _payload -> :ignore end)) do
      {:ok, %{"turn" => %{"id" => turn_id}}} -> {:ok, turn_id}
      other -> other
    end
  end
end
