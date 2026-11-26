defmodule Aiur.Experiments do
  @moduledoc "Versioned experiment specs and their durable audit trail."

  alias Aiur.Experiments.{AnalysisRequests, Analyst}
  alias Aiur.Experiments.{Arms, Capture, Catalog, ChartData, ChartEvidence, Checkpointer, Evaluator, Journal, Paths, Reader, ReportMarkdown, ReportReads, SampleStatus, Schema, Store, WindowEvents}

  @spec metric_catalog() :: map()
  def metric_catalog, do: Catalog.load()

  @spec observations([String.t()], map(), map()) :: map()
  def observations(refs, window, context \\ %{}), do: Evaluator.observations(refs, window, context)

  @spec children(boolean()) :: [module()]
  def children(recording?), do: if(child(recording?), do: [Store, Capture, Checkpointer, Aiur.Experiments.StatsRunner], else: [])

  @spec window_children(boolean()) :: [module()]
  def window_children(recording?),
    do: if(child(recording?), do: [Aiur.Experiments.Auto.Notifier, Aiur.Experiments.Auto.WindowManager, Aiur.Experiments.Analyst, Aiur.Experiments.AnalystTrigger], else: [])

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
      filters = Map.new(filters)
      rows = if is_nil(filters[:status]), do: Enum.reject(rows, &(Map.get(&1, :status) == "abandoned")), else: rows
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
  def fetch(id), do: ReportReads.detail(id, Reader.fetch(id))

  @spec chart_detail(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def chart_detail(id, opts \\ []) do
    with {:ok, detail} <- fetch(id) do
      detail = ChartEvidence.attach(id, detail)
      ChartData.attach({:ok, detail}, opts)
    end
  end

  @spec events(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def events(id, opts \\ []) do
    task = Task.Supervisor.async_nolink(Aiur.TaskSupervisor, fn -> prepare_events(id, opts) end)
    result = Task.yield(task, Keyword.get(opts, :timeout_ms, 120_000)) || Task.shutdown(task, :brutal_kill)
    finish_events(result, id, opts)
  catch
    :exit, _reason -> {:error, :events_collection_unavailable}
  end

  defp prepare_events(id, opts) do
    with {:ok, spec, read_only?} <- Reader.spec(id) do
      cached_events(WindowEvents.snapshot(spec), spec, read_only?, opts)
    end
  end

  defp cached_events({:ok, snapshot}, spec, read_only?, opts) do
    if opts[:refresh], do: collect_events(spec, read_only?, opts), else: {:cached, snapshot}
  end

  defp cached_events({:error, :not_found}, spec, read_only?, opts), do: collect_events(spec, read_only?, opts)
  defp cached_events(error, _spec, _read_only?, _opts), do: error
  defp collect_events(_spec, true, _opts), do: {:error, :store_read_only}
  defp collect_events(spec, false, opts), do: {:collected, WindowEvents.collect(spec, opts)}

  defp finish_events({:ok, {:cached, snapshot}}, _id, _opts), do: {:ok, snapshot}
  defp finish_events({:ok, {:collected, snapshot}}, id, opts), do: mutate({:events_snapshot, id, snapshot, Keyword.get(opts, :refresh, false)})
  defp finish_events({:ok, {:error, _reason} = error}, _id, _opts), do: error
  defp finish_events(nil, _id, _opts), do: {:error, :events_collection_timeout}
  defp finish_events({:exit, _reason}, _id, _opts), do: {:error, :events_collection_failed}

  @spec create(map(), keyword()) :: {:ok, Aiur.Experiments.Spec.t()} | {:error, term()}
  def create(attrs, opts \\ []), do: mutate({:create, attrs, opts})

  @spec request_analysis(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def request_analysis(id, mode, opts \\ []), do: mutate({:analysis_request, id, mode, opts})

  @spec analyze(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def analyze(id, opts \\ []), do: Analyst.analyze(id, opts)

  @doc false
  @spec reconcile_analysis_requests(String.t()) :: :ok | {:error, term()}
  def reconcile_analysis_requests(id), do: mutate({:reconcile_analysis, id})

  @doc false
  @spec update_analysis_dispatch(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_analysis_dispatch(id, request_id, fields), do: mutate({:analysis_request_update, :dispatch, id, request_id, fields})

  @spec analysis_requests(String.t()) :: {:ok, [map()]} | {:error, term()}
  def analysis_requests(id) do
    with {:ok, _spec, _read_only?} <- Reader.spec(id), {:ok, rows} <- AnalysisRequests.history(id), do: {:ok, AnalysisRequests.latest(rows)}
  end

  @spec attach_analysis_ticket(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def attach_analysis_ticket(id, request_id, ticket), do: mutate({:analysis_request_update, :attach_ticket, id, request_id, ticket})

  @spec fulfill_analysis_request(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def fulfill_analysis_request(id, request_id, submission), do: mutate({:analysis_request_update, :fulfill, id, request_id, submission})

  @spec fail_analysis_request(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def fail_analysis_request(id, request_id, reason), do: mutate({:fail_analysis_request, id, request_id, reason})

  @spec cancel_analysis_request(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def cancel_analysis_request(id, request_id, reason), do: mutate({:analysis_request_update, :cancel, id, request_id, reason})

  @spec freeze(String.t(), String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def freeze(id, window \\ nil, opts \\ []) do
    if Paths.valid_id?(id), do: ReportReads.snapshot(id, mutate({:freeze, id, window, opts})), else: {:error, :not_found}
  end

  @spec arms(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def arms(id, opts \\ []), do: ReportReads.arms(id, Arms.read(id, opts))

  @spec export_analysis_input(String.t()) :: {:ok, map()} | {:error, term()}
  def export_analysis_input(id) do
    if Paths.valid_id?(id), do: ReportReads.input(id, mutate({:export_analysis_input, id})), else: {:error, :not_found}
  end

  @doc "Completed-unit minimum-sample guards for pre-registered primary metrics."
  @spec sample_status(map()) :: {:ok, [map()]} | {:error, term()}
  def sample_status(spec), do: SampleStatus.read(spec)

  @spec checkpoint(String.t(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def checkpoint(id, now), do: mutate({:checkpoint, id, now})

  @doc false
  @spec manage_window(String.t(), term(), map(), DateTime.t(), term()) :: term()
  def manage_window(id, samples, config, now, truncation \\ nil), do: mutate({:manage_window, id, samples, config, now, truncation})

  @doc false
  @spec window_spec(String.t()) :: {:ok, map(), boolean()} | {:error, term()}
  def window_spec(id), do: mutate({:window_spec, id})

  @spec amend(String.t(), map(), term()) :: {:ok, Aiur.Experiments.Spec.t()} | {:error, term()}
  def amend(id, changes, actor), do: mutate({:amend, id, changes, actor, "amended"})

  @spec set_status(String.t(), atom() | String.t(), String.t(), term()) :: {:ok, Aiur.Experiments.Spec.t()} | {:error, term()}
  def set_status(id, status, reason, actor), do: mutate({:amend, id, %{status: to_string(status)}, actor, {"status", reason}})

  @spec abandon(String.t(), String.t(), term()) :: {:ok, Aiur.Experiments.Spec.t()} | {:error, term()}
  def abandon(id, reason, actor), do: mutate({:abandon, id, reason, actor})

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

  @spec stats(String.t()) :: {:ok, map()} | {:error, term()}
  def stats(id), do: mutate({:stats, id})

  @spec put_report(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def put_report(id, report), do: mutate({:put_report, id, report})

  @spec report_markdown(map()) :: String.t()
  def report_markdown(report), do: ReportMarkdown.render(report)

  @spec put_preregistration(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def put_preregistration(id, attrs), do: mutate({:put_preregistration, id, attrs})

  @spec record_results_read(String.t()) :: :ok | {:error, term()}
  def record_results_read(id), do: mutate({:record_results_read, id})

  @spec report_dir(String.t()) :: Path.t()
  def report_dir(id), do: Paths.file(id, "report")

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Aiur.PubSub, "experiments")

  defp mutate(command) do
    GenServer.call(Store, command, 125_000)
  catch
    :exit, {:noproc, _call} -> {:error, Store.startup_failure()}
    :exit, {:timeout, _call} -> {:error, :outcome_unknown}
  end
end
