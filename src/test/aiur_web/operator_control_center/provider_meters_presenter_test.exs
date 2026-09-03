defmodule AiurWeb.OperatorControlCenter.ProviderMetersPresenterTest do
  use ExUnit.Case, async: true

  alias Aiur.ProviderMeterSnapshot
  alias AiurWeb.OperatorControlCenter.ProviderMetersPresenter, as: Presenter

  @reset ~U[2026-07-18 12:00:00Z]
  @observed ~U[2026-07-18 11:30:00Z]

  describe "locked capability" do
    test "renders a content-free locked view with no cards or protected facts" do
      view =
        Presenter.present(%{state: :locked, accessible_name: "Provider meters locked", reason: "Authentication is required.", authentication_path: "Sign in."}, %{
          codex: healthy(:codex),
          claude: healthy(:claude)
        })

      assert view.state == :locked
      assert view.cards == []
      assert view.locked.accessible_name == "Provider meters locked"
      assert view.locked.reason == "Authentication is required."
      assert view.locked.authentication_path == "Sign in."

      # No protected snapshot value leaks into the locked view.
      refute inspect(view) =~ "gen-codex"
      refute inspect(view) =~ "Primary"
      refute inspect(view) =~ "subscription"
      refute inspect(view) =~ ":pro"
    end

    test "announcement names the locked state" do
      view = Presenter.present(%{state: :locked}, %{codex: healthy(:codex)})
      assert Presenter.announcement(view) =~ "locked"
    end

    test "a missing capability defaults to locked rather than exposing snapshots" do
      view = Presenter.present(%{}, %{codex: healthy(:codex)})
      assert view.state == :locked
      assert view.cards == []
    end
  end

  describe "authorized composition" do
    test "renders one card per registry provider in registry order" do
      view = Presenter.present(authorized(), %{codex: healthy(:codex), claude: healthy(:claude)})

      assert view.state == :authorized
      assert Enum.map(view.cards, & &1.provider) == [:codex, :claude, :kimi, :deepseek, :openrouter, :fake]
      assert Enum.map(view.cards, & &1.provider_label) == ["Codex", "Claude", "Kimi", "DeepSeek", "OpenRouter", "Fake"]
    end

    test "names the generic transport backend" do
      snapshot = %{healthy(:deepseek) | backend: :openai_compat}
      view = Presenter.present(authorized(), %{deepseek: snapshot})

      assert Enum.find(view.cards, &(&1.provider == :deepseek)).backend_label == "OpenAI-compatible API"
    end

    test "a provider with no loaded snapshot renders loading without affecting the other card" do
      view = Presenter.present(authorized(), %{codex: healthy(:codex), claude: nil})

      assert card(view, :codex).state == :healthy
      assert card(view, :claude).state == :loading
    end
  end

  describe "identity-scoped facts (never borrow a tier or quota)" do
    test "a healthy known identity attaches auth mode, plan tier, and account generation" do
      view = Presenter.present(authorized(), %{codex: healthy(:codex, auth_mode: :subscription, tier: :pro)})
      codex = card(view, :codex)

      assert codex.state == :healthy
      assert codex.auth_mode.value == :subscription
      assert codex.auth_mode.label == "Subscription"
      assert codex.plan.state == :known
      assert codex.plan.tier == :pro
      assert codex.plan.tier_label == "Pro"
      assert codex.identity.state == :known
      assert is_binary(codex.identity.generation_label)
    end

    test "an api-key account is named as such" do
      view = Presenter.present(authorized(), %{codex: healthy(:codex, auth_mode: :api_key)})
      assert card(view, :codex).auth_mode.value == :api_key
      assert card(view, :codex).auth_mode.label == "API key"
    end

    test "an unknown identity never borrows a tier or auth mode even if the struct carries them" do
      # A snapshot with no known generation but a stray plan/auth_mode must stay explicit.
      snapshot = %ProviderMeterSnapshot{
        provider: :codex,
        backend: :app_server,
        provider_account_generation: nil,
        auth_mode: :subscription,
        plan: %{tier: :enterprise, source: :provider},
        health: %{state: :unavailable, failure: :unknown_account_generation, last_observed_at: nil, last_source_version: nil}
      }

      codex = card(Presenter.present(authorized(), %{codex: snapshot}), :codex)

      assert codex.state == :unknown
      assert codex.plan.state == :none
      assert codex.plan.tier == nil
      assert codex.auth_mode.value == :unknown
      assert codex.identity.state == :unknown
      assert codex.windows == []
      refute inspect(codex) =~ "Enterprise"
    end

    test "a rotated account renders a different account generation label" do
      first = card(Presenter.present(authorized(), %{codex: healthy(:codex, generation: "gen-first")}), :codex)
      second = card(Presenter.present(authorized(), %{codex: healthy(:codex, generation: "gen-second")}), :codex)

      assert first.identity.generation_label != second.identity.generation_label
    end
  end

  describe "provider and window health states are distinct" do
    test "loading: awaiting first observation for a known generation" do
      snapshot = ProviderMeterSnapshot.empty(:codex, :app_server, "gen-codex")
      assert card(Presenter.present(authorized(), %{codex: snapshot}), :codex).state == :loading
    end

    test "unknown: unresolvable account generation" do
      snapshot = ProviderMeterSnapshot.unknown(:codex, :app_server)
      assert card(Presenter.present(authorized(), %{codex: snapshot}), :codex).state == :unknown
    end

    test "partial: mixed window freshness" do
      snapshot = healthy(:codex) |> Map.put(:health, health(:partial)) |> Map.put(:freshness, :partial)
      assert card(Presenter.present(authorized(), %{codex: snapshot}), :codex).state == :partial
    end

    test "stale last-known-good retains windows after a refresh failure" do
      snapshot = healthy(:codex) |> Map.put(:health, health(:stale, :transport))
      codex = card(Presenter.present(authorized(), %{codex: snapshot}), :codex)

      assert codex.state == :stale
      assert codex.windows != []
      assert codex.health.failure == :transport
    end

    test "hard error: first-observation failure with no retained windows" do
      snapshot = %ProviderMeterSnapshot{
        provider: :codex,
        backend: :app_server,
        provider_account_generation: "gen-codex",
        health: health(:stale, :authentication),
        windows: %{}
      }

      codex = card(Presenter.present(authorized(), %{codex: snapshot}), :codex)
      assert codex.state == :error
      assert codex.windows == []
      assert codex.health.failure_label == "Authentication failed"
    end

    # The two are rendered distinctly on purpose: a generic label is what let a
    # crash in our own percentage arithmetic read as a multi-day provider
    # outage. Both may still render unhealthy; the reason must not be the same
    # sentence.
    test "a probe crash is labelled apart from a probe that could not read the provider" do
      labels =
        for failure <- [:probe_crashed, :probe_failed] do
          snapshot = healthy(:deepseek) |> Map.put(:health, health(:stale, failure))
          card(Presenter.present(authorized(), %{deepseek: snapshot}), :deepseek).health.failure_label
        end

      assert [crashed, failed] = labels
      assert crashed == "Meter probe crashed"
      assert crashed != failed
      refute failed == nil
    end
  end

  describe "credential absence is awaiting observation, not a hard failure" do
    # A missing DeepSeek/OpenRouter API key, a missing credentials file, or a
    # malformed credential blob means the provider cannot be read *yet* — not
    # that it is broken. These render as loading, matching a first observation
    # that has not arrived, rather than a misleading hard "unavailable".
    test "a missing or malformed credential blob renders loading" do
      for failure <- [:no_credentials, :malformed_credentials] do
        snapshot = %ProviderMeterSnapshot{
          provider: :claude,
          backend: :app_server,
          provider_account_generation: nil,
          health: %{state: :unavailable, failure: failure, last_observed_at: nil, last_source_version: nil}
        }

        assert card(Presenter.present(authorized(), %{claude: snapshot}), :claude).state == :loading,
               "expected #{inspect(failure)} to render loading, got a hard state"
      end
    end

    test "a missing API key or disabled provider renders loading" do
      for failure <- [:missing_api_key, :missing_api_key_configuration, :disabled] do
        snapshot = %ProviderMeterSnapshot{
          provider: :deepseek,
          backend: :openai_compat,
          provider_account_generation: nil,
          health: %{state: :unavailable, failure: failure, last_observed_at: nil, last_source_version: nil}
        }

        assert card(Presenter.present(authorized(), %{deepseek: snapshot}), :deepseek).state == :loading,
               "expected #{inspect(failure)} to render loading, got a hard state"
      end
    end

    # An absent, empty, or expired Claude OAuth token is a stable "not signed
    # in" state, not a transient "loading" one: no observation will ever arrive
    # until the operator signs in to Claude Code.
    test "an absent or expired Claude OAuth token renders an honest not-signed-in state" do
      for failure <- [:no_oauth_token, :token_expired] do
        snapshot = %ProviderMeterSnapshot{
          provider: :claude,
          backend: :app_server,
          provider_account_generation: nil,
          health: %{state: :unavailable, failure: failure, last_observed_at: nil, last_source_version: nil}
        }

        claude = card(Presenter.present(authorized(), %{claude: snapshot}), :claude)

        assert claude.state == :signed_out,
               "expected #{inspect(failure)} to render not-signed-in, got #{inspect(claude.state)}"

        assert claude.status_label == "Not signed in"
        assert claude.health.failure_label in ["No OAuth token", "OAuth token expired"]
      end
    end

    test "a real authentication failure still renders a hard state" do
      snapshot = %ProviderMeterSnapshot{
        provider: :deepseek,
        backend: :openai_compat,
        provider_account_generation: nil,
        health: %{state: :unavailable, failure: :authentication, last_observed_at: nil, last_source_version: nil}
      }

      assert card(Presenter.present(authorized(), %{deepseek: snapshot}), :deepseek).state == :unavailable
    end
  end

  describe "meter windows: coverage, standing, resets, zero" do
    test "a supported window exposes an exact semantic meter value" do
      window = window(used_percent: 40, remaining_percent: 60, coverage: :supported, standing: :allowed, resets_at: @reset)
      codex = card(Presenter.present(authorized(), %{codex: with_windows(:codex, %{"primary" => window})}), :codex)
      [meter] = codex.windows

      assert meter.coverage == :supported
      assert meter.meter == %{kind: :exact, now: 40, min: 0, max: 100}
      assert meter.standing_label == "Allowed"
      assert meter.resets_at == @reset
    end

    test "zero usage is an exact value distinct from unknown" do
      window = window(used_percent: 0, remaining_percent: 100, coverage: :supported)
      [meter] = card(Presenter.present(authorized(), %{codex: with_windows(:codex, %{"z" => window})}), :codex).windows
      assert meter.meter == %{kind: :exact, now: 0, min: 0, max: 100}
    end

    test "unsupported and empty-supported windows carry no meter value and stay distinct" do
      unsupported = window(coverage: :unsupported, standing: nil, used_percent: nil)
      empty = window(coverage: :empty_supported, standing: nil, used_percent: nil)

      windows =
        card(Presenter.present(authorized(), %{codex: with_windows(:codex, %{"u" => unsupported, "e" => empty})}), :codex).windows

      by_coverage = Map.new(windows, &{&1.coverage, &1})
      assert by_coverage[:unsupported].meter == %{kind: :none}
      assert by_coverage[:unsupported].coverage_label == "Not supported"
      assert by_coverage[:empty_supported].meter == %{kind: :none}
      assert by_coverage[:empty_supported].coverage_label == "Supported, no data reported"
    end

    test "credit and spend-control windows name their status" do
      credit = window(kind: :credit, name: "Credits", coverage: :supported, used_percent: nil, credits: %{status: :exhausted, amount: 0})
      spend = window(kind: :spend_control, name: "Spend control", coverage: :supported, used_percent: nil, spend_control: %{status: :enabled, limit: 100})

      windows = card(Presenter.present(authorized(), %{codex: with_windows(:codex, %{"c" => credit, "s" => spend})}), :codex).windows
      by_kind = Map.new(windows, &{&1.kind, &1})

      assert by_kind[:credit].credits.label == "Exhausted"
      assert by_kind[:credit].credits.amount == 0
      assert by_kind[:spend_control].spend_control.label == "Enabled"

      # A prepaid provider reports dollars, not a consumed fraction. A supported
      # window carrying no used_percent must render as no meter at all: showing
      # it as "0% used" reads as full headroom when the truth is unknown (#1436).
      assert by_kind[:credit].meter == %{kind: :none}
      assert by_kind[:spend_control].meter == %{kind: :none}
    end

    test "windows sort deterministically by kind then name" do
      windows = %{
        "s" => window(kind: :spend_control, name: "Spend control"),
        "c" => window(kind: :credit, name: "Credits"),
        "b" => window(kind: :rate_limit, name: "Secondary"),
        "a" => window(kind: :rate_limit, name: "Primary")
      }

      order = card(Presenter.present(authorized(), %{codex: with_windows(:codex, windows)}), :codex).windows |> Enum.map(& &1.name)
      assert order == ["Primary", "Secondary", "Credits", "Spend control"]
    end

    # Claude reports a five-hour session window and a set of weekly windows.
    # The session window resets every few hours, so on its own it is close to
    # no planning signal; the weekly standing is what an operator budgets a day
    # against, and it must lead the card. Ordering keys off the declared
    # priority, so it survives a renamed label or a changed reset time.
    test "a window's declared priority leads its same-kind peers" do
      windows = %{
        "five_hour" => window(kind: :rate_limit, name: "Session (5-hour)", priority: 3),
        "seven_day" => window(kind: :rate_limit, name: "Weekly (all models)", priority: 0),
        "seven_day_opus" => window(kind: :rate_limit, name: "Weekly (Opus)", priority: 1)
      }

      order =
        Presenter.present(authorized(), %{codex: with_windows(:codex, windows)})
        |> card(:codex)
        |> Map.fetch!(:windows)
        |> Enum.map(& &1.limit_id)

      assert order == ["seven_day", "seven_day_opus", "five_hour"]
    end

    test "windows without a declared priority keep their name ordering" do
      windows = %{
        "b" => window(kind: :rate_limit, name: "Secondary"),
        "a" => window(kind: :rate_limit, name: "Primary")
      }

      order =
        Presenter.present(authorized(), %{codex: with_windows(:codex, windows)})
        |> card(:codex)
        |> Map.fetch!(:windows)
        |> Enum.map(& &1.name)

      assert order == ["Primary", "Secondary"]
    end

    # A surface must be able to name a credit window's age ("as of HH:MM") and
    # its freshness horizon, so the presenter carries both timestamps through.
    test "a window exposes its observed_at and expires_at timestamps" do
      expires_at = DateTime.add(@observed, 300, :second)

      credit =
        window(kind: :credit, name: "Credits", coverage: :supported, used_percent: nil, credits: %{status: :available, amount: 7.25})
        |> Map.put(:observed_at, @observed)
        |> Map.put(:expires_at, expires_at)

      [view] = card(Presenter.present(authorized(), %{codex: with_windows(:codex, %{"c" => credit})}), :codex).windows
      assert view.observed_at == @observed
      assert view.expires_at == expires_at
    end
  end

  describe "announcements" do
    test "distinct, bounded sentences per provider state" do
      view =
        Presenter.present(authorized(), %{
          codex: healthy(:codex, tier: :pro),
          claude: ProviderMeterSnapshot.unknown(:claude, :app_server)
        })

      announcement = Presenter.announcement(view)
      assert announcement =~ "Codex: healthy"
      assert announcement =~ "Pro plan"
      assert announcement =~ "Claude: no plan or quota available"
    end
  end

  # --- fixtures ------------------------------------------------------------

  defp authorized, do: %{state: :authorized, version: 1}

  defp card(view, provider), do: Enum.find(view.cards, &(&1.provider == provider))

  defp healthy(provider, opts \\ []) do
    %ProviderMeterSnapshot{
      provider: provider,
      backend: :app_server,
      provider_account_generation: Keyword.get(opts, :generation, "gen-#{provider}"),
      auth_mode: Keyword.get(opts, :auth_mode, :subscription),
      plan: %{tier: Keyword.get(opts, :tier, :pro), source: :provider, observed_at: @observed, freshness: :fresh},
      observed_at: @observed,
      ingested_at: @observed,
      freshness: :fresh,
      health: health(:healthy),
      windows: %{"primary" => window(used_percent: 40, remaining_percent: 60, coverage: :supported, standing: :allowed, resets_at: @reset)}
    }
  end

  defp with_windows(provider, windows), do: %{healthy(provider) | windows: windows}

  defp window(opts) do
    %{
      kind: Keyword.get(opts, :kind, :rate_limit),
      name: Keyword.get(opts, :name, "Primary"),
      standing: Keyword.get(opts, :standing, :allowed),
      used_percent: Keyword.get(opts, :used_percent, 40),
      remaining_percent: Keyword.get(opts, :remaining_percent, 60),
      coverage: Keyword.get(opts, :coverage, :supported),
      priority: Keyword.get(opts, :priority),
      freshness: Keyword.get(opts, :freshness, :fresh),
      source: :codex_app_server
    }
    |> maybe_put(:resets_at, Keyword.get(opts, :resets_at))
    |> maybe_put(:credits, Keyword.get(opts, :credits))
    |> maybe_put(:spend_control, Keyword.get(opts, :spend_control))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp health(:healthy), do: %{state: :healthy, failure: nil, last_observed_at: @observed, last_source_version: 1}
  defp health(:partial), do: %{state: :partial, failure: nil, last_observed_at: @observed, last_source_version: 1}

  defp health(:stale, failure), do: %{state: :stale, failure: failure, last_observed_at: @observed, last_source_version: 1}
end
