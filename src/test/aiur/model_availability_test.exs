defmodule Aiur.ModelAvailabilityTest do
  use ExUnit.Case, async: true

  alias Aiur.Config.Schema.Agent
  alias Aiur.ModelAvailability

  setup do
    path = Path.join(System.tmp_dir!(), "aiur-model-usage-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  test "persists hourly, weekly, and monthly windows with reset times", %{path: path} do
    reset = DateTime.add(DateTime.utc_now(), 3_600, :second) |> DateTime.to_iso8601()

    assert :ok =
             ModelAvailability.observe(
               "codex",
               %{
                 hourly: %{used: 10, limit: 10, reset_at: reset},
                 weekly: %{used: 4, limit: 20, reset_at: reset},
                 monthly: %{used: 5, limit: 100, reset_at: reset}
               },
               path: path
             )

    assert %{"backends" => %{"codex" => %{"hourly" => %{"used" => 10, "reset_at" => ^reset}}}} = ModelAvailability.load(path)
    refute ModelAvailability.available?("codex", path: path)
  end

  test "normalizes provider primary and secondary windows", %{path: path} do
    reset = DateTime.add(DateTime.utc_now(), 3_600, :second) |> DateTime.to_iso8601()

    assert :ok =
             ModelAvailability.observe(
               "codex",
               %{
                 primary: %{usedPercent: 100, windowDurationMins: 60, resetsAt: reset},
                 secondary: %{usedPercent: 20, windowDurationMins: 10_080, resetsAt: reset}
               },
               path: path
             )

    assert %{"backends" => %{"codex" => %{"hourly" => %{"used" => 100, "limit" => 100}, "weekly" => %{"used" => 20}}}} = ModelAvailability.load(path)
  end

  test "restores availability after the limiting reset", %{path: path} do
    past = DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.to_iso8601()
    assert :ok = ModelAvailability.mark_limited("claude", past, path: path)
    assert ModelAvailability.available?("claude", path: path)
  end

  test "chooses the first available backend in configured priority", %{path: path} do
    future = DateTime.add(DateTime.utc_now(), 3_600, :second) |> DateTime.to_iso8601()
    assert :ok = ModelAvailability.mark_limited("claude", future, path: path)
    assert ModelAvailability.first_available(["claude", "codex", "claude-repl"], path: path) == "codex"
  end

  test "validates fallback backend configuration" do
    valid = Agent.changeset(%Agent{}, %{"switch_model_on_ratelimit" => ["claude", "codex"]})
    assert valid.valid?

    duplicate = Agent.changeset(%Agent{}, %{"switch_model_on_ratelimit" => ["codex", "codex"]})
    refute duplicate.valid?

    unknown = Agent.changeset(%Agent{}, %{"switch_model_on_ratelimit" => ["unknown"]})
    refute unknown.valid?
  end

  test "fails open for unreadable state and unsupported provider payloads", %{path: path} do
    File.write!(path, "not json")
    assert %{"backends" => %{}} = ModelAvailability.load(path)
    assert ModelAvailability.available?("codex", path: path)

    assert :ok = ModelAvailability.observe("codex", nil, path: path)
    assert ModelAvailability.available?("codex", path: path)
  end

  test "an explicit limit without a reset remains unavailable", %{path: path} do
    assert :ok = ModelAvailability.mark_limited("codex", nil, path: path)
    refute ModelAvailability.available?("codex", path: path)
  end

  test "a past usage-window reset restores availability", %{path: path} do
    reset = DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.to_iso8601()

    assert :ok =
             ModelAvailability.observe(
               "codex",
               %{monthly: %{used: 100, limit: 100, reset_at: reset}},
               path: path
             )

    assert ModelAvailability.available?("codex", path: path)
  end
end
