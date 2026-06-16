defmodule AiurEngineTest do
  use ExUnit.Case, async: true

  @engine Path.expand("../../packaging/npm/aiur-cli/libexec/aiur-engine.sh", __DIR__)

  # Run the engine's `__identity` probe with a clean AIUR_* env plus the given
  # overrides, returning the resolved KEY=VALUE map.
  defp identity(overrides) do
    base = [
      {"USER", "tester"},
      {"AIUR_BG_STATE_DIR", nil},
      {"AIUR_SESSION_PREFIX", nil},
      {"AIUR_PROFILES_FILE", nil},
      {"AIUR_RELEASE_NODE", nil},
      {"AIUR_COOKIE_FILE", nil},
      {"AIUR_RELEASE_DIR", nil}
    ]

    env = base ++ overrides

    {out, 0} = System.cmd(@engine, ["__identity"], env: env, stderr_to_stdout: true)

    out
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [k, v] = String.split(line, "=", parts: 2)
      {k, v}
    end)
  end

  test "resolves the single aiur identity" do
    id = identity([])

    assert id["AIUR_SESSION_PREFIX"] == "aiur"
    assert id["AIUR_RELEASE_NODE"] == "aiur-tester@127.0.0.1"
    assert id["AIUR_BG_STATE_DIR"] =~ ~r{/\.config/aiur$}
    assert id["AIUR_COOKIE_FILE"] =~ ~r{/\.config/aiur/cookie$}
  end

  test "the state dir is redirectable so tests need not touch ~/.config/aiur" do
    id = identity([{"AIUR_BG_STATE_DIR", "/tmp/aiur-test-state"}])

    assert id["AIUR_BG_STATE_DIR"] == "/tmp/aiur-test-state"
    assert id["AIUR_COOKIE_FILE"] == "/tmp/aiur-test-state/cookie"
    # naming stays the fixed aiur identity regardless of state dir
    assert id["AIUR_RELEASE_NODE"] == "aiur-tester@127.0.0.1"
  end
end
