defmodule AiurWeb.Api.UsageProgress.History do
  @moduledoc """
  Ordered progress, check-in and phase-transition events for one ticket.

  Reads the ticket's IssueLog event markers through `Aiur.IssueLog.event_history/2`
  and keeps only the ticket's own progress and phase topics, oldest first.
  Events the ticket consumed from other tickets are excluded: a dependency's
  progress is not this ticket's progress.
  """

  alias Aiur.{AgentEventFeed, IssueLog, TrackerIdentity}

  # Progress topics are a small share of a ticket's markers, so the scan reads
  # well past the returned window before filtering.
  @scan_limit 2_000
  @default_limit 20
  @max_limit 50
  @kinds [:emit, :emit_alert, :self]
  @progress_topics %{
    "agent.progress" => :progress,
    "agent.progress.checkin" => :checkin,
    "agent.progress.phase" => :phase_progress
  }
  @stages ~w(brainstorm plan work review)
  @transitions ~w(start end)

  @spec default_limit() :: pos_integer()
  def default_limit, do: @default_limit

  @spec max_limit() :: pos_integer()
  def max_limit, do: @max_limit

  @spec read(String.t(), TrackerIdentity.t() | nil, keyword()) ::
          {:available | :unavailable, [map()]}
  def read(identifier, identity, opts) do
    reader = Keyword.get(opts, :history_fun, &IssueLog.event_history/2)
    limit = Keyword.get(opts, :limit, @default_limit)

    case rows(reader.(source(identifier, identity), kinds: @kinds, limit: @scan_limit)) do
      {:ok, rows} -> {:available, rows |> Enum.flat_map(&entry(&1, identifier)) |> Enum.take(-limit)}
      :unavailable -> {:unavailable, []}
    end
  end

  # A joinable identity resolves the exact repository's log; a bare display
  # identifier falls back to the configured repository's log. Only the
  # identity read reports failures: the bare-identifier read degrades an
  # unreadable log to [], so `:unavailable` requires a joinable identity.
  defp source(identifier, identity) do
    if TrackerIdentity.joinable?(identity), do: identity, else: identifier
  end

  defp rows(rows) when is_list(rows), do: {:ok, rows}
  defp rows({:ok, rows}) when is_list(rows), do: {:ok, rows}
  # No log yet is an ordinary state: the ticket has published nothing.
  defp rows({:error, :missing_source}), do: {:ok, []}
  defp rows(_error), do: :unavailable

  defp entry(%{topic: topic} = row, identifier) when is_binary(topic) do
    with {:ok, suffix} <- own_suffix(topic, identifier),
         {:ok, fields} <- classify(suffix) do
      [Map.merge(base(row, suffix), fields)]
    else
      :ignore -> []
    end
  end

  defp entry(_row, _identifier), do: []

  defp own_suffix(topic, identifier) do
    prefix = "ticket.#{identifier}."
    if String.starts_with?(topic, prefix), do: {:ok, String.replace_prefix(topic, prefix, "")}, else: :ignore
  end

  defp classify(suffix) when is_map_key(@progress_topics, suffix),
    do: {:ok, %{type: Map.fetch!(@progress_topics, suffix)}}

  defp classify("agent.phase." <> rest) do
    case String.split(rest, ".") do
      [stage, transition] when stage in @stages and transition in @transitions ->
        {:ok, %{type: :phase, phase: stage, transition: transition}}

      _other ->
        :ignore
    end
  end

  defp classify(_suffix), do: :ignore

  defp base(row, suffix) do
    %{
      id: Map.get(row, :id),
      topic: suffix,
      label: AgentEventFeed.topic_label(row.topic),
      summary: row |> Map.get(:summary, "") |> to_string() |> AgentEventFeed.scrub() |> String.trim(),
      at: Map.get(row, :ts)
    }
  end
end
