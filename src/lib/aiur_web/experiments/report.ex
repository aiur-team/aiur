defmodule AiurWeb.Experiments.Report do
  @moduledoc false
  use Phoenix.Component

  alias Aiur.{DisplaySanitizer, Experiments}
  alias AiurWeb.Markdown

  attr(:report, :map, default: nil)

  @spec card(map()) :: Phoenix.LiveView.Rendered.t()
  def card(assigns) do
    ~H"""
    <section id="exp-report" class="an-card" aria-labelledby="exp-report-title">
      <div class="an-card-head"><h3 id="exp-report-title" class="an-card-title">Analyst report</h3></div>
      <p :if={is_nil(@report)} class="an-card-sub">The analyst has not written a report for this experiment yet.</p>
      <div :if={@report}>
        <p class="an-card-sub">{@report.author} · <.timestamp value={@report.written_at} /></p>
        <p :if={@report.changed?} class="exp-notice" id="exp-report-stale">
          Results changed after this report was written (report <.timestamp value={@report.written_at} />, results <.timestamp value={@report.results_at} />)
        </p>
        <div :if={@report.markdown} class="ticket-context-markdown">{Markdown.render(@report.markdown, heading_offset: 2)}</div>
        <p :if={is_nil(@report.markdown)} class="exp-notice">The analyst report could not be displayed.</p>
      </div>
    </section>
    """
  end

  @spec from_detail(map()) :: map() | nil
  def from_detail(detail) do
    case detail |> Map.get(:report_records, %{}) |> Map.get("reports", []) |> List.last() do
      nil ->
        nil

      report ->
        header = report["header"]
        analyst = header["analyst"]
        author = Enum.join(Enum.reject([analyst["agent"], analyst["model"]], &is_nil/1), " / ")
        times = Enum.map(Map.get(detail, :snapshots, []), &datetime(&1["computed_at"]))
        results_at = times |> Enum.reject(&is_nil/1) |> Enum.max(DateTime, fn -> nil end)

        prepare(%{
          markdown: Experiments.report_markdown(report),
          author: if(author != "", do: author),
          written_at: header["generated_at"],
          results_at: if(results_at, do: DateTime.to_iso8601(results_at))
        })
    end
  end

  @spec prepare(map() | nil) :: map() | nil
  def prepare(nil), do: nil

  def prepare(report) do
    written_at = datetime(report[:written_at])
    results_at = datetime(report[:results_at])

    %{
      markdown: sanitized(report[:markdown], 128_000),
      author: sanitized(report[:author], 1_000) || "Unknown analyst",
      written_at: written_at,
      results_at: results_at,
      changed?: not is_nil(written_at) and not is_nil(results_at) and DateTime.compare(results_at, written_at) == :gt
    }
  end

  defp sanitized(value, limit) do
    case DisplaySanitizer.sanitize(value, limit) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _offset} -> time
      {:error, _reason} -> nil
    end
  end

  defp datetime(_value), do: nil

  attr(:value, :any, required: true)

  defp timestamp(assigns) do
    ~H"""
    <time :if={@value} datetime={DateTime.to_iso8601(@value)} title={DateTime.to_iso8601(@value)}>{relative(@value)}</time>
    <span :if={is_nil(@value)}>Unknown time</span>
    """
  end

  defp relative(value) do
    seconds = DateTime.diff(DateTime.utc_now(), value, :second)

    cond do
      seconds <= 60 -> "just now"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end
end
