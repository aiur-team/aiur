defmodule Aiur.Docs.ControlCenterFixture.MeterSource do
  @moduledoc false

  # DOCUMENTATION SAFETY BOUNDARY.
  #
  # The production `AiurWeb.OperatorControlCenter.ProviderMeterSource` reads
  # `Aiur.ProviderMeterProjection`, which is fed by `Aiur.ProviderMeterRefresh`
  # probing the operator's real Claude and Codex accounts over HTTP with
  # whatever ambient credentials the shell carries. That is live account data
  # and it must never reach a checked-in screenshot, so this fixture never
  # starts those probes and installs this stand-in through the endpoint's
  # `:provider_meter_source` seam instead. It performs no I/O and returns fixed
  # synthetic readings for both providers.

  alias Aiur.ProviderMeterSnapshot

  # Relative to the capture, not a fixed calendar date: a hard-coded reset in the
  # past renders as "reset time passed" on every card.
  defp observed_at, do: DateTime.add(DateTime.utc_now(), -720, :second)
  defp session_reset, do: DateTime.add(DateTime.utc_now(), 4_320, :second)
  defp weekly_reset, do: DateTime.add(DateTime.utc_now(), 331_200, :second)

  def subscribe(_context), do: :ok
  def load(_context, _opts \\ []), do: snapshots()
  def reload(_context, _message, _opts \\ []), do: snapshots()

  def snapshots do
    %{
      claude: snapshot(:claude, :cli, "example-account-claude", :max, 34, 58),
      codex: snapshot(:codex, :app_server, "example-account-codex", :pro, 61, 47)
    }
  end

  def streamdeck_meters do
    %{
      "claude" => %{
        "state" => "observed",
        "windows" => %{
          "session" => %{"kind" => "rate_limit", "used_percent" => 34, "remaining" => "3h 48m", "freshness" => "fresh"},
          "weekly" => %{"kind" => "rate_limit", "used_percent" => 58, "remaining" => "4d", "freshness" => "fresh"}
        }
      },
      "codex" => %{
        "state" => "observed",
        "windows" => %{
          "session" => %{"kind" => "rate_limit", "used_percent" => 61, "remaining" => "1h 12m", "freshness" => "fresh"},
          "weekly" => %{"kind" => "rate_limit", "used_percent" => 47, "remaining" => "4d", "freshness" => "fresh"}
        }
      }
    }
  end

  defp snapshot(provider, backend, generation, tier, session_used, weekly_used) do
    %ProviderMeterSnapshot{
      provider: provider,
      backend: backend,
      provider_account_generation: generation,
      projection_generation: 1,
      auth_mode: :subscription,
      plan: %{tier: tier, source: :provider, observed_at: observed_at(), freshness: :fresh},
      update_kind: :snapshot,
      observed_at: observed_at(),
      age_seconds: 12,
      ingested_at: observed_at(),
      source: :example_fixture,
      source_version: 1,
      full_snapshot_observed_at: observed_at(),
      freshness: :fresh,
      health: %{
        state: :healthy,
        failure: nil,
        last_observed_at: observed_at(),
        last_source_version: 1,
        last_attempt_at: observed_at(),
        consecutive_failures: 0
      },
      windows: %{
        "session" => window("Session", session_used, session_reset(), provider),
        "weekly" => window("Weekly", weekly_used, weekly_reset(), provider)
      }
    }
  end

  defp window(name, used_percent, resets_at, provider) do
    %{
      kind: :rate_limit,
      name: name,
      standing: :allowed,
      used_percent: used_percent,
      remaining_percent: 100 - used_percent,
      coverage: :supported,
      freshness: :fresh,
      resets_at: resets_at,
      source: provider
    }
  end
end
