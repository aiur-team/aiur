defmodule Aiur.AgentList.Renderer.ChromeUsageTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentList.Renderer.Chrome

  @width 120

  defp text(iodata), do: iodata |> IO.iodata_to_binary() |> strip_ansi()
  defp strip_ansi(binary), do: Regex.replace(~r/\e\[[0-9;?]*[a-zA-Z]/, binary, "")

  test "an observed provider renders a bar, a percentage, and an age" do
    row = Chrome.usage_row(%{claude: observed(42, 120)}, @width)

    assert text(row) =~ "Usage:"
    assert text(row) =~ "claude"
    assert text(row) =~ "42%"
    assert text(row) =~ "(2m)"
    assert text(row) =~ "████░░░░░░"
  end

  # An empty bar reads as "0% consumed"; a provider we have never observed must
  # not be drawn that way.
  test "a never-observed provider reads n/a and draws no bar" do
    row = text(Chrome.usage_row(%{claude: unknown()}, @width))

    assert row =~ "claude n/a"
    refute row =~ "░"
    refute row =~ "█"
  end

  test "no usage at all still renders the row as n/a" do
    assert text(Chrome.usage_row(%{}, @width)) =~ "Usage:"
    assert text(Chrome.usage_row(%{}, @width)) =~ "n/a"
    assert text(Chrome.usage_row(nil, @width)) =~ "n/a"
  end

  # The window that will stop work first is the one worth the header's line.
  test "the worst-consumed rate-limit window wins" do
    view = %{
      state: :observed,
      age_seconds: 30,
      windows: %{
        "session" => %{kind: :rate_limit, used_percent: 12},
        "weekly" => %{kind: :rate_limit, used_percent: 88}
      }
    }

    assert text(Chrome.usage_row(%{codex: view}, @width)) =~ "88%"
  end

  test "non-rate-limit windows are ignored" do
    view = %{
      state: :observed,
      age_seconds: 5,
      windows: %{"spend" => %{kind: :budget, used_percent: 99}}
    }

    assert text(Chrome.usage_row(%{codex: view}, @width)) =~ "codex n/a"
  end

  test "both providers render, ordered stably" do
    row = text(Chrome.usage_row(%{claude: observed(10, 10), codex: observed(20, 10)}, @width))

    assert row =~ "claude"
    assert row =~ "codex"

    claude_at = :binary.match(row, "claude") |> elem(0)
    codex_at = :binary.match(row, "codex") |> elem(0)
    assert claude_at < codex_at, "providers should render in a stable, sorted order"
  end

  test "ages scale from seconds to hours" do
    assert text(Chrome.usage_row(%{codex: observed(5, 45)}, @width)) =~ "(45s)"
    assert text(Chrome.usage_row(%{codex: observed(5, 600)}, @width)) =~ "(10m)"
    assert text(Chrome.usage_row(%{codex: observed(5, 7_200)}, @width)) =~ "(2h)"
  end

  defp observed(percent, age_seconds) do
    %{
      state: :observed,
      age_seconds: age_seconds,
      windows: %{"session" => %{kind: :rate_limit, used_percent: percent}}
    }
  end

  defp unknown, do: %{state: :unknown, age_seconds: nil, windows: %{}}
end
