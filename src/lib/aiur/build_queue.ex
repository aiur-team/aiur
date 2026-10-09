defmodule Aiur.BuildQueue do
  @moduledoc "Supervised build queue reconciliation and read-only planned actions."

  alias Aiur.BuildQueue.{ReadModel, Server}

  @type status :: :running | :disabled | :unsupported_tracker | :store_unavailable | :writes_paused

  @spec child(boolean()) :: module() | nil
  def child(false), do: nil
  def child(true), do: if(availability() == :running, do: Server)

  @spec status() :: status()
  def status do
    if Process.whereis(Server), do: GenServer.call(Server, :status), else: absent_status()
  end

  @doc "Returns the version 1 public read model from held projections; no upstream requests or label writes."
  @spec show(GenServer.server()) :: map()
  def show(server \\ Server) do
    GenServer.call(server, :read_model)
  catch
    :exit, {:noproc, _} -> ReadModel.unavailable(absent_status())
  end

  @spec reconcile_now() :: :ok | {:error, status()}
  def reconcile_now do
    GenServer.call(Server, :reconcile_now)
  catch
    :exit, {:noproc, _} -> {:error, :disabled}
  end

  @doc "Rebuilds a missing or corrupt store as an operator-held list from queued markers."
  @spec recover() :: :ok | {:error, term()}
  def recover do
    GenServer.call(Server, :recover)
  catch
    :exit, {:noproc, _} -> {:error, :disabled}
  end

  @doc "Clears item holds and overrides, or releases all items and the hold in a queue by ID."
  @spec release(String.t(), GenServer.server()) :: :ok | {:error, term()}
  def release(target, server \\ Server) when is_binary(target) do
    GenServer.call(server, {:release, target})
  catch
    :exit, {:noproc, _} -> {:error, :disabled}
  end

  defp absent_status do
    case availability() do
      :running -> :disabled
      status -> status
    end
  end

  defp availability do
    with {:ok, settings} <- Aiur.Config.settings(),
         true <- settings.build_queue.enabled do
      if Aiur.Tracker.open_issue_labels(1) == {:error, :unsupported}, do: :unsupported_tracker, else: :running
    else
      _ -> :disabled
    end
  end
end
