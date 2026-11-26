defmodule LocalHost.BriefingSource do
  @moduledoc "Markdown briefing and notes stored beneath the host root."
  @behaviour VoiceConverse.Ports.BriefingSource
  @impl true
  def describe_target(_target), do: %{id: "local", kind: :executor, title: "Local project"}
  @impl true
  def brief(_target) do
    with {:ok, text} <- File.read(LocalHost.path("briefing.md")) do
      {:ok, VoiceConverse.Briefing.from_markdown(text)}
    else
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  @impl true
  def details(_target, "notes", _opts), do: File.read(LocalHost.path("notes.md"))
  def details(_target, _section, _opts), do: {:error, :not_found}
  @impl true
  def sections(_target), do: [%{id: "notes", description: "Project notes"}]
  @impl true
  def subscribe(target, pid), do: LocalHost.Files.subscribe({:briefing, target}, pid)
  @impl true
  def alive?(_target), do: File.regular?(LocalHost.path("briefing.md"))
end
