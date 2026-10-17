defmodule Aiur.LocalTestEvidence do
  @moduledoc "Parses the PR Local tests section shared by CI and merge-policy consumers."

  @modes ["none", "partial", "all"]
  @sha ~r/\A[0-9a-fA-F]{40}\z/
  @type evidence :: %{policy: String.t(), tested_head: String.t(), base: String.t(), selection: String.t(), commands: [map()]}

  @spec parse(String.t()) :: {:ok, evidence()} | :missing | {:error, String.t()}
  def parse(body) do
    sections = Regex.scan(~r/^\#{2,6} Local tests\s*\n(.*?)(?=^\#{1,6} |\z)/ms, body)

    case sections do
      [] -> :missing
      [[_heading, section]] -> parse_section(section)
      _duplicates -> {:error, "Duplicate Local tests sections"}
    end
  end

  @spec validate(evidence(), String.t(), String.t() | nil) :: :ok | {:error, String.t()}
  def validate(evidence, mode, head \\ nil) do
    cond do
      mode not in @modes -> {:error, "Invalid repo local_tests mode"}
      rank(evidence.policy) < rank(mode) -> {:error, "Local tests policy below repo mode #{mode}"}
      head != nil and String.downcase(evidence.tested_head) != String.downcase(head) -> {:error, "Local tests Tested head does not match PR head"}
      true -> :ok
    end
  end

  defp parse_section(section) do
    with {:ok, policy} <- field(section, "Policy"),
         true <- policy in @modes or {:error, "Local tests Policy must be all, partial or none"},
         {:ok, head} <- field(section, "Tested head"),
         true <- Regex.match?(@sha, head) or {:error, "Local tests Tested head must be a full 40-character SHA"},
         {:ok, base} <- field(section, "Base"),
         true <- Regex.match?(~r/\A\S+ @ [0-9a-fA-F]{40}\z/, base) or {:error, "Local tests Base must be ref @ full 40-character SHA"},
         {:ok, selection} <- field(section, "Selection"),
         {:ok, commands} <- commands(section) do
      {:ok, %{policy: policy, tested_head: head, base: base, selection: selection, commands: commands}}
    end
  end

  defp field(section, name) do
    case Regex.scan(Regex.compile!("^#{name}: *([^\\n]*)$", "m"), section) do
      [[_line, value]] -> nonempty_field(value, name)
      _missing_or_duplicate -> {:error, "Local tests requires one nonempty #{name} field"}
    end
  end

  defp nonempty_field(value, name) do
    case String.trim(value) do
      "" -> {:error, "Local tests requires one nonempty #{name} field"}
      value -> {:ok, value}
    end
  end

  defp commands(section) do
    lines = String.split(section, "\n")
    indexes = for {line, index} <- Enum.with_index(lines), String.starts_with?(line, "- "), do: index
    parsed = Enum.map(indexes, &Regex.run(~r/^- `(\S[^`]*)` -> (\S.*)$/, Enum.at(lines, &1)))

    cond do
      parsed == [] or Enum.any?(parsed, &is_nil/1) ->
        {:error, "Local tests requires command bullets with a nonempty -> result"}

      not contiguous_after_fields?(lines, indexes) ->
        {:error,
         "Local tests command bullets must be one unbroken list directly after Selection: " <>
           "remove blank lines and prose between bullets, and move notes below the list"}

      true ->
        {:ok, Enum.map(parsed, fn [_line, command, result] -> %{command: command, result: result} end)}
    end
  end

  defp contiguous_after_fields?(lines, [first | _rest] = indexes) do
    previous = lines |> Enum.take(first) |> Enum.reject(&(String.trim(&1) == "")) |> List.last("")
    List.last(indexes) - first + 1 == length(indexes) and Regex.match?(~r/^(Policy|Tested head|Base|Selection):/, previous)
  end

  defp rank(mode), do: Enum.find_index(@modes, &(&1 == mode))
end
