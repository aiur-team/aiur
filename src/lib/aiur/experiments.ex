defmodule Aiur.Experiments do
  @moduledoc "Versioned experiment specs and their durable audit trail."

  alias Aiur.Experiments.{Journal, Paths, Reader, Schema, Store}

  @spec child(boolean()) :: module() | nil
  def child(false), do: nil

  def child(true) do
    case Aiur.Config.settings() do
      {:ok, %{experiments: %{enabled: false}}} -> nil
      _settings -> Store
    end
  end

  @spec status() :: map()
  def status do
    store =
      cond do
        is_nil(Process.whereis(Store)) -> {:error, Store.startup_failure()}
        writable_directory?() -> :ok
        true -> {:error, :store_read_only}
      end

    %{available?: store == :ok, store: store, capture: if(Aiur.Config.telemetry_enabled?(), do: :on, else: :off)}
  end

  defp writable_directory? do
    case File.stat(Paths.root()) do
      {:ok, %{access: access}} -> access in [:write, :read_write]
      {:error, _reason} -> false
    end
  end

  @spec list(keyword() | map()) :: {:ok, [map()]} | {:error, term()}
  def list(filters \\ []) do
    with {:ok, rows} <- Reader.summaries() do
      if invalid_index?() and Process.whereis(Store), do: GenServer.cast(Store, :rebuild_index)
      {:ok, Enum.filter(rows, fn row -> Enum.all?(filters, fn {key, value} -> is_nil(value) or Map.get(row, key) == value end) end)}
    end
  end

  defp invalid_index? do
    case Reader.json(Path.join(Paths.root(), "index.json")) do
      {:ok, %{"experiments" => rows} = index} when is_list(rows) -> not match?({:ok, _index}, Schema.migrate(index))
      _invalid -> true
    end
  end

  @spec fetch(String.t()) :: {:ok, map()} | {:error, term()}
  def fetch(id), do: Reader.fetch(id)

  @spec create(map(), keyword()) :: {:ok, Aiur.Experiments.Spec.t()} | {:error, term()}
  def create(attrs, opts \\ []), do: mutate({:create, attrs, opts})

  @spec amend(String.t(), map(), term()) :: {:ok, Aiur.Experiments.Spec.t()} | {:error, term()}
  def amend(id, changes, actor), do: mutate({:amend, id, changes, actor, "amended"})

  @spec set_status(String.t(), atom() | String.t(), String.t(), term()) :: {:ok, Aiur.Experiments.Spec.t()} | {:error, term()}
  def set_status(id, status, reason, actor), do: mutate({:amend, id, %{status: to_string(status)}, actor, {"status", reason}})

  @spec annotate(String.t(), map(), term()) :: :ok | {:error, term()}
  def annotate(id, annotation, actor), do: mutate({:annotate, id, annotation, actor})

  @spec journal(String.t()) :: [map()] | {:error, term()}
  def journal(id) do
    if Paths.valid_id?(id) do
      case Journal.read(Paths.file(id, "journal.ndjson")) do
        {:ok, entries} -> entries
        error -> error
      end
    else
      {:error, :not_found}
    end
  end

  @spec report_dir(String.t()) :: Path.t()
  def report_dir(id), do: Paths.file(id, "report")

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Aiur.PubSub, "experiments")

  defp mutate(command) do
    GenServer.call(Store, command, 30_000)
  catch
    :exit, {:noproc, _call} -> {:error, :disabled}
    :exit, {:timeout, _call} -> {:error, :outcome_unknown}
  end
end
