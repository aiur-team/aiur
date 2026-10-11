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
    bullets = section |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "- "))
    parsed = Enum.map(bullets, &Regex.run(~r/^- `(\S[^`]*)` -> (\S.*)$/, &1))

    if parsed == [] or Enum.any?(parsed, &is_nil/1) do
      {:error, "Local tests requires command bullets with a nonempty -> result"}
    else
      {:ok, Enum.map(parsed, fn [_line, command, result] -> %{command: command, result: result} end)}
    end
  end

  defp rank(mode), do: Enum.find_index(@modes, &(&1 == mode))
end
