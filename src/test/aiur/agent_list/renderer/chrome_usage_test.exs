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
    assert text(row) =~ "58% left"
    assert text(row) =~ "(2m)"
    assert text(row) =~ "██████░░░░"
  end

  # An empty bar reads as exhausted; a provider we have never observed must not
  # be drawn that way.
  test "a never-observed provider reads n/a and draws no bar" do
    row = text(Chrome.usage_row(%{claude: unknown()}, @width))

    assert row =~ "claude n/a"
    refute row =~ "░"
    refute row =~ "█"
  end

  # Claude's CLI reports a standing and a reset time but no utilization, so a
  # bar is impossible for it. Name what is known instead of drawing an empty
  # bar, which would read as exhausted.
  test "a provider with a standing but no percentage names the standing" do
    view = %{
      state: :observed,
      age_seconds: 30,
      windows: %{
        "rate-limit" => %{
          kind: :rate_limit,
          standing: :allowed,
          resets_at: DateTime.add(DateTime.utc_now(), 7_200, :second)
        }
      }
    }

    row = text(Chrome.usage_row(%{claude: view}, @width))

    assert row =~ "claude ok"
    assert row =~ "resets in 1h" or row =~ "resets in 2h"
    refute row =~ "░"
    refute row =~ "0%"
  end

  # A weekly window reading "167h" makes the reader divide to learn it is a week
  # away.
  test "a reset more than a day out reads in days" do
    view = %{
      state: :observed,
      age_seconds: 5,
      windows: %{
        "r" => %{
          kind: :rate_limit,
          standing: :allowed,
          resets_at: DateTime.add(DateTime.utc_now(), 167 * 3_600 + 1_800, :second)
        }
      }
    }

    row = text(Chrome.usage_row(%{claude: view}, @width))

    assert row =~ "resets in 6d"
    refute row =~ "167h"
  end

  test "a limited standing reads as limited, not as unknown" do
    view = %{state: :observed, age_seconds: 5, windows: %{"r" => %{kind: :rate_limit, standing: :rejected}}}

    assert text(Chrome.usage_row(%{claude: view}, @width)) =~ "claude limited"
  end

  test "an unknown standing still reads n/a" do
    view = %{state: :observed, age_seconds: 5, windows: %{"r" => %{kind: :rate_limit, standing: :unknown}}}

    assert text(Chrome.usage_row(%{claude: view}, @width)) =~ "claude n/a"
  end

  test "no usage at all still renders the row as n/a" do
    assert text(Chrome.usage_row(%{}, @width)) =~ "Usage:"
    assert text(Chrome.usage_row(%{}, @width)) =~ "n/a"
    assert text(Chrome.usage_row(nil, @width)) =~ "n/a"
  end

  # The window that will stop work first is the one worth the header's line.
  test "the least-remaining rate-limit window wins" do
    view = %{
      state: :observed,
      age_seconds: 30,
      windows: %{
        "session" => %{kind: :rate_limit, used_percent: 12},
        "weekly" => %{kind: :rate_limit, used_percent: 88}
      }
    }

    assert text(Chrome.usage_row(%{codex: view}, @width)) =~ "12% left"
  end

  test "an explicit remaining percentage takes precedence over derived usage" do
    view = %{
      state: :observed,
      age_seconds: 30,
      windows: %{
        "session" => %{kind: :rate_limit, used_percent: 40, remaining_percent: 65}
      }
    }

    assert text(Chrome.usage_row(%{codex: view}, @width)) =~ "65% left"
  end

  test "non-rate-limit windows are ignored" do
    view = %{
      state: :observed,
      age_seconds: 5,
      windows: %{"spend" => %{kind: :budget, used_percent: 99}}
    }

    assert text(Chrome.usage_row(%{codex: view}, @width)) =~ "codex n/a"
  end

  test "a provider credit balance renders as dollars rather than a fake percentage" do
    view = %{
      state: :observed,
      age_seconds: 15,
      windows: %{"credits" => %{kind: :credit, credits: %{status: :available, amount: 77.5}}}
    }

    row = text(Chrome.usage_row(%{openrouter: view}, @width))
    assert row =~ "openrouter $77.50 left (15s)"
    refute row =~ "%"
    refute row =~ "░"
  end

  test "DeepSeek renders exact balance and local concurrency without a provider percentage" do
    view = %{
      state: :observed,
      age_seconds: 15,
      windows: %{
        "balance" => %{kind: :credit, credits: %{status: :available, amount: 12.5}},
        "local-concurrency" => %{
          kind: :rate_limit,
          name: "Local concurrency",
          used: 2,
          limit: 2_500,
          used_percent: 0.08
        }
      }
    }

    row = text(Chrome.usage_row(%{deepseek: view}, @width))
    assert row =~ "deepseek $12.50 left · 2/2500 concurrent (15s)"
    refute row =~ "%"
    refute row =~ "░"
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
