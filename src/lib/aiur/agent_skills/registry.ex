defmodule Aiur.AgentSkills.Registry do
  @moduledoc """
  Reads the skills installed in a workspace, keyed by skill directory name.

  Kept apart from `Aiur.AgentSkills.Preload` so the file-reading and
  frontmatter-parsing concern stays separate from the ticket-to-skill mapping
  concern. `Preload` delegates its two public readers here.
  """

  @skill_file "SKILL.md"
  # A one-line index entry, not the full description: the point of the index is
  # to be scannable next to the preloaded text.
  @index_description_chars 140
  @fallback_install_path ".claude/skills"
  # `<name>`, `<group>/<name>` and `<group>/<pack>/<name>` below an install path.
  @max_depth 3

  @doc """
  The skills installed in `workspace`, keyed by directory name.

  Reads every provider install path and keeps the first copy of each skill name,
  so a `.codex/skills` link to `.claude/skills` counts once. A skill nested up to
  three directories deep (`vendor/<pack>/<skill>/SKILL.md`) is keyed by its own
  directory name; a shallower skill of the same name wins.
  """
  @spec installed_skills(Path.t() | nil) :: %{String.t() => map()}
  def installed_skills(workspace) when is_binary(workspace) do
    install_paths()
    |> Enum.reduce(%{}, fn path, acc -> read_skill_dir(Path.join(workspace, path), acc) end)
  end

  def installed_skills(_workspace), do: %{}

  defp install_paths do
    Aiur.AgentSkills.install_paths()
  rescue
    _error -> [@fallback_install_path]
  catch
    _kind, _reason -> [@fallback_install_path]
  end

  # Breadth-first, so a skill nearer the install path wins a name collision with
  # a nested one (`vendor/<pack>/<skill>`). A directory holding a SKILL.md is a
  # skill and is not searched further; depth is bounded so a symlink loop or a
  # large tree cannot stall prompt building.
  defp read_skill_dir(root, acc) do
    {acc, _dirs} =
      Enum.reduce(1..@max_depth, {acc, [root]}, fn _level, {acc, dirs} ->
        dirs
        |> Enum.flat_map(&children/1)
        |> Enum.reduce({acc, []}, &visit/2)
        |> then(fn {acc, next} -> {acc, Enum.reverse(next)} end)
      end)

    acc
  end

  defp children(directory) do
    case File.ls(directory) do
      {:ok, entries} -> entries |> Enum.reject(&String.starts_with?(&1, ".")) |> Enum.sort() |> Enum.map(&Path.join(directory, &1))
      {:error, _reason} -> []
    end
  end

  defp visit(entry, {acc, next}) do
    path = Path.join(entry, @skill_file)

    cond do
      File.regular?(path) -> {read_skill(acc, Path.basename(entry), path), next}
      File.dir?(entry) -> {acc, [entry | next]}
      true -> {acc, next}
    end
  end

  defp read_skill(acc, name, path) do
    case File.read(path) do
      {:ok, text} -> Map.put_new(acc, name, %{name: name, description: description(text), text: text, bytes: byte_size(text), path: path})
      {:error, _unreadable} -> acc
    end
  end

  # The `description:` field of the SKILL.md frontmatter, unquoted and joined.
  # Every bundled skill carries one; a skill without frontmatter still loads,
  # it just shows up in the index without a description.
  @doc false
  @spec description(String.t()) :: String.t() | nil
  def description(text) when is_binary(text) do
    case Regex.run(~r/\A---\r?\n(.*?)\r?\n---/s, text) do
      [_, frontmatter] -> parse_description(frontmatter)
      _no_frontmatter -> nil
    end
  end

  def description(_text), do: nil

  defp parse_description(frontmatter) do
    lines = String.split(frontmatter, ~r/\r?\n/)

    case Enum.find_index(lines, &Regex.match?(~r/\Adescription:/, &1)) do
      nil -> nil
      index -> lines |> Enum.drop(index) |> collect_description() |> unquote_description()
    end
  end

  defp collect_description([first | rest]) do
    inline = first |> String.replace_prefix("description:", "") |> String.trim() |> block_scalar_marker()
    continuation = rest |> Enum.take_while(&continuation?/1) |> Enum.map(&String.trim/1)

    [inline | continuation] |> Enum.reject(&(&1 == "")) |> Enum.join(" ")
  end

  defp block_scalar_marker(value) when value in [">", "|", ">-", "|-", ">+", "|+"], do: ""
  defp block_scalar_marker(value), do: value

  defp continuation?(line) do
    case line do
      "---" <> _rest -> false
      <<" ", _rest::binary>> -> true
      <<"\t", _rest::binary>> -> true
      _ -> false
    end
  end

  defp unquote_description(description) do
    description = String.replace(description, ~r/\s+/, " ") |> String.trim()

    case description do
      <<"\"", _rest::binary>> -> trim_pair(description, "\"")
      <<"'", _rest::binary>> -> trim_pair(description, "'")
      _plain -> nilify(description)
    end
  end

  defp trim_pair(value, quote) do
    size = byte_size(value)

    if size > 1 and binary_part(value, size - 1, 1) == quote do
      binary_part(value, 1, size - 2) |> String.replace(~r/\\"/, "\"") |> nilify()
    else
      nilify(value)
    end
  end

  defp nilify(""), do: nil
  defp nilify(value), do: value

  @doc false
  @spec index_description(String.t() | nil) :: String.t()
  def index_description(nil), do: "no description in its SKILL.md"
  def index_description(description), do: shorten(description)

  defp shorten(description) when byte_size(description) <= @index_description_chars, do: description

  defp shorten(description) do
    shortened = binary_part(description, 0, @index_description_chars)
    # Cut on a word boundary when there is one near the limit.
    case Regex.run(~r/\A(.*)\s/, shortened, capture: :all_but_first) do
      [head | _] when byte_size(head) > 0 -> head <> "…"
      _ -> shortened <> "…"
    end
  end
end
