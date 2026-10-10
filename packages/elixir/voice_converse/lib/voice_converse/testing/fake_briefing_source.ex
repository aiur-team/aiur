defmodule VoiceConverse.Testing.FakeBriefingSource do
  @moduledoc """
  Stateless fake. The target is a map; optional keys: `:briefing`, `:sleep_ms` (delay before
  `brief/1` answers), `:exit` (`brief/1` exits).
  """
  @behaviour VoiceConverse.Ports.BriefingSource

  alias VoiceConverse.Briefing

  @impl true
  def describe_target(t),
    do: %{id: Map.get(t, :id, "fake"), kind: Map.get(t, :kind, :fake), title: Map.get(t, :title, "Fake")}

  @impl true
  def brief(t) do
    if t[:sleep_ms], do: Process.sleep(t.sleep_ms)
    if t[:exit], do: exit(:boom)
    {:ok, Map.get(t, :briefing, %Briefing{})}
  end

  @impl true
  def details(t, section, _opts), do: {:ok, get_in(t, [:details, section]) || ""}

  @impl true
  def sections(t), do: Map.get(t, :sections, [])

  @impl true
  def subscribe(_t, _pid), do: :unsupported

  @impl true
  def alive?(_t), do: :unknown
end
