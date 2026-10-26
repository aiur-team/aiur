defmodule Aiur.Events.Catalog do
  @moduledoc """
  Pure registry of current Exchange topics. This data does not change routing,
  publication or delivery; export flags describe the approved future feed.

  The most specific matching pattern wins. Unrecognized topics are private,
  live events. Catalog tests reject overlapping patterns with equal scores.
  """

  # aiur:event-bus-boundary-member

  alias Aiur.Events
  alias Aiur.Events.Catalog.{Entries, Entry}

  @entries Entries.entries()
  @lookup_entries Enum.sort_by(@entries, &Events.specificity_score(&1.pattern), :desc)
  @exported Enum.filter(@entries, & &1.export?)

  @spec entries() :: [Entry.t()]
  def entries, do: @entries

  @spec lookup(String.t()) :: Entry.t()
  def lookup(topic) when is_binary(topic) do
    Enum.find(@lookup_entries, &Events.matches?(&1.pattern, topic)) || default()
  end

  @spec exported() :: [Entry.t()]
  def exported, do: @exported

  @spec default() :: Entry.t()
  def default, do: %Entry{pattern: "#", class: :live, owner: "unknown"}
end
