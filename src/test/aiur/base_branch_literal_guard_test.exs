defmodule Aiur.BaseBranchLiteralGuardTest do
  use ExUnit.Case, async: true

  @allowed_main_literals %{
    "aiur_web/components/operator_control_center/dashboard_shell.ex" => [~s(class="shell-main")],
    "aiur_web/live/streamdeck_live.ex" => [~s(class="sd-key-main")]
  }

  test "production code contains no hardcoded main branch literal" do
    lib_root = Path.expand("../../lib", __DIR__)

    violations =
      lib_root
      |> Path.join("**/*.{ex,exs}")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        relative_path = Path.relative_to(path, lib_root)
        source = File.read!(path)
        lines = String.split(source, "\n")

        source
        |> hardcoded_main_literal_lines()
        |> Enum.reject(fn line_number -> allowed_main_literal?(relative_path, Enum.at(lines, line_number - 1)) end)
        |> Enum.map(fn line_number -> "#{relative_path}:#{line_number}" end)
      end)

    assert violations == [],
           "hardcoded base-branch literal found; route the value through Aiur.Config.base_branch instead:\n" <>
             Enum.join(violations, "\n")
  end

  test "guard catches every quoted main token while allowing function names" do
    assert hardcoded_main_literal_lines("defp base_branch do\n  _ -> \"main\"\nend") == [2]
    assert hardcoded_main_literal_lines("def prewarm_label, do: \"fetching main\"") == [1]
    assert hardcoded_main_literal_lines("def main(args), do: args\nmode = \"main\"") == [2]
    assert hardcoded_main_literal_lines("def main(args), do: args") == []
  end

  defp hardcoded_main_literal_lines(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _line_number} -> String.match?(line, ~r/"[^"\n]*\bmain\b[^"\n]*"/i) end)
    |> Enum.map(&elem(&1, 1))
  end

  defp allowed_main_literal?(path, line) do
    Enum.any?(Map.get(@allowed_main_literals, path, []), &String.contains?(line, &1))
  end
end
