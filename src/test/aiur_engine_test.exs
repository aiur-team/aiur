defmodule AiurEngineTest do
  use ExUnit.Case, async: true

  @engine Path.expand("../../packaging/npm/aiur-cli/libexec/aiur-engine.sh", __DIR__)

  # Run the engine's `__identity` probe with a clean AIUR_* env plus the given
  # overrides, returning the resolved KEY=VALUE map.
  defp identity(overrides) do
    base = [
      {"USER", "tester"},
      {"AIUR_NODE_PREFIX", nil},
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

  test "defaults to the installed aiur identity when nothing is set" do
    id = identity([])

    assert id["AIUR_NODE_PREFIX"] == "aiur"
    assert id["AIUR_SESSION_PREFIX"] == "aiur"
    assert id["AIUR_RELEASE_NODE"] == "aiur-tester@127.0.0.1"
    assert id["AIUR_BG_STATE_DIR"] =~ ~r{/\.config/aiur$}
    assert id["AIUR_COOKIE_FILE"] =~ ~r{/\.config/aiur/cookie$}
  end

  test "honors the aiurdev identity overrides without a rename in the engine" do
    id =
      identity([
        {"AIUR_NODE_PREFIX", "aiurdev"},
        {"AIUR_BG_STATE_DIR", "/tmp/state/aiurdev"},
        {"AIUR_PROFILES_FILE", "/tmp/cfg/aiurdev.profiles"}
      ])

    assert id["AIUR_RELEASE_NODE"] == "aiurdev-tester@127.0.0.1"
    assert id["AIUR_SESSION_PREFIX"] == "aiurdev"
    assert id["AIUR_COOKIE_FILE"] == "/tmp/state/aiurdev/cookie"
    assert id["AIUR_PROFILES_FILE"] == "/tmp/cfg/aiurdev.profiles"
  end

  test "an explicit AIUR_RELEASE_NODE wins over the prefix default" do
    id = identity([{"AIUR_NODE_PREFIX", "aiurdev"}, {"AIUR_RELEASE_NODE", "custom-node@127.0.0.1"}])

    assert id["AIUR_RELEASE_NODE"] == "custom-node@127.0.0.1"
  end
end
