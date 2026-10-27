defmodule AiurWeb.OperatorControlCenter.RunSummaryStripQuotaCopyTest do
  # The keyed-card filter reads credential env vars, which are process-global,
  # so these tests must not run concurrently with each other.
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias AiurWeb.{OperatorControlCenter.RunSummaryStrip, StaticAssets}

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

  test "a GitHub card still awaiting a response shows the awaiting placeholder" do
    with_deepseek_key(fn ->
      quota = %{github_quota_view() | state: :loading, windows: %{}}

      html =
        render_component(&RunSummaryStrip.run_summary_strip/1, %{
          run: run_view(),
          usage: usage_view(),
          meters: %{state: :authorized, cards: Enum.take(model_cards(), 1)},
          github_quota: quota,
          now: @now
        })

      assert html =~ "Awaiting GitHub response"
    end)
  end

  # ---- ElevenLabs credit quota ----
  #
  # ElevenLabs publishes a character/credit quota plus the amount due on the
  # next invoice. The latter is owed money, never a spendable balance. Like the
  # other meters on this strip, the credit bar shows the remaining share.
  test "an unconfigured ElevenLabs account leaves no trace on the strip" do
    html = strip(elevenlabs_quota: %{state: :unconfigured, window: nil, failure: nil, observed_at: nil})

    refute html =~ "ElevenLabs"
    refute html =~ "Credits remaining"
    refute html =~ "rs-elevenlabs"
    assert html =~ "1 API"
    refute html =~ "2 APIs"
  end

  test "an omitted ElevenLabs quota is an absent account, not an empty meter" do
    html =
      render_component(&RunSummaryStrip.run_summary_strip/1, %{
        run: run_view(),
        usage: usage_view(),
        meters: meters_view(),
        github_quota: github_quota_view(),
        now: @now
      })

    refute html =~ "ElevenLabs"
    assert html =~ "1 API"
  end

  test "a configured account renders a remaining-credit meter and invoice amount beside GitHub" do
    html = strip(elevenlabs_quota: elevenlabs_quota_view())
    row = elevenlabs_row(html)

    assert html =~ "2 APIs"
    assert html =~ ~s(title="Github - for ticket state")
    assert html =~ ~s(src="/elevenlabs-symbol.svg")
    assert html =~ ~s(title="Elevenlabs - for voice to text")
    assert row =~ "Credits"
    assert row =~ "75.0K left · 75% left · resets 3d"
    assert row =~ ~s(style="width:75%")
    refute row =~ "Next invoice due"
    refute row =~ "$5.00"
    refute row =~ "100.0K"
    refute row =~ "credits left"

    assert {:ok, "image/svg+xml", svg} = StaticAssets.fetch("/elevenlabs-symbol.svg")
    assert svg =~ ~s(<svg width="180" height="292")
  end

  test "the label names the quota it meters and the billing it does not" do
    row = elevenlabs_row(strip(elevenlabs_quota: elevenlabs_quota_view()))

    assert row =~ "account credit quota"
    assert row =~ "Speech-to-text is billed per minute of audio and is not counted here."
    assert row =~ "The dollar figure is the amount due on the next invoice, not a balance."
  end

  test "an absent next invoice does not hide the credit meter" do
    row = elevenlabs_row(strip(elevenlabs_quota: elevenlabs_quota_view(next_invoice: nil)))

    assert row =~ "75.0K left · 75% left · resets 3d"
    assert row =~ ~s(style="width:75%")
    refute row =~ "Next invoice due"
    refute row =~ "$"
  end

  test "compact reset copy chooses one truthful unit" do
    cases = [
      {DateTime.add(@now, -1, :second), "reset time passed"},
      {DateTime.add(@now, 3, :day), "resets 3d"},
      {DateTime.add(@now, 5, :hour), "resets 5h"},
      {DateTime.add(@now, 45, :minute), "resets 45m"},
      {nil, "reset unavailable"}
    ]

    for {reset_at, expected} <- cases do
      row = elevenlabs_row(strip(elevenlabs_quota: elevenlabs_quota_view(reset_at: reset_at)))
      assert row =~ expected
    end
  end

  test "a configured key with no answer yet says so and draws an empty bar" do
    row = elevenlabs_row(strip(elevenlabs_quota: %{state: :unknown, window: nil, failure: nil, observed_at: nil}))

    assert row =~ "Awaiting ElevenLabs response"
    assert row =~ ~s(class="rs-meter is-unknown")
  end

  test "a configured key whose read failed surfaces the failure without the credential" do
    for {failure, sentence} <- [
          {:authentication, "the API key was rejected"},
          {:rate_limited, "rate limited by ElevenLabs"},
          {:provider_error, "ElevenLabs returned an error"},
          {:transport, "ElevenLabs could not be reached"},
          {:malformed, "the response could not be read"}
        ] do
      row = elevenlabs_row(strip(elevenlabs_quota: %{state: :failed, window: nil, failure: failure, observed_at: nil}))

      assert row =~ "Unavailable · " <> sentence
      assert row =~ ~s(class="rs-meter is-unknown")
    end
  end

  test "a nearly exhausted quota warns and an exhausted one is critical" do
    warning = elevenlabs_row(strip(elevenlabs_quota: elevenlabs_quota_view(used: 95_000)))
    assert warning =~ ~s(class="is-critical" style="width:5%")

    critical = elevenlabs_row(strip(elevenlabs_quota: elevenlabs_quota_view(used: 100_000)))
    assert critical =~ ~s(class="is-critical" style="width:0%")

    healthy = elevenlabs_row(strip(elevenlabs_quota: elevenlabs_quota_view()))
    refute healthy =~ "is-warning"
    refute healthy =~ "is-critical"
  end

  test "a zero character limit renders the credits and an empty bar" do
    row = elevenlabs_row(strip(elevenlabs_quota: elevenlabs_quota_view(limit: 0, used: 0)))

    assert row =~ "0 left"
    assert row =~ ~s(class="rs-meter is-unknown")
    refute row =~ "% used"
  end
end
