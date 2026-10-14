defmodule AiurWeb.OperatorControlCenter.RunSummaryStripFixtures do
  @moduledoc false
  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias AiurWeb.OperatorControlCenter.RunSummaryStrip

  @now ~U[2026-07-20 12:00:00Z]

  # OpenAI-compatible providers only occupy strip space when their configured
  # credential env resolves to a non-empty value. These tests exercise those
  # cards, so they set the env in-process and restore it afterwards.

  def with_deepseek_key(fun) do
    previous = System.get_env("DEEPSEEK_API_KEY")
    System.put_env("DEEPSEEK_API_KEY", "test-key")

    try do
      fun.()
    after
      restore_env("DEEPSEEK_API_KEY", previous)
    end
  end

  def with_kimi_key(fun) do
    previous = System.get_env("MOONSHOT_API_KEY")
    System.put_env("MOONSHOT_API_KEY", "test-key")

    try do
      fun.()
    after
      restore_env("MOONSHOT_API_KEY", previous)
    end
  end

  def with_openrouter_key(fun) do
    previous = System.get_env("OPENROUTER_MANAGEMENT_KEY")
    System.put_env("OPENROUTER_MANAGEMENT_KEY", "test-key")

    try do
      fun.()
    after
      restore_env("OPENROUTER_MANAGEMENT_KEY", previous)
    end
  end

  def restore_env(key, nil), do: System.delete_env(key)

  def restore_env(key, value), do: System.put_env(key, value)

  # Everything after the ElevenLabs row's marker class and before the next pane.
  def elevenlabs_row(html) do
    [_before, rest] = String.split(html, "rs-elevenlabs", parts: 2)
    rest |> String.split("rs-block", parts: 2) |> List.first()
  end

  def strip(opts) do
    defaults = %{run: run_view(), usage: usage_view(), meters: meters_view(), github_quota: github_quota_view(), now: @now}
    render_component(&RunSummaryStrip.run_summary_strip/1, Enum.into(opts, defaults))
  end

  def elevenlabs_quota_view(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100_000)
    used = Keyword.get(opts, :used, 25_000)

    %{
      state: :observed,
      failure: nil,
      observed_at: @now,
      window: %{
        limit: limit,
        used: used,
        remaining: max(limit - used, 0),
        used_percent: test_used_percent(used, limit),
        next_invoice: Keyword.get(opts, :next_invoice, %{amount_due_cents: 500, currency: "USD"}),
        tier: "creator",
        reset_at: Keyword.get(opts, :reset_at, DateTime.add(@now, 3, :day)),
        observed_at: @now
      }
    }
  end

  def test_used_percent(_used, limit) when limit <= 0, do: nil

  def test_used_percent(used, limit) do
    used
    |> Kernel./(limit)
    |> Kernel.*(100)
    |> max(0.0)
    |> min(100.0)
    |> Float.round(1)
  end

  # Every pane in the strip is an `.rs-block`: the GitHub card and the models
  # pane.
  def pane_count(html), do: length(String.split(html, "rs-block")) - 1

  def model_cards do
    [
      model_card(:codex, "Codex", :healthy, "Healthy", [model_window("Session", 40, remaining: 3000, limit: 5000)]),
      model_card(:claude, "Claude", :stale, "Not live", [
        model_window("Session", 62, remaining: 1900, limit: 5000, freshness: :stale)
      ]),
      model_card(:deepseek, "DeepSeek", :healthy, "Healthy", [model_window("Session", 0, remaining: 5000, limit: 5000)]),
      model_card(:kimi, "Kimi", :unavailable, "Unavailable", [])
    ]
  end

  def model_card(provider, label, state, status_label, windows) do
    %{
      provider: provider,
      provider_label: label,
      state: state,
      status_label: status_label,
      auth_mode: %{value: :api_key},
      windows: windows
    }
  end

  def model_window(name, percent, opts) do
    %{
      kind: :rate_limit,
      name: name,
      coverage_label: "Supported",
      meter: %{kind: :exact, now: percent, min: 0, max: 100},
      used: percent,
      used_percent: percent,
      remaining: Keyword.get(opts, :remaining),
      limit: Keyword.get(opts, :limit),
      freshness: Keyword.get(opts, :freshness, :fresh),
      resets_at: DateTime.add(@now, 30, :minute)
    }
  end

  def github_quota_view do
    %{
      state: :observed,
      windows: %{
        "core" => %{resource: "core", remaining: 3750, limit: 5000, used_percent: 25.0, reset_at: DateTime.add(@now, 30, :minute)}
      },
      attribution: [],
      backoffs: []
    }
  end

  def run_view do
    %{
      state: :ready,
      counts: %{live: 3, remaining: 4},
      progress: %{kind: :exact, percent: 60},
      elapsed: %{label: "20m"},
      eta: %{label: "About 8m remaining"}
    }
  end

  def usage_view do
    %{
      state: :ready,
      api_equivalent: %{by_currency: [%{currency: "USD", amount: "8.75"}]},
      providers: %{
        codex: %{tokens: %{total: 1_500}, api_equivalent: [%{currency: "USD", amount: "2.50"}]},
        claude: %{tokens: %{total: 2_000}, api_equivalent: [%{currency: "USD", amount: "6.25"}]}
      }
    }
  end

  def meters_view do
    %{
      state: :authorized,
      cards: [
        meter_card(:codex, "Codex", 40),
        meter_card(:claude, "Claude", 25)
      ]
    }
  end

  def card(provider) do
    %{
      provider: provider,
      provider_label: provider_label(provider),
      status_label: "Healthy",
      auth_mode: %{value: :api_key},
      windows: []
    }
  end

  def provider_label(provider) do
    case Aiur.CodingAgent.provider_descriptor(provider) do
      %{label: label} -> label
      _ -> provider |> to_string() |> String.capitalize()
    end
  end

  def meter_card(provider, label, percent) do
    %{
      provider: provider,
      provider_label: label,
      status_label: "Healthy",
      auth_mode: %{value: :api_key},
      windows: [
        %{
          kind: :rate_limit,
          name: "Session",
          coverage_label: "Supported",
          meter: %{kind: :exact, now: percent},
          resets_at: DateTime.add(@now, 30, :minute)
        }
      ]
    }
  end

  # Mirrors the shape ProviderMetersPresenter emits: the rendered percentage
  # comes from `meter.now`, and `coverage_label` is required by the meta
  # renderer.
  def scoped_window(limit_id, percent) do
    %{
      limit_id: limit_id,
      kind: :rate_limit,
      name: "Primary",
      coverage_label: "Supported",
      meter: %{kind: :exact, now: percent, min: 0, max: 100},
      used: percent,
      used_percent: percent,
      resets_at: DateTime.add(@now, 30, :minute)
    }
  end

  def restore_app_env(app, key, previous) do
    if is_nil(previous) do
      Application.delete_env(app, key)
    else
      Application.put_env(app, key, previous)
    end
  end
end
