defmodule Aiur.GitHubUsageCLITest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.GitHubUsageCLI

  @now ~U[2026-08-17 12:00:00Z]

  test "builds a per-actor envelope with core and graphql figures" do
    assert {:ok, envelope} = GitHubUsageCLI.build(usage_fun: fn -> snapshot() end, now: @now)

    assert envelope["schema_version"] == 1
    assert envelope["page"] == "github-usage"

    [daemon, agent] = envelope["data"]["actors"]
    assert daemon["actor"] == "daemon:nonode@nohost"
    assert daemon["core"]["used"] == 1200
    assert daemon["core"]["limit"] == 3000
    assert daemon["graphql"]["used"] == 340
    assert daemon["graphql"]["limit"] == 2000

    assert agent["actor"] == "workspace:/agents/42"
    assert agent["core"]["used"] == 45
    assert agent["core"]["limit"] == 1000
    assert agent["graphql"]["used"] == 12
    assert agent["graphql"]["limit"] == 500
  end

  test "prints per-actor used/limit and reset times" do
    output = capture_io(fn -> assert 0 == GitHubUsageCLI.run(usage_fun: fn -> snapshot() end, now: @now) end)

    assert output =~ "daemon:nonode@nohost"
    assert output =~ "core    1200/3000"
    assert output =~ "graphql 340/2000"
    assert output =~ "workspace:/agents/42"
    assert output =~ "core    45/1000"
    assert output =~ "graphql 12/500"
    assert output =~ "resets in"
  end

  test "marks an actor at its ceiling" do
    at_ceiling = %{
      actors: [
        %{
          token_key: "tok",
          consumer_key: "daemonfp",
          consumer_label: "daemon:nonode@nohost",
          core: %{used: 3000, limit: 3000, reset_at_ms: now_ms() + 3_599_000},
          graphql: %{used: 340, limit: 2000, reset_at_ms: now_ms() + 1_800_000}
        }
      ]
    }

    output = capture_io(fn -> assert 0 == GitHubUsageCLI.run(usage_fun: fn -> at_ceiling end, now: @now) end)

    assert output =~ "3000/3000 (at ceiling)"
  end

  test "an unobserved broker reports nothing observed, never zero" do
    output = capture_io(fn -> assert 0 == GitHubUsageCLI.run(usage_fun: fn -> %{actors: []} end, now: @now) end)

    assert output =~ "No GitHub usage has been observed"
  end

  test "survives a broker that is not running" do
    assert {:error, message} = GitHubUsageCLI.build(usage_fun: fn -> exit(:noproc) end)
    assert message =~ "not running"
  end

  test "rejects an unusable broker result" do
    assert {:error, message} = GitHubUsageCLI.build(usage_fun: fn -> :unavailable end)
    assert message =~ "could not read the GitHub usage broker"
  end

  test "emits a machine-readable envelope under --json" do
    output = capture_io(fn -> assert 0 == GitHubUsageCLI.run(usage_fun: fn -> snapshot() end, now: @now, json: true) end)

    decoded = Jason.decode!(output)

    assert decoded["schema_version"] == 1
    assert decoded["page"] == "github-usage"
    assert [daemon | _] = decoded["data"]["actors"]
    assert daemon["core"]["used"] == 1200
  end

  defp snapshot do
    %{
      actors: [
        %{
          token_key: "tok",
          consumer_key: "daemonfp",
          consumer_label: "daemon:nonode@nohost",
          core: %{used: 1200, limit: 3000, reset_at_ms: now_ms() + 3_000_000},
          graphql: %{used: 340, limit: 2000, reset_at_ms: now_ms() + 1_800_000}
        },
        %{
          token_key: "tok",
          consumer_key: "agentfp",
          consumer_label: "workspace:/agents/42",
          core: %{used: 45, limit: 1000, reset_at_ms: now_ms() + 2_400_000},
          graphql: %{used: 12, limit: 500, reset_at_ms: now_ms() + 600_000}
        }
      ]
    }
  end

  defp now_ms, do: DateTime.to_unix(@now, :millisecond)
end
