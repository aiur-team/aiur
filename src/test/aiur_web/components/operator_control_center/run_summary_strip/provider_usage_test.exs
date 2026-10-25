defmodule AiurWeb.OperatorControlCenter.RunSummaryStripProviderUsageTest do
  # The keyed-card filter reads credential env vars, which are process-global,
  # so these tests must not run concurrently with each other.
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias AiurWeb.{OperatorControlCenter.RunSummaryStrip}

  @now ~U[2026-07-20 12:00:00Z]

  setup do
    # Deterministic keyed-filter baseline: these credential env vars start
    # unset in every test; a test opts in via the with_*_key helpers.
    System.delete_env("DEEPSEEK_API_KEY")
    System.delete_env("MOONSHOT_API_KEY")
    System.delete_env("OPENROUTER_API_KEY")
    System.delete_env("OPENROUTER_MANAGEMENT_KEY")
    :ok
  end

  # OpenAI-compatible providers only occupy strip space when their configured
  # credential env resolves to a non-empty value. These tests exercise those
  # cards, so they set the env in-process and restore it afterwards.
  import AiurWeb.OperatorControlCenter.RunSummaryStripFixtures

  # Codex reports an account-wide limit alongside per-model ones. Only the
  # account-wide bucket governs whether work can proceed, and a row per model
  # turns a glanceable card into a table.
  test "only the account-wide rate limit is shown, not per-model ones" do
    meters = %{
      state: :authorized,
      cards: [
        %{
          provider: :codex,
          provider_label: "Codex",
          state: :ready,
          windows: [
            scoped_window("codex:primary", 12),
            scoped_window("codex_bengalfox:primary", 88)
          ]
        }
      ]
    }

    html =
      render_component(&RunSummaryStrip.run_summary_strip/1, %{
        run: %{state: :loading},
        usage: %{state: :ready, providers: %{}},
        meters: meters,
        now: @now
      })

    assert html =~ "88% left"
    refute html =~ ~s(<span class="rs-pc">12% left</span>)
  end

  test "falls back to whatever exists when no account-wide window is reported" do
    meters = %{
      state: :authorized,
      cards: [
        %{
          provider: :codex,
          provider_label: "Codex",
          state: :ready,
          windows: [scoped_window("codex_bengalfox:primary", 88)]
        }
      ]
    }

    html =
      render_component(&RunSummaryStrip.run_summary_strip/1, %{
        run: %{state: :loading},
        usage: %{state: :ready, providers: %{}},
        meters: meters,
        now: @now
      })

    assert html =~ "12% left"
  end

  # Codex reports `hasCredits`/`unlimited`/`rateLimitResetCredits` facts, not a
  # prepaid dollar balance. They must not render as a "Credits … balance" row
  # with a meter, which would imply a spendable balance that does not exist.
  test "codex drops its credit windows instead of rendering a balance" do
    meters = %{
      state: :authorized,
      cards: [
        %{
          provider: :codex,
          provider_label: "Codex",
          state: :ready,
          status_label: "Healthy",
          auth_mode: %{value: :subscription},
          windows: [
            scoped_window("codex:primary", 12),
            %{kind: :credit, name: :credits, coverage_label: "Supported", credits: %{status: :exhausted, label: "Exhausted"}}
          ]
        }
      ]
    }

    html =
      render_component(&RunSummaryStrip.run_summary_strip/1, %{
        run: %{state: :loading},
        usage: %{state: :ready, providers: %{}},
        meters: meters,
        now: @now
      })

    assert html =~ "88% left"
    refute html =~ "balance"
    refute html =~ "Exhausted"
  end

  # A prepaid balance is a :credit window with no percentage. It must render as
  # a dollar amount, never as a fabricated "0% consumed" bar. Local concurrency
  # is an instantaneous process-local reading, so retaining it on a provider
  # card would turn it into a permanently stale pseudo-limit.
  test "renders a credit balance and omits local concurrency from provider cards" do
    with_deepseek_key(fn ->
      credit = %{
        kind: :credit,
        name: :credits,
        coverage_label: "Supported",
        credits: %{status: :available, label: "Available", amount: 7.25},
        expires_at: DateTime.add(@now, 5, :minute)
      }

      Enum.each([{0, :ready, :fresh}, {5, :stale, :stale}, {42, :ready, :fresh}], fn {used, state, freshness} ->
        concurrency =
          scoped_window("local-concurrency", used)
          |> Map.merge(%{name: "Local concurrency", freshness: freshness, resets_at: nil})

        meters = %{
          state: :authorized,
          cards: [model_card(:deepseek, "DeepSeek", state, "Healthy", [credit, concurrency])]
        }

        html = strip(run: %{state: :loading}, usage: %{state: :ready, providers: %{}}, meters: meters)

        assert html =~ "$7.25"
        refute html =~ "Local concurrency"
        refute html =~ "reset unavailable"
        [_before_provider, provider_html] = String.split(html, "DeepSeek", parts: 2)
        assert length(Regex.scan(~r/<div class="rs-ln"/, provider_html)) == 1
      end)
    end)
  end
end
