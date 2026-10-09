defmodule Aiur.EpicCLI do
  @moduledoc "Formats local epic registry commands dispatched by the shared launcher."
  alias Aiur.BuildOrder.EpicOverrides
  alias Aiur.JSONSafe

  @spec run(keyword()) :: non_neg_integer()
  def run(opts) do
    action = Keyword.fetch!(opts, :action)

    case execute(action, opts) do
      {:ok, result} ->
        IO.puts(if opts[:json], do: Jason.encode!(JSONSafe.normalize(Map.put(result, :ok, true))), else: render(action, result, opts))
        0

      {:error, reason} ->
        if opts[:json], do: IO.puts(Jason.encode!(JSONSafe.normalize(error_result(reason))))
        error_fun = Keyword.get(opts, :error_fun, &IO.puts(:stderr, &1))
        error_fun.("aiur: epic #{action}: #{error_text(reason)}")
        1
    end
  end

  defp error_result(%{state: _} = health), do: %{ok: false, health: health}
  defp error_result(reason), do: %{ok: false, error: inspect(reason)}
  defp error_text(%{failure: reason}), do: "epic overrides unavailable (#{reason})"
  defp error_text(:epic_config_unavailable), do: "epic config unavailable"
  defp error_text(reason), do: inspect(reason)

  defp execute(:list, opts) do
    with {:ok, epics} <- EpicOverrides.catalog(opts), do: {:ok, %{epics: epics}}
  end

  defp execute(:show, opts) do
    with {:ok, overrides, health} <- EpicOverrides.all(opts) do
      known =
        case EpicOverrides.catalog(opts) do
          {:ok, epics} -> Enum.map(epics, & &1.key)
          _ -> nil
        end

      ids = Keyword.get(opts, :ids, [])
      selected = if ids == [], do: overrides, else: Map.take(overrides, ids)
      rows = selected |> Map.values() |> Enum.sort_by(& &1.number) |> Enum.map(&Map.put(Map.from_struct(&1), :epic_known, if(is_nil(known), do: nil, else: &1.epic in known)))
      {:ok, %{health: health, overrides: rows, missing: ids -- Map.keys(selected)}}
    end
  end

  defp execute(action, opts) when action in [:set, :clear] do
    with {:ok, provenance} <- provenance(opts) do
      result = if action == :set, do: EpicOverrides.set(opts[:epic], opts[:ids], provenance, opts), else: EpicOverrides.clear(opts[:ids], provenance, opts)

      with {:ok, result} <- result do
        results = Enum.map(result.results, &Map.put(&1, :epic, opts[:epic]))
        {:ok, result |> Map.put(:source, provenance.source) |> Map.put(:results, results)}
      end
    end
  end

  defp execute(_action, _opts), do: {:error, :invalid_epic_arguments}

  defp provenance(opts) do
    who = opts[:who]
    source = Keyword.get(opts, :source, :cli)

    if is_binary(who) and Regex.match?(~r/\A[A-Za-z0-9._-]{1,64}\z/, who) and source in [:cli, :"backfill-agent"] do
      actor = "cli:" <> who
      {:ok, %{actor: actor, source: if(source == :cli, do: actor, else: "backfill-agent")}}
    else
      {:error, :invalid_epic_arguments}
    end
  end

  defp render(:list, result, _opts), do: Enum.map_join(result.epics, "\n", &"#{&1.key}  #{&1.label}")

  defp render(:show, result, _opts) do
    Enum.map_join(result.overrides, "\n", &show_row/1) <> Enum.map_join(result.missing, "", &"\n##{&1}  no override")
  end

  defp render(action, result, opts) do
    summary = Enum.map_join(result.results, ", ", &"##{&1.number} #{&1.status}")
    previous = result.results |> Enum.filter(&(&1.status == :changed and not is_nil(&1.previous))) |> Enum.map_join("", &previous_row/1)
    "#{action} #{opts[:epic]}: #{summary} (source #{result.source})" <> previous
  end

  defp previous_row(%{number: n, previous: p}), do: "\n##{n} was #{p.epic} by #{p.actor} (#{p.source}, #{confirmation(p.confirmed)})"
  defp confirmation(true), do: "confirmed"
  defp confirmation(false), do: "unconfirmed"

  defp show_row(row) do
    suffix =
      case row.epic_known do
        true -> ""
        false -> " (not a configured epic; ignored)"
        nil -> " (epic config unavailable)"
      end

    "##{row.number}  #{row.epic}#{suffix}  #{row.actor}  #{row.source}  #{confirmation(row.confirmed)}  #{DateTime.to_iso8601(row.at)}"
  end
end
