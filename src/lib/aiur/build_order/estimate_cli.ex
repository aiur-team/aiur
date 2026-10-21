defmodule Aiur.BuildOrder.EstimateCLI do
  @moduledoc "CLI reads and durable writes for ticket estimate overrides."
  alias Aiur.BuildOrder.Estimates

  @spec run(keyword()) :: 0 | 1
  def run(opts \\ []) do
    with {:ok, request} <- request(opts),
         {:ok, _} <- Estimates.get(request.id, store_opts(opts)),
         :ok <- write(request, opts),
         {:ok, record} <- Estimates.get(request.id, store_opts(opts)) do
      result = Map.merge(record, context(request.id, opts)) |> Map.put(:id, request.id)
      if opts[:json], do: IO.puts(Jason.encode!(Aiur.JSONSafe.normalize(result))), else: IO.puts(human(result))
      0
    else
      {:error, reason} ->
        Keyword.get(opts, :error_fun, &IO.puts(:stderr, &1)).("aiur: #{error(reason)}")
        1
    end
  end

  defp request(opts) do
    hours = hours(opts[:hours])
    by = Keyword.get(opts, :by, "cli:#{System.get_env("USER", "unknown")}")
    write? = opts[:clear] == true or opts[:hours] != nil

    with :ok <- shape(opts),
         :ok <- valid_hours(opts, hours),
         {:ok, reason} <- validate(opts[:id], hours, opts[:reason], by, write?) do
      {:ok, %{id: opts[:id], hours: hours, reason: reason, by: by, clear: opts[:clear] == true}}
    end
  end

  defp shape(opts) do
    cond do
      Keyword.keys(opts) -- [:id, :hours, :reason, :by, :clear, :json, :server, :snapshot_fun, :error_fun] != [] -> {:error, :unknown_option}
      opts[:json] not in [nil, false, true] -> {:error, :invalid_json}
      opts[:clear] not in [nil, false, true] -> {:error, :invalid_clear}
      opts[:clear] == true and opts[:hours] != nil -> {:error, :clear_with_hours}
      true -> :ok
    end
  end

  defp valid_hours(opts, hours) do
    if opts[:hours] != nil and is_nil(hours), do: {:error, :invalid_hours}, else: :ok
  end

  defp validate(id, hours, reason, by, true), do: Estimates.validate(id, hours || :clear, reason, by)

  defp validate(id, _hours, reason, by, false) do
    cond do
      not (is_integer(id) and id > 0) -> {:error, :invalid_id}
      not Estimates.valid_by?(by) -> {:error, :invalid_by}
      reason != nil -> {:error, :reason_without_write}
      true -> {:ok, nil}
    end
  end

  defp hours(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9]{1,3}(\.(0|00|25|5|50|75))?\z/, value) do
      case Float.parse(value) do
        {number, ""} when number > 0 and number <= 999 -> number
        _ -> nil
      end
    end
  end

  defp hours(value) when is_number(value) and value >= 0.25 and value <= 999 do
    if value * 4 == trunc(value * 4), do: value
  end

  defp hours(_), do: nil
  defp store_opts(opts), do: Keyword.take(opts, [:server])

  defp write(%{clear: true} = request, opts), do: result(Estimates.clear(request.id, request.reason, request.by, store_opts(opts)))
  defp write(%{hours: nil}, _opts), do: :ok
  defp write(request, opts), do: result(Estimates.put(request.id, request.hours, request.reason, request.by, store_opts(opts)))
  defp result({:ok, _}), do: :ok
  defp result({:error, reason}), do: {:error, reason}

  defp context(id, opts) do
    snapshot = Keyword.get(opts, :snapshot_fun, fn -> AiurWeb.Build.Index.window(AiurWeb.Build.Index, "Etc/UTC", 1_000) end)

    case safe_snapshot(snapshot) do
      {:ok, %{sections: sections, sources: %{queue: %{state: state}}}} ->
        plan = Map.get(sections, :plan, [])
        row = [:plan, :now, :nq, :hist] |> Enum.flat_map(&Map.get(sections, &1, [])) |> Enum.find(&(&1.num == id))
        planned = planned(plan, id, state)
        %{planned: planned, default_hours: Estimates.default_hours(row && row.cx), complexity: row && row.cx}

      _ ->
        %{planned: "unknown", default_hours: nil, complexity: nil}
    end
  end

  defp planned(_plan, _id, "disabled"), do: false

  defp planned(plan, id, state) when state in ["ok", "stale", "incomplete"] do
    if Enum.any?(plan, &(&1.num == id)), do: true, else: if(state == "ok", do: false, else: "unknown")
  end

  defp planned(_plan, _id, _state), do: "unknown"

  defp safe_snapshot(fun) do
    fun.()
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp human(%{override: override} = result) do
    complexity = if result.complexity, do: " from complexity:#{result.complexity}", else: ""
    default = "default #{label(result.default_hours)}#{complexity}"
    estimate = if override, do: "#{label(override.hours)} (override by #{override.by}, #{override.at}; #{default}). Reason: #{override.reason}", else: "#{default} (no override)"
    planned = if result.planned == false, do: "; not planned now; no card shows it until it is queued", else: ""
    journal = Enum.map_join(result.journal, "\n", fn entry -> "  #{entry.op} #{label(entry.hours)} by #{entry.by} at #{entry.at}: #{entry.reason}" end)
    "##{result.id} estimate #{estimate}#{planned}" <> if(journal == "", do: "", else: "\nJournal:\n#{journal}")
  end

  defp label(nil), do: "—"
  defp label(hours), do: "≈#{:erlang.float_to_binary(hours / 1, [:compact, decimals: 2]) |> String.trim_trailing("0") |> String.trim_trailing(".")}h"
  defp error(%{failure: failure}), do: unavailable(failure)
  defp error(:estimates_unavailable), do: unavailable(:estimates_unavailable)
  defp error(reason), do: "ticket estimate refused (#{inspect(reason)})"

  defp unavailable(reason) do
    path =
      case Aiur.Config.Paths.build_estimates_state_dir() do
        {:ok, path} -> Path.join(path, "estimates.json")
        _ -> "estimates.json"
      end

    "estimate store unavailable (#{reason}); restore or remove #{path}.corrupt-*, then restart"
  end
end
