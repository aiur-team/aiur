defmodule AiurWeb.Build.HomeAssetsScanTest do
  use ExUnit.Case, async: true

  @assets Path.expand("../../../priv/static/build-home", __DIR__)

  test "payload clock exports exist; future regression guard rejects wall clock reads" do
    clock = File.read!(Path.join(@assets, "clock.js"))
    assert clock =~ "export function setNow"
    assert clock =~ "export const nowMs"
    assert File.read!(Path.join(@assets, "hook.js")) =~ "./clock.js"
    Enum.each(Path.wildcard(Path.join(@assets, "**/*.js")), &assert(clock_violations(File.read!(&1)) == []))
    assert clock_violations("const NOW = Date.now(); new Date()") == ["NOW", "Date.now(", "new Date()"]
  end

  test "future regression guard requires managed resources and detects planted calls" do
    Enum.each(Path.wildcard(Path.join(@assets, "**/*.js")), fn path ->
      unless Path.basename(path) == "life.js" do
        assert resource_violations(File.read!(path)) == []
      end
    end)

    shell = File.read!(Path.join(@assets, "shell.js"))
    assert resource_violations(shell <> "\nsetInterval(syncSB, 500)") == ["setInterval("]
    assert resource_violations("window.addEventListener('click', f); new ResizeObserver(f)") == ["window.addEventListener(", "new ResizeObserver("]
  end

  defp clock_violations(source), do: Regex.scan(~r/\bNOW\b|Date\.now\s*\(|new Date\s*\(\s*\)/, source) |> List.flatten()
  defp resource_violations(source), do: Regex.scan(~r/\bsetInterval\s*\(|(?:document|window)\.addEventListener\s*\(|new ResizeObserver\s*\(/, source) |> List.flatten()
end
