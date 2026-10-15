defmodule Aiur.Experiments.Auto.Creator do
  @moduledoc false
  use GenServer
  require Logger
  alias Aiur.Config.Schema.Experiments.Auto, as: AutoConfig
  alias Aiur.Experiments
  alias Aiur.Experiments.Auto.{ConcurrentChanges, Line, LineMerge, SpecBuilder}
  alias Aiur.Experiments.{Catalog, Paths}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec create(Line.t(), GenServer.server()) :: {:ok, term()} | {:error, term()}
  def create(line, server \\ __MODULE__), do: GenServer.call(server, {:create, line}, 180_000)

  @spec rollback(String.t(), DateTime.t(), GenServer.server()) :: :ok | {:error, term()}
  def rollback(version, at, server \\ __MODULE__), do: GenServer.call(server, {:rollback, version, at}, 180_000)

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, Path.join(Paths.root(), "auto-creator.json"))

    with {:ok, receipts} <- Aiur.JsonStore.read(path, %{"completed" => [], "skipped" => []}),
         true <- valid_receipts?(receipts) do
      {:ok,
       %{
         path: path,
         receipts: receipts,
         catalog_context: Keyword.get(opts, :catalog_context, %{}),
         config: Keyword.get(opts, :config),
         telemetry: Keyword.get(opts, :telemetry, &Aiur.Config.telemetry_enabled?/0)
       }}
    else
      false -> {:stop, :invalid_auto_receipts}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:create, %Line{key: key} = line}, _from, state) when is_binary(key) do
    {result, state} = create_line(line, state)
    {:reply, result, state}
  end

  def handle_call({:create, _invalid}, _from, state), do: {:reply, {:error, :invalid_line}, state}

  def handle_call({:rollback, version, at}, _from, state), do: {:reply, LineMerge.rollback(version, at), state}

  defp create_line(line, state) do
    cond do
      not state.telemetry.() -> skip(line, state)
      line.key in state.receipts["completed"] -> {{:ok, :exists}, state}
      line.key in state.receipts["skipped"] -> {{:ok, :skipped}, state}
      true -> initialize(line, state)
    end
  end

  defp initialize(line, state) do
    config = state.config || settings()

    # X2 create commits the frozen baseline before returning; freezing again adds an unwanted revision.
    with {:ok, attrs} <- SpecBuilder.build(line, config, Catalog.load(state.catalog_context)),
         {:ok, experiment} <- merge_or_create(line, attrs, config),
         :ok <- ensure_baseline(experiment.id),
         :ok <- LineMerge.supersede(experiment.id, line),
         :ok <- ConcurrentChanges.annotate(experiment.id, line),
         {:ok, updated} <- remember(state, "completed", line.key) do
      {{:ok, experiment}, updated}
    else
      error -> {error, state}
    end
  end

  defp merge_or_create(line, attrs, config) do
    with {:ok, target} <- LineMerge.target(line, config) do
      case target do
        nil -> Experiments.create(attrs, actor: "auto")
        id -> LineMerge.attach(id, line)
      end
    end
  end

  defp ensure_baseline(id) do
    with {:ok, detail} <- Experiments.fetch(id) do
      if Enum.any?(detail.snapshots, &(&1["window_name"] == "before")) do
        :ok
      else
        freeze_baseline(id)
      end
    end
  end

  defp freeze_baseline(id) do
    case Experiments.freeze(id, "before") do
      {:ok, _snapshot} -> :ok
      error -> error
    end
  end

  defp skip(line, state) do
    if line.key in state.receipts["skipped"] do
      {{:ok, :skipped}, state}
    else
      case remember(state, "skipped", line.key) do
        {:ok, updated} ->
          Logger.info("automatic experiment skipped: telemetry disabled key=#{line.key}")
          {{:ok, :skipped}, updated}

        error ->
          {error, state}
      end
    end
  end

  defp remember(state, category, key) do
    receipts = Map.update!(state.receipts, category, &[key | &1])

    with :ok <- Aiur.Journal.ensure_directory(Path.dirname(state.path)),
         :ok <- Aiur.Fs.atomic_write(state.path, Jason.encode!(receipts), fsync: true, mode: 0o600) do
      {:ok, %{state | receipts: receipts}}
    end
  end

  defp valid_receipts?(%{"completed" => completed, "skipped" => skipped}) do
    is_list(completed) and is_list(skipped) and Enum.all?(completed ++ skipped, &is_binary/1)
  end

  defp valid_receipts?(_invalid), do: false

  defp settings do
    case Aiur.Config.settings() do
      {:ok, %{experiments: %{auto: auto}}} -> auto
      _unconfigured -> %AutoConfig{}
    end
  end
end
