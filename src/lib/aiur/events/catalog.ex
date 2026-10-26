defmodule Aiur.Events.Catalog do
  @moduledoc """
  Pure registry of current Exchange topics. This data does not change routing,
  publication or delivery; export flags describe the approved future feed.

  The most specific matching pattern wins. Unrecognized topics are private,
  live events. Catalog tests reject overlapping patterns with equal scores.
  """

  alias Aiur.Events
  alias Aiur.Events.Catalog.{Entries, Entry}

  @spec entries() :: [Entry.t()]
  defdelegate entries(), to: Entries

  @spec lookup(String.t()) :: Entry.t()
  def lookup(topic) when is_binary(topic) do
    entries()
    |> Enum.filter(&Events.matches?(&1.pattern, topic))
    |> Enum.max_by(&Events.specificity_score(&1.pattern), &default/0)
  end

  @spec exported() :: [Entry.t()]
  def exported, do: Enum.filter(entries(), & &1.export?)

  @spec default() :: Entry.t()
  def default, do: %Entry{pattern: "#", class: :live, owner: "unknown"}
end
