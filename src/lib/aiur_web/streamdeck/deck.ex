defmodule AiurWeb.Streamdeck.Deck do
  @moduledoc "Deck adapter over shared read models, with isolated section failures."

  alias AiurWeb.Streamdeck.Deck.{BuildOrder, Counts}

  @spec read(keyword()) :: map()
  def read(opts \\ []) do
    %{build_order: read_section(BuildOrder, opts), counts: Counts.read(opts)}
  end

  defp read_section(section, opts) do
    section.read(opts)
  rescue
    _error -> %{build: nil, build_status: "unavailable"}
  catch
    :exit, _reason -> %{build: nil, build_status: "unavailable"}
  end
end
