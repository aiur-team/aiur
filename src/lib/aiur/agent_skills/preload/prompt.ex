defmodule Aiur.AgentSkills.Preload.Prompt do
  @moduledoc "Renders a resolved `Aiur.AgentSkills.Preload` as the worker's prompt blocks."

  alias Aiur.AgentSkills.Preload
  alias Aiur.AgentSkills.Preload.Skill
  alias Aiur.AgentSkills.Registry

  @doc """
  The prompt block, or `""` when the workspace has no readable skills.

  Mapped skills come first with their full `SKILL.md` text, then every other
  installed skill as a one-line index, then anything mapped but not installed.
  """
  @spec prompt_block(Preload.t()) :: String.t()
  def prompt_block(%Preload{} = preload) do
    if preload.mapped == [] and preload.recommended == [] and preload.index == [] and preload.missing == [] do
      ""
    else
      [
        heading(),
        mapped_section(preload),
        recommended_section(preload),
        index_section(preload),
        missing_section(preload)
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")
      |> Kernel.<>("\n")
    end
  end

  @doc """
  A short pointer to the mapped skills for a resumed session, or `""` when none
  are mapped. The thread may have lost the inlined text to compaction, so this
  names each skill, its reason and its `SKILL.md` path instead of repeating it.
  """
  @spec pointer_block(Preload.t()) :: String.t()
  def pointer_block(%Preload{mapped: []}), do: ""

  def pointer_block(%Preload{} = preload) do
    entries = Enum.map_join(preload.mapped, "\n", &"- `#{&1.name}` (#{&1.reason}) — `#{&1.path}`")

    "## Skills for this ticket (pointer)\n\n" <>
      "These skills are mapped to this ticket. If their instructions are no longer in your context, re-read each `SKILL.md` before continuing.\n\n" <>
      entries <> "\n\n"
  end

  defp heading do
    """
    ## Skills for this ticket

    Load the mapped skills first: they fit this ticket's work, and their instructions are
    inlined below so you can start without opening a file. Recommended skills also fit, but
    are listed with a path to open when the work needs them. Every other installed skill is
    listed after them as a name and description you can load on demand.\
    """
  end

  defp mapped_section(%Preload{mapped: []}), do: ""

  defp mapped_section(%Preload{mapped: mapped}) do
    entries = Enum.map_join(mapped, "\n\n", &mapped_entry/1)
    "### Mapped skills (load first)\n\n" <> entries
  end

  defp mapped_entry(%Skill{} = skill) do
    ["#### `", skill.name, "` — mapped by ", skill.reason, "\n\n", String.trim(skill.text || "")]
    |> IO.iodata_to_binary()
  end

  defp recommended_section(%Preload{recommended: []}), do: ""

  defp recommended_section(%Preload{recommended: recommended}) do
    entries =
      Enum.map_join(recommended, "\n", fn skill ->
        "- `#{skill.name}` (#{skill.reason}) — #{skill.description || Registry.index_description(nil)}\n  Load: `#{skill.path}`"
      end)

    "### Recommended skills (load on demand)\n\n" <>
      "These fit this ticket but are not inlined. Read the `SKILL.md` at the path shown when the work needs it.\n\n" <>
      entries
  end

  defp index_section(%Preload{index: []}), do: ""

  defp index_section(%Preload{index: index}) do
    entries = Enum.map_join(index, "\n", &"- `#{&1.name}` — #{Registry.index_description(&1.description)}")

    "### Other installed skills (load on demand)\n\n" <> entries
  end

  defp missing_section(%Preload{missing: []}), do: ""

  defp missing_section(%Preload{missing: missing}) do
    entries = Enum.map_join(missing, "\n", &"- `#{&1.name}` (#{&1.reason})")

    "### Mapped skills not installed here\n\n" <>
      "These names are mapped to this ticket but have no `SKILL.md` in this workspace, so they\n" <>
      "are not inlined. Do not stall on them: record the gap in your workpad and carry on with\n" <>
      "the skills above.\n\n" <> entries
  end
end
