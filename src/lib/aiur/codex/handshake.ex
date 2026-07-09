defmodule Aiur.Codex.Handshake do
  @moduledoc """
  Codex initialize, thread establishment, and first-turn sequencing.
  """

  require Logger

  alias Aiur.AppServer.Messages
  alias Aiur.Codex.{Frames, Rpc}
  alias Aiur.Perf

  @spec establish(port(), Path.t(), map(), String.t() | nil) ::
          {:ok, String.t(), boolean()} | {:error, term()}
  def establish(port, workspace, session_policies, resume_thread_id) do
    case send_initialize(port) do
      :ok -> start_or_resume_thread(port, workspace, session_policies, resume_thread_id)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec start_or_resume_thread(port(), Path.t(), map(), nil | String.t()) ::
          {:ok, String.t(), boolean()} | {:error, term()}
  def start_or_resume_thread(port, workspace, session_policies, nil) do
    with {:ok, thread_id} <- start_thread(port, workspace, session_policies) do
      {:ok, thread_id, false}
    end
  end

  def start_or_resume_thread(port, workspace, session_policies, resume_thread_id)
      when is_binary(resume_thread_id) do
    case resume_outcome(resume_thread(port, workspace, session_policies, resume_thread_id), resume_thread_id) do
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

        with {:ok, thread_id} <- start_thread(port, workspace, session_policies) do
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

  @spec start_thread(port(), Path.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def start_thread(port, workspace, session_policies) do
    send_thread_init(port, Frames.thread_init_frame(nil, workspace, session_policies))
  end

  @spec resume_thread(port(), Path.t(), map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def resume_thread(port, workspace, session_policies, resume_thread_id) do
    send_thread_init(port, Frames.thread_init_frame(resume_thread_id, workspace, session_policies))
  end

  @spec send_thread_init(port(), map()) :: {:ok, String.t()} | {:error, term()}
  def send_thread_init(port, frame) do
    Rpc.send_message(port, frame)
    parse_thread_response(Rpc.await_startup_response(port, Frames.thread_start_id()))
  rescue
    ArgumentError -> {:error, :port_closed}
  end

  @spec parse_thread_response({:ok, map()} | {:error, term()}) :: {:ok, String.t()} | {:error, term()}
  def parse_thread_response({:ok, %{"thread" => %{"id" => thread_id}}}), do: {:ok, thread_id}
  def parse_thread_response({:ok, %{"thread" => thread_payload}}), do: {:error, {:invalid_thread_payload, thread_payload}}
  def parse_thread_response(other), do: other

  @spec send_initialize(port()) :: :ok | {:error, term()}
  def send_initialize(port) do
    Rpc.send_message(port, Messages.initialize_frame())

    with {:ok, _} <- Rpc.await_startup_response(port, Messages.initialize_id()) do
      Rpc.send_message(port, Messages.initialized_frame())
      :ok
    end
  rescue
    # The agent process can exit at any point (e.g. it crashed on boot);
    # Port.command/2 then raises ArgumentError on the closed port. Surface it as
    # a handled {:error, :port_closed} — `do_start_session/1` already routes that
    # — instead of crashing the run. Mirrors send_operator_message/interrupt_turn.
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
        },
        prompt,
        issue
      ) do
    frame = Frames.turn_start_frame(thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy)
    Rpc.send_message(port, frame)

    case Rpc.await_startup_response(port, Frames.turn_start_id()) do
      {:ok, %{"turn" => %{"id" => turn_id}}} -> {:ok, turn_id}
      other -> other
    end
  end
end
