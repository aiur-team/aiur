defmodule AiurWeb.StreamdeckPackageIndependenceTest do
  use ExUnit.Case, async: true

  @src Path.expand("../..", __DIR__)
  # Prose only (a README pointer in an install prompt and a comment); no file reads.
  @prose_only ["lib/aiur_web/live/streamdeck_live.ex"]

  test "daemon compile inputs never reference the sidecar package source tree" do
    files =
      Path.wildcard(Path.join(@src, "lib/**/*.ex")) ++
        Path.wildcard(Path.join(@src, "config/*.exs")) ++ [Path.join(@src, "mix.exs")]

    assert files != []

    offenders =
      files
      |> Enum.reject(&(Path.relative_to(&1, @src) in @prose_only))
      |> Enum.filter(&(&1 |> File.read!() |> String.contains?("packages/" <> "streamdeck")))
      |> Enum.map(&Path.relative_to(&1, @src))

    assert offenders == []
  end
end
