defmodule Aiur.AffectedTests.Command do
  @moduledoc false

  @spec build({:full, String.t()} | {:scoped, [String.t()]}) :: [String.t()]
  def build({:full, reason}),
    do: ["# full suite recommended: #{reason}", "cd src && mise exec -- make ci"]

  def build({:scoped, []}), do: ["# no affected test files detected for the documentation-only change"]

  def build({:scoped, tests}) do
    paths = Enum.map(tests, &(&1 |> String.replace_prefix("src/", "") |> shell_quote()))
    ["cd src && mise exec -- mix test --max-cases 4 " <> Enum.join(paths, " ")]
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
