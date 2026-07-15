defmodule Aiur.Codex.SessionLifecycle do
  @moduledoc false

  require Logger

  alias Aiur.AppServer.{Messages, Rpc}
  alias Aiur.Codex.{AccountGeneration, AppServerPort, Handshake, TurnEvents}
  alias Aiur.{ModelAvailability, PauseContainment}

  @spec observe_startup(port(), boolean(), map(), keyword()) :: :ok
  def observe_startup(port, true, session, handshake_opts) do
    observe_rate_limits(port, handshake_opts)
    seed_account(port, session, handshake_opts)
  end

  def observe_startup(_port, false, _session, _handshake_opts), do: :ok

  @spec notification_handler(map(), (map() -> term())) :: (map() -> :handled | :ignore)
  def notification_handler(session, on_message) do
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

  @spec register_pause_containment(String.t() | nil, map(), Path.t()) :: term() | nil
  def register_pause_containment(identifier, metadata, workspace) when is_binary(identifier) do
    with pid when is_binary(pid) <- metadata[:codex_app_server_pid],
         group when is_binary(group) <- metadata[:agent_process_group_id],
         {root_pid, ""} <- Integer.parse(pid),
         {process_group_id, ""} <- Integer.parse(group),
         {:ok, handle} <- PauseContainment.register(identifier, root_pid, process_group_id, workspace: workspace) do
      handle
    else
      _ -> nil
    end
  end

  def register_pause_containment(_identifier, _metadata, _workspace), do: nil

  @spec cleanup_port(port(), term() | nil) :: :ok
  def cleanup_port(port, containment) do
    AppServerPort.stop_port(port)
  after
    Rpc.clear_late_sensitive_responses(port)
    PauseContainment.unregister(containment)
  end

  defp observe_rate_limits(port, handshake_opts) do
    case Handshake.read_rate_limits(port, handshake_opts) do
      {:ok, rate_limits} -> ModelAvailability.observe("codex", rate_limits)
      {:error, _reason} -> Logger.debug("Codex account/rateLimits/read unavailable")
    end
  end

  defp seed_account(port, session, handshake_opts) do
    case Handshake.read_account(port, handshake_opts) do
      {:ok, account_response} -> AccountGeneration.seed_from_account_read(session, account_response)
      {:error, _reason} -> Logger.debug("Codex account/read unavailable")
    end
  end
end
