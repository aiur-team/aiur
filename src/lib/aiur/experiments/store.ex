defmodule Aiur.Experiments.Store do
  @moduledoc false
  use GenServer
  require Logger

  alias Aiur.Experiments.{Journal, Paths, Persistence, Reader, Registration, Schema, Spec}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    with :ok <- Aiur.Journal.ensure_directory(Paths.root()), :ok <- Persistence.recover() do
      {:ok, %{append: Keyword.get(opts, :journal_writer, &Journal.append/2), defaults: Map.new(Keyword.get(opts, :defaults, config_defaults())) |> Map.put_new(:repo_slug, Paths.repo())}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:create, attrs, opts}, _from, state) do
    result = create(attrs, opts, state)
    {:reply, result, state}
  end

  def handle_call({:amend, id, changes, actor, kind}, _from, state) do
    result = amend(id, changes, actor, kind, state)
    {:reply, result, state}
  end

  def handle_call({:annotate, id, annotation, actor}, _from, state) do
    {:reply, annotate(id, annotation, actor), state}
  end

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

    with {:ok, spec} <- Spec.new(attrs, state.defaults) do
      case existing(spec.key) do
        {:error, _reason} = error -> error
        {:ok, nil} -> create_new(spec, opts, state)
        {:ok, id} -> existing_spec(id)
      end
    end
  end

  defp existing_spec(id) do
    with :ok <- Persistence.recover_one(id), {:ok, old, _read_only?} <- Reader.spec(id), {:ok, old} <- Spec.new(old) do
      {:ok, %{old | existing: true}}
    end
  end

  defp create_new(spec, opts, state) do
    spec = Registration.mark(spec)
    id = spec.id || next_id(spec.title)

    cond do
      not Paths.valid_id?(id) ->
        {:error, [%{path: "id", message: "invalid experiment id"}]}

      File.exists?(Paths.experiment(id)) ->
        {:error, :id_exists}

      true ->
        spec = %{spec | id: id}
        entry = entry("created", Keyword.get(opts, :actor, "operator"), spec.updated_at, %{"origin" => Keyword.get(opts, :origin)})
        with :ok <- Persistence.commit(id, Spec.to_map(spec), entry, state.append), do: {:ok, spec}
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
           :ok <- status_transition(old["status"], updated.status) do
        persist_amendment(id, old, updated, actor, kind, state.append)
      end
    else
      {:error, :not_found}
    end
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
