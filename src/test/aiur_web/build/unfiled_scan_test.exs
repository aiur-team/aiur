defmodule AiurWeb.Build.UnfiledScanTest do
  use ExUnit.Case, async: true

  @patterns [~r/["']#["']\s*\+\s*\w+\.num\b/, ~r/["']Q["']\s*\+\s*\w+\.qpos\b/, ~r/#\$\{\s*\w+\.num\s*\}/, ~r/Q\$\{\s*\w+\.qpos\s*\}/, ~r/wave\s*>=\s*5/, ~r/build-plan\.md/]
  defp offenders(text), do: Enum.filter(@patterns, &Regex.match?(&1, text))

  test "renderers use shared unfiled display helpers" do
    files = Path.wildcard(Path.expand("../../../priv/static/build-home/**/*.js", __DIR__)) |> Enum.reject(&String.ends_with?(&1, "/unfiled.js"))
    assert files != []

    assert Enum.flat_map(files, fn file ->
             file
             |> File.read!()
             |> String.split("\n")
             |> Enum.with_index(1)
             |> Enum.flat_map(fn {line, n} ->
               if offenders(line) == [], do: [], else: ["#{file}:#{n}: #{line}"]
             end)
           end) == []
  end

  test "future regression guard: scanner catches concatenated and interpolated identities" do
    assert offenders(~s("#" + t.num)) != []
    assert offenders(~S(`Q${t.qpos}`)) != []
  end
end
