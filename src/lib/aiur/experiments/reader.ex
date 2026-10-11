defmodule Aiur.Experiments.Reader do
  @moduledoc false

  alias Aiur.Experiments.{Journal, Paths, Registration, Schema, Spec}

  @spec json(Path.t()) :: {:ok, map()} | {:error, term()}
  def json(path) do
    with {:ok, bytes} <- File.read(path), {:ok, value} when is_map(value) <- Jason.decode(bytes) do
      {:ok, value}
    else
      {:ok, _other} -> {:error, :unreadable}
      {:error, :enoent} -> {:error, :not_found}
      {:error, _reason} -> {:error, :unreadable}
    end
  end

  @spec spec(String.t()) :: {:ok, map(), boolean()} | {:error, term()}
  def spec(id) do
    if Paths.valid_id?(id) do
      with {:ok, raw} <- json(Paths.file(id, "spec.json")) do
        migrate_spec(raw)
      end
    else
      {:error, :not_found}
    end
  end

  defp migrate_spec(raw) do
    case Schema.migrate(raw) do
      {:ok, migrated} ->
        case Spec.new(migrated) do
          {:ok, spec} -> {:ok, Spec.to_map(Registration.mark(spec)), false}
          {:error, _errors} -> {:error, :unreadable}
        end

      {:error, {:newer_version, _version}} ->
        {:ok, raw, true}

      {:error, _reason} ->
        {:error, :unreadable}
    end
  end

  @spec summaries() :: {:ok, [map()]} | {:error, term()}
  def summaries do
    with {:ok, ids} <- Paths.ids() do
      {:ok,
       Enum.map(ids, fn id ->
         case spec(id) do
           {:ok, spec, read_only?} -> summary(id, spec) |> Map.put(:read_only?, read_only?)
           {:error, reason} -> %{id: id, error: reason}
         end
       end)}
    end
  end

  defp summary(id, spec) do
    %{id: id, title: spec["title"], kind: safe_get(spec, ["design", "kind"]), status: spec["status"], created_at: spec["created_at"], updated_at: spec["updated_at"]}
  end

  @spec fetch(String.t()) :: {:ok, map()} | {:error, term()}
  def fetch(id) do
    with {:ok, spec, spec_read_only?} <- spec(id),
         {:ok, journal} <- Journal.read(Paths.file(id, "journal.ndjson")),
         {:ok, annotations} <- Journal.read(Paths.file(id, "annotations.ndjson")),
         {:ok, snapshots} <- snapshots(id) do
      read_only? = spec_read_only? or newer?(journal ++ annotations) or pending_newer?(id)
      {:ok, %{spec: spec, phase: phase(spec), journal: Enum.take(journal, -50), annotations: annotations, snapshots: snapshots, read_only?: read_only?}}
    end
  end

  defp pending_newer?(id) do
    case json(Paths.file(id, "pending.json")) do
      {:ok, pending} -> newer?([pending])
      _missing -> false
    end
  end

  defp newer?(rows), do: Enum.any?(rows, &match?({:error, {:newer_version, _}}, Schema.migrate(&1)))

  defp phase(%{"design" => design, "windows" => windows} = spec) when is_map(design) and is_map(windows) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    change = safe_get(spec, ["design", "change", "time"])
    end_time = safe_get(spec, ["windows", "after", "end"]) || safe_get(spec, ["windows", "observation", "end"])

    cond do
      is_binary(change) and later?(change, now) -> :awaiting_change
      is_binary(end_time) and not later?(end_time, now) -> :window_closed
      true -> :collecting
    end
  end

  defp phase(_unknown), do: :unknown

  defp later?(left, right) do
    with {:ok, left, _} <- DateTime.from_iso8601(left), {:ok, right, _} <- DateTime.from_iso8601(right) do
      DateTime.compare(left, right) == :gt
    else
      _invalid -> false
    end
  end

  defp safe_get(map, keys) do
    Enum.reduce(keys, map, fn
      key, value when is_map(value) -> Map.get(value, key)
      _key, _unknown -> nil
    end)
  end

  defp snapshots(id) do
    case File.ls(Paths.file(id, "snapshots")) do
      {:ok, names} -> {:ok, Enum.sort(names)}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end
end
