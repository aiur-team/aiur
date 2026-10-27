defmodule VoiceConverse.SessionSupervisor do
  @moduledoc false

  use DynamicSupervisor

  alias VoiceConverse.{Config, Session}

  @spec start_link(Config.t()) :: Supervisor.on_start()
  def start_link(%Config{name: instance} = config) do
    DynamicSupervisor.start_link(__MODULE__, config, name: name(instance))
  end

  @spec name(module()) :: module()
  def name(instance), do: Module.concat(instance, SessionSupervisor)

  @spec start_session(module(), term(), keyword()) :: {:ok, String.t()} | {:error, atom()}
  def start_session(instance, target, opts) do
    :global.trans({__MODULE__, instance}, fn -> start_session_locked(instance, target, opts) end)
  end

  defp start_session_locked(instance, target, opts) do
    config = :persistent_term.get({__MODULE__, instance}, :missing)

    cond do
      config == :missing or is_nil(Process.whereis(name(instance))) ->
        {:error, :not_installed}

      count(instance) >= config.limits.max_sessions ->
        {:error, :session_limit}

      true ->
        start_child(instance, config, target, opts)
    end
  end

  @impl true
  def init(%Config{name: instance} = config) do
    :persistent_term.put({__MODULE__, instance}, config)
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  defp count(instance) do
    instance
    |> name()
    |> DynamicSupervisor.count_children()
    |> Map.fetch!(:active)
  end

  defp start_child(instance, config, target, opts) do
    conversation_id = "vc_" <> (:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false))
    child = {Session, [instance: instance, config: config, target: target, conversation_id: conversation_id] ++ opts}

    case DynamicSupervisor.start_child(name(instance), child) do
      {:ok, pid} -> await_started(pid, conversation_id)
      {:error, {:session_start_failed, code}} -> {:error, code}
      {:error, _reason} -> {:error, :unknown}
    end
  end

  defp await_started(pid, conversation_id) do
    case GenServer.call(pid, :await_started, 5_000) do
      :ok -> {:ok, conversation_id}
      {:error, code} -> {:error, code}
      _ -> {:error, :unknown}
    end
  catch
    :exit, {:session_start_failed, code} -> {:error, code}
    :exit, {{:session_start_failed, code}, _} -> {:error, code}
    :exit, _reason -> {:error, :unknown}
  end
end
