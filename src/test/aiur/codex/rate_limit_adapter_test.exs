defmodule Aiur.Codex.RateLimitAdapterTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Aiur.Codex.RateLimitAdapter
  alias Aiur.ProviderMeters.{Input, Reconciler}

  @observed_at ~U[2026-07-16 19:00:00Z]

  test "normalizes the installed v2 full response with arbitrary limit IDs" do
    response = fixture!("rate_limits_v2_0_144_4.json")

    assert {:ok, update} = RateLimitAdapter.snapshot(response, make_ref(), :subscription, @observed_at)
    assert {:ok, normalized} = Input.normalize(update)

    assert normalized.update_kind == :snapshot
    assert normalized.auth_mode == :subscription
    assert normalized.plan.tier == :business
    assert normalized.windows["codex:primary"].used_percent == 25
    assert normalized.windows["codex:primary"].remaining_percent == 75
    assert normalized.windows["codex:primary"].expires_at == normalized.windows["codex:primary"].resets_at
    assert normalized.windows["gpt-5:primary"].duration_minutes == 60
    assert normalized.windows["codex:credits"].credits.status == :available
    assert normalized.windows["gpt-5:credits"].credits.status == :exhausted
    assert normalized.windows["codex:spend-control"].spend_control.status == :enabled
    assert normalized.windows["codex:spend-control"].remaining_percent == 85
    assert normalized.windows["codex:spend-control"].resets_at == ~U[2026-08-16 00:00:00Z]
    assert normalized.windows["codex:spend-control"].expires_at == ~U[2026-08-16 00:00:00Z]
    assert normalized.windows["reset-credits"].credits == %{status: :available, amount: 2}
  end

  test "rate and spend facts become stale at their provider reset boundary" do
    reset_at = DateTime.add(@observed_at, 60, :second)

    response = %{
      "rateLimits" => %{
        "limitId" => "codex",
        "primary" => %{"usedPercent" => 25, "resetsAt" => DateTime.to_unix(reset_at)},
        "individualLimit" => %{
          "used" => "1.00",
          "limit" => "2.00",
          "remainingPercent" => 50,
          "resetsAt" => DateTime.to_unix(reset_at)
        }
      },
      "rateLimitsByLimitId" => nil,
      "rateLimitResetCredits" => nil
    }

    assert {:ok, update} = RateLimitAdapter.snapshot(response, make_ref(), :subscription, @observed_at)
    assert {:ok, normalized} = Input.normalize(update)

    normalized =
      normalized
      |> Map.delete(:account_generation_binding)
      |> Map.put(:provider_account_generation, "generation")

    assert {:updated, fresh} = Reconciler.apply(nil, normalized, @observed_at)
    assert fresh.freshness == :fresh

    expired = Reconciler.refresh(fresh, DateTime.add(reset_at, 1, :second))
    assert expired.windows["codex:primary"].freshness == :stale
    assert expired.windows["codex:spend-control"].freshness == :stale
    assert expired.freshness == :stale
    assert expired.health.state == :stale
  end

  test "maps API-key mode without fabricating plan or monetary balances" do
    response = %{
      "rateLimits" => %{
        "limitId" => "api",
        "primary" => %{"usedPercent" => 20, "windowDurationMins" => 60, "resetsAt" => 1_784_246_400},
        "credits" => %{"hasCredits" => true, "unlimited" => false, "balance" => "secret-money"}
      },
      "rateLimitsByLimitId" => nil,
      "rateLimitResetCredits" => nil
    }

    assert {:ok, update} = RateLimitAdapter.snapshot(response, make_ref(), :api_key, @observed_at)
    assert {:ok, normalized} = Input.normalize(update)

    assert normalized.auth_mode == :api_key
    assert normalized.plan == nil
    assert normalized.windows["api:credits"].credits == %{status: :available}
    refute inspect(normalized) =~ "secret-money"
  end

  test "treats notifications as sparse patches and ignores nullable fields" do
    patch = %{
      "limitId" => "codex",
      "planType" => nil,
      "primary" => %{"usedPercent" => 80},
      "secondary" => nil,
      "credits" => nil,
      "individualLimit" => nil
    }

    assert {:ok, update} = RateLimitAdapter.patch(patch, make_ref(), :subscription, @observed_at)
    assert {:ok, normalized} = Input.normalize(update)

    assert normalized.update_kind == :patch
    assert normalized.plan == nil
    assert Map.keys(normalized.windows) == ["codex:primary"]
    assert normalized.windows["codex:primary"].used_percent == 80
  end

  test "does not turn nullable sparse fields into tombstones" do
    patch = %{"limitId" => "codex", "primary" => nil, "secondary" => nil, "credits" => nil}

    assert :ignore = RateLimitAdapter.patch(patch, make_ref(), :subscription, @observed_at)
  end

  test "uses an unkeyed sparse patch only after a full snapshot identifies one bucket" do
    patch = %{"primary" => %{"usedPercent" => 20}}

    assert :ambiguous_limit_id = RateLimitAdapter.patch(patch, make_ref(), :subscription, @observed_at)

    assert {:ok, update} =
             RateLimitAdapter.patch(patch, make_ref(), :subscription, @observed_at, single_limit_id: "default")

    assert {:ok, normalized} = Input.normalize(update)
    assert normalized.windows["default:primary"].used_percent == 20
  end

  test "normalizes an unkeyed plan-only patch without fabricating a limit ID" do
    patch = %{"limitId" => nil, "planType" => "plus"}

    assert {:ok, update} = RateLimitAdapter.patch(patch, make_ref(), :subscription, @observed_at)
    assert {:ok, normalized} = Input.normalize(update)
    assert normalized.plan.tier == :pro
    assert normalized.windows == %{}
  end

  test "normalizes a compatible v2 response without claiming its binary version" do
    response = fixture!("rate_limits_v2_compatible.json")

    assert {:ok, update} = RateLimitAdapter.snapshot(response, make_ref(), :subscription, @observed_at)
    assert {:ok, normalized} = Input.normalize(update)

    assert normalized.windows["default:primary"].used_percent == 50
    assert normalized.source_version == 144_004
    refute inspect(normalized) =~ "future-only"
  end

  test "a full snapshot removes omitted windows through the existing reconciliation contract" do
    first = %{
      "rateLimits" => %{
        "limitId" => "codex",
        "primary" => %{"usedPercent" => 30},
        "secondary" => %{"usedPercent" => 40}
      },
      "rateLimitsByLimitId" => nil,
      "rateLimitResetCredits" => nil
    }

    replacement = put_in(first, ["rateLimits", "secondary"], nil)

    assert {:ok, first_update} = RateLimitAdapter.snapshot(first, make_ref(), :subscription, @observed_at)
    assert {:ok, replacement_update} = RateLimitAdapter.snapshot(replacement, make_ref(), :subscription, @observed_at)
    assert Enum.map(first_update.windows, & &1.limit_id) |> Enum.sort() == ["codex:primary", "codex:secondary"]
    assert Enum.map(replacement_update.windows, & &1.limit_id) == ["codex:primary"]
  end

  test "rejects malformed source fields and returns typed failures without source content" do
    oversized_id = String.duplicate("x", 1_025)
    oversized_response = %{"rateLimits" => %{"limitId" => oversized_id}}

    assert {:error, :malformed} =
             RateLimitAdapter.snapshot(oversized_response, make_ref(), :subscription, @observed_at)

    assert {:error, :malformed} = RateLimitAdapter.patch(%{"limitId" => oversized_id}, make_ref(), :subscription, @observed_at)

    failure = RateLimitAdapter.failure(make_ref(), :response_timeout, @observed_at)
    assert failure.reason == :timeout
    refute Map.has_key?(failure, :raw_response)
  end

  test "rejects protocol drift instead of replacing a snapshot with unknown facts" do
    unknown_only = %{
      "rateLimits" => %{"newWindowType" => %{"value" => 1}},
      "rateLimitsByLimitId" => nil,
      "rateLimitResetCredits" => nil
    }

    invalid_multi_bucket = %{
      "rateLimits" => %{"primary" => %{"usedPercent" => 10}},
      "rateLimitsByLimitId" => ["not-a-map"],
      "rateLimitResetCredits" => nil
    }

    assert {:error, :malformed} = RateLimitAdapter.snapshot(unknown_only, make_ref(), :subscription, @observed_at)

    assert {:error, :malformed} =
             RateLimitAdapter.snapshot(invalid_multi_bucket, make_ref(), :subscription, @observed_at)

    mismatched_id = %{
      "rateLimits" => %{"primary" => %{"usedPercent" => 10}},
      "rateLimitsByLimitId" => %{"codex" => %{"limitId" => "gpt-5", "primary" => %{"usedPercent" => 10}}},
      "rateLimitResetCredits" => nil
    }

    assert {:error, :malformed} = RateLimitAdapter.snapshot(mismatched_id, make_ref(), :subscription, @observed_at)
  end

  test "rejects malformed or conflicting plan facts across limit buckets" do
    response = %{
      "rateLimits" => %{"planType" => "business"},
      "rateLimitsByLimitId" => %{
        "codex" => %{"planType" => "business", "primary" => %{"usedPercent" => 10}},
        "gpt-5" => %{"planType" => "enterprise", "primary" => %{"usedPercent" => 20}}
      },
      "rateLimitResetCredits" => nil
    }

    assert {:error, :malformed} = RateLimitAdapter.snapshot(response, make_ref(), :subscription, @observed_at)

    compatible = put_in(response, ["rateLimitsByLimitId", "gpt-5", "planType"], "self_serve_business_usage_based")

    assert {:ok, %{plan: %{tier: :business}}} =
             RateLimitAdapter.snapshot(compatible, make_ref(), :subscription, @observed_at)

    malformed = put_in(response, ["rateLimitsByLimitId", "gpt-5", "planType"], %{raw: "enterprise"})
    assert {:error, :malformed} = RateLimitAdapter.snapshot(malformed, make_ref(), :subscription, @observed_at)
  end

  test "drops account and capability fields before projection output" do
    response = %{
      "rateLimits" => %{
        "limitId" => "codex",
        "primary" => %{"usedPercent" => 1},
        "email" => "person@example.test",
        "credential" => "secret",
        "capabilityUrl" => "https://example.test/secret"
      },
      "rateLimitsByLimitId" => nil,
      "rateLimitResetCredits" => nil,
      "account" => %{"email" => "person@example.test"}
    }

    assert {:ok, update} = RateLimitAdapter.snapshot(response, make_ref(), :subscription, @observed_at)
    refute inspect(update) =~ "person@example.test"
    refute inspect(update) =~ "secret"
  end

  test "canonicalizes unsafe arbitrary IDs without retaining their source value" do
    raw_limit_id = "workspace/\u2603/very-long-limit"

    response = %{
      "rateLimits" => %{"limitId" => raw_limit_id, "primary" => %{"usedPercent" => 1}},
      "rateLimitsByLimitId" => nil,
      "rateLimitResetCredits" => nil
    }

    assert {:ok, update} = RateLimitAdapter.snapshot(response, make_ref(), :subscription, @observed_at)
    assert {:ok, normalized} = Input.normalize(update)

    assert [limit_id] = Map.keys(normalized.windows)
    assert String.starts_with?(limit_id, "opaque-")
    refute inspect(normalized) =~ raw_limit_id
  end

  test "bounds hostile multi-limit input before projection expansion" do
    ids = Enum.map(1..33, &"limit-#{&1}")

    response = %{
      "rateLimits" => %{"primary" => %{"usedPercent" => 10}},
      "rateLimitsByLimitId" => Map.new(ids, &{&1, %{"primary" => %{"usedPercent" => 10}}}),
      "rateLimitResetCredits" => nil
    }

    assert {:error, :malformed} = RateLimitAdapter.snapshot(response, make_ref(), :subscription, @observed_at)
  end

  property "preserves arbitrary supported limit IDs from the multi-bucket response" do
    check all(
            ids <- uniq_list_of(string(:alphanumeric, min_length: 1, max_length: 20), min_length: 2, max_length: 8),
            max_runs: 25
          ) do
      response = %{
        "rateLimits" => %{"limitId" => hd(ids), "primary" => %{"usedPercent" => 10}},
        "rateLimitsByLimitId" =>
          Map.new(ids, fn id ->
            {id, %{"limitId" => id, "primary" => %{"usedPercent" => 10}}}
          end),
        "rateLimitResetCredits" => nil
      }

      assert {:ok, update} = RateLimitAdapter.snapshot(response, make_ref(), :subscription, @observed_at)
      assert {:ok, normalized} = Input.normalize(update)
      assert Map.keys(normalized.windows) |> MapSet.new() == Enum.map(ids, &"#{&1}:primary") |> MapSet.new()
    end
  end

  test "projects more than 32 supported windows from arbitrary multi-limit snapshots" do
    snapshot = %{
      "primary" => %{"usedPercent" => 10},
      "secondary" => %{"usedPercent" => 20},
      "credits" => %{"hasCredits" => true, "unlimited" => false},
      "individualLimit" => %{"used" => "1.00", "limit" => "2.00", "remainingPercent" => 50, "resetsAt" => 1_784_246_400}
    }

    ids = Enum.map(1..9, &"limit-#{&1}")

    response = %{
      "rateLimits" => Map.put(snapshot, "limitId", hd(ids)),
      "rateLimitsByLimitId" => Map.new(ids, &{&1, Map.put(snapshot, "limitId", &1)}),
      "rateLimitResetCredits" => nil
    }

    assert {:ok, update} = RateLimitAdapter.snapshot(response, make_ref(), :subscription, @observed_at)
    assert {:ok, normalized} = Input.normalize(update)
    assert map_size(normalized.windows) == 36
  end

  defp fixture!(name) do
    __DIR__
    |> Path.join("../../fixtures/codex/#{name}")
    |> File.read!()
    |> Jason.decode!()
  end
end
