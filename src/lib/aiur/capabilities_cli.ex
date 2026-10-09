defmodule Aiur.CapabilitiesCLI do
  @moduledoc "Read-only capability report for the local control CLI."

  @spec run(keyword()) :: 0
  def run(opts \\ []) do
    report = Keyword.get(opts, :report_fun, &Aiur.Capabilities.report/0).()
    output = if Keyword.get(opts, :json, false), do: Jason.encode!(Aiur.Capabilities.to_wire(report)), else: render(report)
    IO.puts(output)
    0
  end

  @spec render(map()) :: String.t()
  def render(report) do
    header = "aiur capabilities — #{value(report.machine, :label)} / #{value(report.instance, :instance_id)}"
    age = "#{report.age_ms / 1_000}s ago"
    rows = report.capabilities |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&capability/1)

    Enum.join(
      [
        "#{header} (revision #{report.revision}, observed #{age}, #{report.freshness})",
        "repository   #{repository(report.repository)}",
        "executor     #{value(report.executor, :state)}  #{value(report.executor, :consumer_id)}" | rows
      ],
      "\n"
    )
  end

  defp repository(nil), do: "unknown"

  defp repository(repository) do
    name = [repository[:owner], repository[:name]] |> Enum.reject(&is_nil/1) |> Enum.join("/")
    "#{value(repository, :kind)} #{name}"
  end

  defp capability({id, entry}) do
    reason = if entry[:reason], do: "  #{entry.reason}", else: ""

    needs =
      case entry[:depends_on] do
        dependencies when is_list(dependencies) and dependencies != [] -> " (needs #{Enum.join(dependencies, ", ")})"
        _ -> ""
      end

    "#{String.pad_trailing(id, 25)}#{value(entry, :state)}#{reason}#{needs}"
  end

  defp value(section, key), do: (section && Map.get(section, key)) || "unknown"
end
