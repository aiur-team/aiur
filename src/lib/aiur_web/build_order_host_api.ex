defmodule AiurWeb.BuildOrderHostApi do
  @moduledoc "Build Order reads constrained by a verified feature or epic grant."

  alias Aiur.BuildOrder.Features
  alias Aiur.TrackerIdentity

  @spec read(map(), keyword()) :: {:ok, map()} | {:error, :not_found | :unavailable}
  def read(%{build_order: %{kind: :feature, key: key}}, opts), do: document_for(:feature, key, opts)
  def read(%{build_order: %{kind: :epic, key: key}}, opts), do: document_for(:epic, key, opts)
  def read(_scope, _opts), do: {:error, :not_found}

  defp document_for(kind, key, opts) do
    features_opts = Keyword.get(opts, :features_opts, [])

    with {:ok, registry} <- Features.snapshot(features_opts),
         {:ok, scope, slugs} <- resolve(registry, kind, key, features_opts),
         numbers when numbers != [] <- owned_numbers(registry, slugs, kind, key, features_opts),
         {:ok, rows} <- ticket_rows(numbers, opts),
         {:ok, feature_rows} <- feature_rows(kind, scope, registry) do
      {:ok, envelope(scope, feature_rows, kind, key, rows, opts)}
    else
      [] -> {:error, :not_found}
      {:error, :not_found} -> {:error, :not_found}
      {:error, {:unknown_epic, _}} -> {:error, :not_found}
      {:error, _reason} -> {:error, :unavailable}
      _empty -> {:error, :not_found}
    end
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp resolve(registry, :feature, key, _features_opts) do
    case Map.fetch(registry.features, key) do
      {:ok, feature} ->
        epic =
          registry.epics
          |> Enum.find(fn epic -> key in Map.get(epic, :features, []) end)

        {:ok, Map.put(feature, :epic, epic && epic.slug), [key]}

      :error ->
        {:error, :not_found}
    end
  end

  defp resolve(_registry, :epic, key, opts) do
    case Features.epic(key, opts) do
      {:ok, epic} -> {:ok, epic, epic.features}
      error -> error
    end
  end

  defp feature_rows(:feature, _scope, _registry), do: {:ok, []}

  defp feature_rows(:epic, scope, registry) do
    slugs = Map.get(scope, :features, [])

    rows =
      Enum.map(slugs, fn slug ->
        feature = Map.get(registry.features, slug, %{})

        %{
          "key" => slug,
          "title" => Map.get(feature, :label, slug),
          "label" => Map.get(feature, :label, slug),
          "url" => nil,
          "icon" => nil,
          "hue" => Map.get(feature, :hue),
          "epic" => scope.slug,
          "order" => nil,
          "features" => [],
          "progress" => unknown_progress("Feature progress is unknown.")
        }
      end)

    {:ok, rows}
  end

  defp owned_numbers(registry, slugs, kind, key, features_opts) do
    for {number, %{feature: feature}} <- registry.owners,
        feature in slugs,
        owns_ticket?(registry, number, kind, key, features_opts),
        do: number
  end

  defp owns_ticket?(registry, number, :feature, key, _features_opts) do
    case Map.get(registry.owners, number) do
      %{feature: ^key} -> true
      _owner -> false
    end
  end

  defp owns_ticket?(_registry, number, :epic, key, features_opts) do
    case Features.feature_and_epic(number, features_opts) do
      {:ok, %{epic: ^key}} -> true
      _other -> false
    end
  end

  defp owns_ticket?(_registry, _number, _kind, _key, _features_opts), do: true

  defp ticket_rows(numbers, opts) do
    snapshots = Keyword.get(opts, :activity_fun, &Aiur.TicketActivity.snapshots/0).()
    entries = Map.get(snapshots, :entries, [])
    by_number = Map.new(entries, fn entry -> {entry.identity.identifier, entry} end)

    rows =
      Enum.map(numbers, fn number ->
        entry = by_number[to_string(number)]
        %{number: number, title: issue_title(number, entry), status: activity_status(entry), identity: entry && entry.identity}
      end)

    {:ok, rows}
  rescue
    _error -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp envelope(scope, feature_rows, kind, key, rows, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    tickets = Enum.map(rows, &ticket(&1, kind, key))
    progress = unknown_progress("Feature scoped progress is supplied by /api/v1/:issue_identifier/progress.")

    selected = %{
      "key" => key,
      "title" => Map.get(scope, :label, key),
      "label" => Map.get(scope, :label),
      "url" => nil,
      "icon" => Map.get(scope, :icon),
      "hue" => Map.get(scope, :hue),
      "epic" => if(kind == :epic, do: key, else: Map.get(scope, :epic)),
      "order" => 0,
      "features" => if(kind == :epic, do: Map.get(scope, :features, []), else: []),
      "progress" => progress
    }

    %{
      "contract" => "aiur.build_order",
      "contract_version" => 1,
      "build_order_id" => "registry:" <> Atom.to_string(kind) <> ":" <> key,
      "title" => Map.get(scope, :label, key),
      "repository" => repository(rows),
      "root" => nil,
      "generated_at" => DateTime.to_iso8601(now),
      "sources" => %{
        "pack" => unknown_source("No pack metadata is present in the feature registry."),
        "tracker" => unknown_source("Registry membership only"),
        "progress" => unknown_source("Use the ticket progress endpoint for live activity.")
      },
      "epics" => if(kind == :epic, do: [selected], else: []),
      "features" => if(kind == :feature, do: [selected], else: feature_rows),
      "lanes" => [],
      "tickets" => tickets,
      "edges" => [],
      "gates" => [],
      "waves" => [],
      "critical_path" => %{"status" => "unknown", "tickets" => [], "hours" => nil, "reason" => "Registry scope does not include dependency estimates."},
      "progress" => progress
    }
  end

  defp ticket(%{number: number, title: title} = row, kind, key) do
    %{
      "id" => to_string(number),
      "number" => number,
      "title" => title,
      "url" => Map.get(row, :url),
      "kind" => "executable",
      "provenance" => "discovered",
      "epic" => if(kind == :epic, do: key, else: Map.get(row, :epic)),
      "feature" => if(kind == :feature, do: key, else: Map.get(row, :feature)),
      "lane" => nil,
      "phase" => nil,
      "wave" => nil,
      "complexity" => nil,
      "points" => nil,
      "estimate_hours" => nil,
      "status" => Map.get(row, :status, "unknown"),
      "progress_percent" => nil,
      "started_at" => nil,
      "ended_at" => nil
    }
  end

  defp ticket(number, kind, key) when is_integer(number), do: ticket(%{number: number, title: "Ticket #{number}"}, kind, key)

  defp repository(rows) do
    case Enum.find_value(rows, &Map.get(&1, :identity)) do
      %TrackerIdentity{owner: owner, repository: repo} when is_binary(owner) and is_binary(repo) -> owner <> "/" <> repo
      _unknown -> nil
    end
  end

  defp issue_title(_number, %{title: title}) when is_binary(title), do: title
  defp issue_title(number, _entry), do: "Ticket #{number}"
  defp activity_status(%{stage: %{status: :known, value: phase}}) when is_atom(phase), do: Atom.to_string(phase)
  defp activity_status(_entry), do: "unknown"

  defp unknown_source(reason), do: %{"status" => "unknown", "observed_at" => nil, "reason" => reason}

  defp unknown_progress(reason),
    do: %{"status" => "unknown", "total" => nil, "done" => nil, "open" => nil, "failed" => nil, "percent" => nil, "by_status" => nil, "observed_at" => nil, "reason" => reason}
end
