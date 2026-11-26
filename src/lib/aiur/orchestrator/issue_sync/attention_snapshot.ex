defmodule Aiur.Orchestrator.IssueSync.AttentionSnapshot do
  @moduledoc "Process-local attention projection for one synchronous candidate poll."

  alias Aiur.AlertFeed

  @key {__MODULE__, :topics}

  @spec run((-> result)) :: result when result: var
  def run(fun) do
    if Process.get(@key) do
      fun.()
    else
      Process.put(@key, :unloaded)

      try do
        fun.()
      after
        Process.delete(@key)
      end
    end
  end

  @spec topics() :: MapSet.t()
  def topics, do: snapshot().topics

  defp snapshot do
    case Process.get(@key) do
      nil -> load()
      :unloaded -> load() |> tap(&Process.put(@key, &1))
      topics -> topics
    end
  end

  @spec active_system_attention?(String.t()) :: boolean()
  def active_system_attention?(topic), do: MapSet.member?(snapshot().system_topics, topic)

  defp load do
    alerts = AlertFeed.list(needs_attention: true)
    %{topics: MapSet.new(alerts, & &1["topic"]), system_topics: alerts |> Enum.filter(&(&1["agent"] == "system")) |> MapSet.new(& &1["topic"])}
  end
end
