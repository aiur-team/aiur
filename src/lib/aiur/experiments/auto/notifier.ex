defmodule Aiur.Experiments.Auto.Notifier do
  @moduledoc false
  use GenServer
  require Logger
  alias Aiur.Events.Publisher
  alias Aiur.Experiments.Paths
  alias Aiur.JsonStore

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec notify(map(), String.t(), GenServer.server()) :: :ok | {:error, term()}
  def notify(spec, event, server \\ __MODULE__), do: GenServer.call(server, {:notify, spec, event})

  @spec status(GenServer.server()) :: :ok | :degraded
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, Path.join(Paths.root(), "auto-latches.json"))
    latches = load(path)
    {:ok, %{path: path, latches: latches, write: Keyword.get(opts, :write, &persist/2), publish: Keyword.get(opts, :publish, &publish/2)}}
  end

  defp load(path) do
    case JsonStore.read(path, %{}) do
      {:ok, latches} when is_map(latches) -> validate_latches(latches)
      error -> degraded(error)
    end
  end

  defp validate_latches(latches) do
    if Enum.all?(latches, fn {key, value} -> is_binary(key) and value == true end), do: latches, else: degraded(:invalid_latches)
  end

  defp degraded(reason) do
    Logger.error("experiment notifications degraded: #{inspect(reason)}")
    nil
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, if(is_nil(state.latches), do: :degraded, else: :ok), state}
  def handle_call({:notify, _spec, _event}, _from, %{latches: nil} = state), do: {:reply, {:error, :degraded}, state}

  def handle_call({:notify, spec, event}, _from, state) when event in ~w(preregister report_due cancelled) do
    key = Jason.encode!([spec["id"], event])
    if Map.has_key?(state.latches, key), do: {:reply, :ok, state}, else: announce(spec, event, key, state)
  end

  defp announce(spec, event, key, state) do
    latches = Map.put(state.latches, key, true)

    case state.write.(state.path, latches) do
      :ok ->
        payload = %{experiment_id: spec["id"], reason: spec["report_reason"], line_source: line_source(spec)}
        id = String.replace(spec["id"], ".", "%2E")
        result = state.publish.("system.experiment.#{id}.#{event}", payload)
        if result != :ok, do: Logger.error("experiment notification publication failed: #{inspect(result)}")
        {:reply, result, %{state | latches: latches}}

      {:error, reason} = error ->
        Logger.error("experiment notification latch write failed: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  defp line_source(spec) do
    case get_in(spec, ["design", "change", "evidence"]) do
      %{"source" => source} when source in ~w(aiur_version repo_release feature) -> source
      _manual -> "manual"
    end
  end

  defp persist(path, latches) do
    JsonStore.write!(path, latches)
  rescue
    error -> {:error, error}
  end

  defp publish(topic, payload) do
    case Publisher.publish(topic, Map.put(payload, :source, :system)) do
      {:ok, _id, _subscribers} -> :ok
      error -> {:error, error}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end
end
