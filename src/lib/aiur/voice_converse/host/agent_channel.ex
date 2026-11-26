defmodule Aiur.VoiceConverse.Host.AgentChannel do
  @moduledoc """
  Worker delivery through Listener. References are stable per target and client request;
  acceptance and delivery arrive asynchronously at the subscribing voice session.
  Subscribed sessions own the observer's lifetime. No draft or confirmation state lives here.
  """
  @behaviour VoiceConverse.Ports.AgentChannel
  alias Aiur.Listener.CapabilityProvider
  alias Aiur.VoiceConverse.Host.{DeliveryObserver, Worker}

  @impl true
  def capabilities(%Worker{}) do
    if available?(), do: %{fork: :none, ask: true, instruct: true}, else: %{fork: :none}
  end

  def capabilities(_target), do: %{fork: :none}

  @impl true
  def subscribe(%Worker{} = target, pid) when is_pid(pid) do
    if available?() do
      case observer(target, pid) do
        {:ok, observer} ->
          GenServer.cast(observer, {:subscribe, pid})
          :ok

        _ ->
          :unsupported
      end
    else
      :unsupported
    end
  end

  def subscribe(:executor, _pid), do: :not_applicable
  def subscribe(_target, _pid), do: :unsupported

  @impl true
  def instruct(target, text, key, opts), do: enqueue(target, text, key, :instruct, opts)

  @impl true
  def ask(target, text, key, opts), do: enqueue(target, text, key, :ask, opts)

  @impl true
  def fork_query(_target, _text, _opts), do: {:error, :unsupported}

  defp enqueue(%Worker{} = target, text, key, kind, _opts) do
    if available?() do
      ref = {:voice_delivery, target.identity, key}

      with {:ok, observer} <- delivery_observer(target, kind) do
        GenServer.cast(observer, {:send, ref, text, key, kind})
        {:ok, ref}
      end
    else
      {:error, :unsupported}
    end
  end

  defp enqueue(_target, _text, _key, _kind, _opts), do: {:error, :unsupported}

  defp delivery_observer(target, :instruct) do
    with {:ok, pid} <- observer(target, self()) do
      GenServer.cast(pid, {:subscribe, self()})
      {:ok, pid}
    end
  end

  defp delivery_observer(target, :ask) do
    case Registry.lookup(__MODULE__.Registry, target) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :unsupported}
    end
  end

  defp observer(target, subscriber) do
    name = {:via, Registry, {__MODULE__.Registry, target}}

    case GenServer.start(DeliveryObserver, {target, subscriber, options()}, name: name) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp options, do: Application.get_env(:aiur, __MODULE__, [])

  defp available? do
    listener = Keyword.get(options(), :listener, Aiur.Listener)
    status = Keyword.get(options(), :available, &listener_available?/0)
    Code.ensure_loaded?(listener) and function_exported?(listener, :send, 3) and status.()
  end

  defp listener_available? do
    CapabilityProvider.capabilities(%{run_shape: %{}, settings: :unavailable})["listener_modes"].state == :available
  end
end
