defmodule AiurWeb.Api.UsageProgress.History do
  @moduledoc """
  Ordered progress, check-in and phase-transition events for one ticket.

  Reads the ticket's shared-event-bus history through
  `Aiur.AgentEventFeed.bus_events/2` and keeps only the ticket's own progress
  and phase topics, oldest first. Events the ticket consumed from other tickets
  are excluded: a dependency's progress is not this ticket's progress.

  `bus_events/2` reads the configured repository's log and treats a missing or
  unreadable log as no events, so this read has no separate failure state.
  """

  alias Aiur.AgentEventFeed

  # Progress topics are a small share of a ticket's markers, so the scan reads
  # well past the returned window before filtering.
  @scan_limit 2_000
  @default_limit 20
  @max_limit 50
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

  @spec read(String.t(), keyword()) :: [map()]
  def read(identifier, opts) do
    reader = Keyword.get(opts, :history_fun, &AgentEventFeed.bus_events/2)

    identifier
    |> reader.(limit: @scan_limit)
    |> Enum.flat_map(&entry(&1, identifier))
    |> Enum.take(-Keyword.get(opts, :limit, @default_limit))
  end

  defp entry(%{kind: kind, topic: topic} = row, identifier) when kind != "consumed" and is_binary(topic) do
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
    %{id: Map.get(row, :id), topic: suffix, label: Map.get(row, :label), summary: Map.get(row, :body, ""), at: Map.get(row, :timestamp)}
  end
end
