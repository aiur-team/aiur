defmodule Aiur.Experiments.Store do
  @moduledoc false
  use GenServer
  require Logger

  alias Aiur.Experiments.{
    AnalysisInput,
    Catalog,
    Checkpoint,
    Evaluation,
    Journal,
    Paths,
    Persistence,
    Reader,
    Registration,
    ReportAnalysis,
    ReportRecords,
    ReportSubmission,
    Schema,
    Snapshot,
    SnapshotPersistence,
    Spec,
    WindowData,
    WindowEvents
  }

  alias Aiur.Experiments.Auto.WindowTransition

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec startup_failure() :: term()
  def startup_failure, do: :persistent_term.get({__MODULE__, :startup_failure}, :disabled)

  @impl true
  def init(opts) do
    :persistent_term.erase({__MODULE__, :startup_failure})

    with :ok <- Aiur.Journal.ensure_directory(Paths.root()), :ok <- Persistence.recover() do
      {:ok,
       %{
         evaluation: nil,
         evaluation_timeout_ms: Keyword.get(opts, :evaluation_timeout_ms, 120_000),
         append: Keyword.get(opts, :journal_writer, &Journal.append/2),
         catalog_context: Keyword.get(opts, :catalog_context, %{}),
         defaults: Map.new(Keyword.get(opts, :defaults, config_defaults())) |> Map.put_new(:repo_slug, Paths.repo())
       }}
    else
      {:error, reason} ->
        :persistent_term.put({__MODULE__, :startup_failure}, reason)
        Logger.warning("experiment writer unavailable: #{inspect(reason)}")
        :ignore
    end
  end

  @impl true
  def handle_call({:create, attrs, opts}, from, state) do
    case create(attrs, opts, state) do
      {:new, spec} -> Evaluation.start(state, from, fn -> prepare_create(spec, opts, state.catalog_context) end, &commit_create(&1, opts, state))
      result -> {:reply, result, state}
    end
  end

  def handle_call({:amend, id, changes, actor, kind}, _from, state) do
    result = amend(id, changes, actor, kind, state)
    {:reply, result, state}
  end

  def handle_call({:annotate, id, annotation, actor}, _from, state) do
    {:reply, annotate(id, annotation, actor), state}
  end

  def handle_call({:manage_window, id, samples, config, now, truncation}, _from, state) do
    result =
      case WindowTransition.prepare(id, samples, config, now, truncation) do
        {:ok, changes, kind} -> amend(id, changes, "window_manager", kind, state)
        result -> result
      end

    {:reply, result, state}
  end

  def handle_call({:window_spec, id}, _from, state), do: {:reply, Reader.spec(id), state}

  def handle_call({:stats, id}, from, state) do
    Evaluation.start(state, from, fn -> ReportAnalysis.prepare(id, state.catalog_context) end, fn result -> commit_result(result, &ReportAnalysis.commit/1) end)
  end

  def handle_call({:put_report, id, report}, from, state) do
    Evaluation.start(state, from, fn -> ReportSubmission.prepare(id, report, state.catalog_context) end, fn result -> commit_result(result, &ReportSubmission.commit/1) end)
  end

  def handle_call({:put_preregistration, id, attrs}, _from, state) do
    {:reply, ReportRecords.preregister(id, attrs, DateTime.utc_now()), state}
  end

  def handle_call({:record_results_read, id}, _from, state) do
    {:reply, ReportRecords.record_results_read(id, DateTime.utc_now()), state}
  end

  def handle_call({:events_snapshot, id, snapshot, refresh?}, _from, state) do
    {:reply, WindowEvents.freeze(id, snapshot, refresh?), state}
  end

  def handle_call({:freeze, id, window, opts}, from, state) do
    opts = Keyword.put_new(opts, :context, state.catalog_context)

    case Persistence.recover_one(id) do
      :ok -> Evaluation.start(state, from, fn -> Snapshot.prepare(id, window, opts) end, fn result -> commit_result(result, &Snapshot.commit_prepared/1) end)
      error -> {:reply, error, state}
    end
  end

  def handle_call({:export_analysis_input, id}, from, state) do
    Evaluation.start(state, from, fn -> AnalysisInput.prepare(id, context: state.catalog_context) end, fn result -> commit_result(result, &AnalysisInput.commit/1) end)
  end

  def handle_call({:checkpoint, id, now}, from, state) do
    Evaluation.start(state, from, fn -> Checkpoint.prepare(id, now, state.catalog_context) end, fn prepared ->
      result = commit_result(prepared, &Checkpoint.commit/1)
      Checkpoint.error_record(id, now, result)
      result
    end)
  end

  @impl true
  def handle_info(message, state), do: Evaluation.handle(message, state)

  @impl true
  def terminate(_reason, state), do: Evaluation.stop(state)

  defp commit_result({:ok, prepared}, commit), do: commit.(prepared)
  defp commit_result(error, _commit), do: error

  @impl true
  def handle_cast(:rebuild_index, state) do
    case Persistence.index() do
      :ok -> Persistence.broadcast(:all)
      {:error, reason} -> Logger.warning("experiment index rebuild failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  defp create(attrs, opts, state) do
    attrs = stringify(attrs) |> with_origin(opts)

    with :ok <- Persistence.recover(),
         {:ok, spec} <- Spec.new(attrs, state.defaults),
         :ok <- Catalog.validate_refs(spec.metrics, state.catalog_context) do
      case existing(spec.key) do
        {:error, _reason} = error -> error
        {:ok, nil} -> create_new(spec)
        {:ok, id} -> existing_spec(id)
      end
    end
  end

  defp existing_spec(id) do
    with :ok <- Persistence.recover_one(id), {:ok, old, _read_only?} <- Reader.spec(id), {:ok, old} <- Spec.new(old) do
      {:ok, %{old | existing: true}}
    end
  end

  defp create_new(spec) do
    spec = Registration.mark(spec)
    id = spec.id || next_id(spec.title)

    cond do
      not Paths.valid_id?(id) -> {:error, [%{path: "id", message: "invalid experiment id"}]}
      File.exists?(Paths.experiment(id)) -> {:error, :id_exists}
      true -> {:new, %{spec | id: id}}
    end
  end

  defp prepare_create(spec, opts, context) do
    if spec.design["kind"] == "before_after" and Keyword.get(opts, :freeze, true) do
      raw = Spec.to_map(spec)

      with {:ok, data} <- WindowData.evaluate(raw, "before", context),
           {:ok, snapshot} <- Snapshot.prepare_spec(raw, "before", nil, data, context: context) do
        {:ok, {spec, snapshot}}
      end
    else
      {:ok, {spec, nil}}
    end
  end

  defp commit_create({:ok, {spec, snapshot}}, opts, state) do
    entry = entry("created", Keyword.get(opts, :actor, "operator"), spec.updated_at, %{"origin" => Keyword.get(opts, :origin)})
    with :ok <- Persistence.commit(spec.id, Spec.to_map(spec), entry, state.append), do: commit_baseline(spec, snapshot)
  end

  defp commit_create(error, _opts, _state), do: error
  defp commit_baseline(spec, nil), do: {:ok, spec}

  defp commit_baseline(spec, snapshot) do
    case SnapshotPersistence.commit(spec.id, "before", snapshot, []) do
      :ok ->
        {:ok, spec}

      error ->
        File.rm_rf(Paths.experiment(spec.id))
        Persistence.index()
        error
    end
  end

  defp existing(nil), do: {:ok, nil}

  defp existing(key) do
    with {:ok, ids} <- Paths.ids() do
      {:ok,
       Enum.find(ids, fn id ->
         case Reader.spec(id) do
           {:ok, spec, _read_only?} -> spec["key"] == key
           _error -> false
         end
       end)}
    end
  end

  defp next_id(title) do
    slug = Aiur.Config.Paths.sanitize(title) |> String.downcase() |> String.slice(0, 60)
    base = Date.utc_today() |> Date.to_iso8601() |> Kernel.<>("-" <> slug)

    Stream.iterate(1, &(&1 + 1))
    |> Enum.find_value(fn n ->
      id = if n == 1, do: base, else: base <> "-" <> Integer.to_string(n)
      if not File.exists?(Paths.experiment(id)), do: id
    end)
  end

  defp amend(id, changes, actor, kind, state) do
    if Paths.valid_id?(id) do
      with :ok <- Persistence.writable(id),
           :ok <- Persistence.recover_one(id),
           {:ok, old, _read_only?} <- Reader.spec(id),
           {:ok, updated} <- changed_spec(old, changes, state.defaults),
           :ok <- validate_changed_metrics(old, updated, state.catalog_context),
           :ok <- status_transition(old["status"], updated.status) do
        persist_amendment(id, old, updated, actor, kind, state.append)
      end
    else
      {:error, :not_found}
    end
  end

  defp validate_changed_metrics(old, updated, context) do
    if old["metrics"] == updated.metrics, do: :ok, else: Catalog.validate_refs(updated.metrics, context)
  end

  defp persist_amendment(id, old, updated, actor, kind, append) do
    diff = Map.new(Spec.to_map(updated), fn {key, value} -> {key, %{"before" => old[key], "after" => value}} end) |> Map.reject(fn {_key, value} -> value["before"] == value["after"] end)
    {kind, reason} = if is_tuple(kind), do: kind, else: {kind, nil}
    entry = entry(kind, actor, updated.updated_at, %{"diff" => diff, "reason" => reason, "post_registration" => not is_nil(old["registered_at"])})
    with :ok <- Persistence.commit(id, Spec.to_map(updated), entry, append), do: {:ok, updated}
  end

  defp changed_spec(old, changes, defaults) do
    changes = stringify(changes)

    immutable = if old["registered_at"], do: ~w(id key schema_version created_at registered_at), else: ~w(id key schema_version created_at)

    if Enum.any?(immutable, &(Map.has_key?(changes, &1) and changes[&1] != old[&1])) do
      {:error, :immutable_field}
    else
      with {:ok, spec} <- old |> Map.merge(changes) |> Map.put("updated_at", DateTime.utc_now() |> DateTime.to_iso8601()) |> Spec.new(defaults) do
        {:ok, Registration.mark(spec)}
      end
    end
  end

  defp status_transition(status, status), do: :ok
  defp status_transition("active", "report_due"), do: :ok
  defp status_transition("report_due", "reported"), do: :ok
  defp status_transition(from, "cancelled") when from in ~w(draft active), do: :ok
  defp status_transition(_status, "abandoned"), do: :ok
  defp status_transition("draft", "active"), do: :ok
  defp status_transition("active", "concluded"), do: :ok
  defp status_transition(_from, _to), do: {:error, :invalid_status_transition}

  defp annotate(id, annotation, actor) do
    if Paths.valid_id?(id) do
      with :ok <- Persistence.writable(id),
           {:ok, _spec, _read_only?} <- Reader.spec(id),
           {:ok, annotation} <- annotation(annotation, actor),
           :ok <- Journal.append(Paths.file(id, "annotations.ndjson"), annotation) do
        Persistence.broadcast(id)
      end
    else
      {:error, :not_found}
    end
  end

  defp annotation(attrs, actor) do
    attrs = stringify(attrs)

    with true <- attrs["kind"] in ["deploy", "confounder", "unit_exclusion", "note"],
         reason when is_binary(reason) and reason != "" <- attrs["reason"],
         at when is_binary(at) <- attrs["at"],
         {:ok, _time, _offset} <- DateTime.from_iso8601(at),
         true <- is_nil(attrs["unit_ids"]) or (is_list(attrs["unit_ids"]) and Enum.all?(attrs["unit_ids"], &is_binary/1)) do
      {:ok, Map.merge(attrs, %{"schema_version" => Schema.current(), "actor" => actor})}
    else
      _invalid -> {:error, :invalid_annotation}
    end
  end

  defp with_origin(attrs, opts) when is_map(attrs) do
    case Keyword.get(opts, :origin) do
      origin when is_map(origin) -> Map.put_new(attrs, "origin", stringify(origin))
      _origin -> attrs
    end
  end

  defp with_origin(attrs, _opts), do: attrs

  defp config_defaults do
    case Aiur.Config.settings() do
      {:ok, %{experiments: settings}} -> Map.from_struct(settings)
      _unconfigured -> []
    end
  end

  defp entry(kind, actor, at, fields),
    do: Map.merge(fields, %{"schema_version" => Schema.current(), "kind" => kind, "actor" => actor, "at" => at, "event_id" => Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)})

  defp stringify(value), do: value |> Jason.encode!() |> Jason.decode!()
end
