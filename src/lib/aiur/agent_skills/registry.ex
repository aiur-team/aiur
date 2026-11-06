defmodule Aiur.AgentSkills.Registry do
  @moduledoc """
  Reads the skills installed in a workspace, keyed by directory name.

  Kept apart from `Aiur.AgentSkills.Preload` so the file-reading and
  frontmatter-parsing concern stays separate from the ticket-to-skill mapping
  concern. `Preload` delegates its two public readers here.
  """

  @skill_file "SKILL.md"
  # A one-line index entry, not the full description: the point of the index is
  # to be scannable next to the preloaded text.
  @index_description_chars 140
  @fallback_install_path ".claude/skills"

  @doc """
  The skills installed in `workspace`, keyed by directory name.

  Reads every provider install path and keeps the first copy of each skill name,
  so a `.codex/skills` link to `.claude/skills` counts once.
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

  defp read_skill_dir(directory, acc) do
    case File.ls(directory) do
      {:ok, entries} -> Enum.reduce(entries, acc, &read_skill(&2, directory, &1))
      {:error, _reason} -> acc
    end
  end

  defp read_skill(acc, directory, name) do
    path = Path.join([directory, name, @skill_file])

    with true <- File.regular?(path),
         {:ok, text} <- File.read(path) do
      Map.put_new(acc, name, %{name: name, description: description(text), text: text, bytes: byte_size(text), path: path})
    else
      _unreadable -> acc
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
