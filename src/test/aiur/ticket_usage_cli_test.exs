defmodule Aiur.TicketUsageCLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Aiur.TestSupport.GroupedScopes, as: GS
  alias Aiur.TicketUsageCLI
  alias AiurWeb.Api.Usage.TicketUsage

  defp usage_opts do
    records = [
      GS.claude_record(1, ticket: GS.identity(5692), run_id: "run-a", tokens: %{input: 100, output: 20}),
      GS.claude_record(2, ticket: GS.identity(77), run_id: "run-a", tokens: %{input: 9_999})
    ]

    [
      scan_fun: fn options -> {:ok, Enum.filter(records, &(&1.position > Keyword.fetch!(options, :after)))} end,
      cells_snapshot_fun: fn -> GS.source(records) end,
      repository_fun: fn -> {:ok, {"its-everdred", "aiur"}} end
    ]
  end

  # The CLI promises the HTTP payload, so a client can switch transports freely.
  test "--json prints the same payload as the HTTP read" do
    output = capture_io(fn -> assert TicketUsageCLI.run("5692", json: true, usage_opts: usage_opts()) == 0 end)
    {:ok, payload} = TicketUsage.fetch("5692", usage_opts())

    assert Jason.decode!(output) == payload
  end

  test "renders per-session model and provider rows for the asked ticket only" do
    output = capture_io(fn -> assert TicketUsageCLI.run("5692", usage_opts: usage_opts()) == 0 end)

    assert output =~ "its-everdred/aiur#5692"
    assert output =~ "Session run-a"
    assert output =~ "model     claude-sonnet-4-6"
    assert output =~ "provider  claude"
    assert output =~ "input=100 output=20"
    refute output =~ "9999"
  end

  test "an unknown ticket exits 1 with a reason on stderr" do
    stderr = capture_io(:stderr, fn -> assert TicketUsageCLI.run("4242", usage_opts: usage_opts()) == 1 end)
    assert stderr =~ "ticket-usage found no usage recorded for ticket 4242"
  end

  test "renders a routed provider and a missing price" do
    payload = %{
      "ticket" => %{"owner" => "o", "repository" => "r", "identifier" => "1"},
      "state" => "partial",
      "currency" => "USD",
      "totals" => %{"tokens" => %{}, "api_equivalent" => %{"amount" => %{}}},
      "sessions" => [
        %{
          "run_id" => nil,
          "tokens" => %{"input" => 1},
          "api_equivalent" => %{"amount" => %{}},
          "by_model" => [%{"model" => nil, "tokens" => %{"input" => 1}, "api_equivalent" => %{"amount" => %{}}}],
          "by_provider" => [
            %{"provider" => "openrouter", "upstream_provider" => "deepinfra", "tokens" => %{"input" => 1}, "api_equivalent" => %{"amount" => %{}}}
          ]
        }
      ]
    }

    output = TicketUsageCLI.render(payload)
    assert output =~ "Total     $n/a  no tokens"
    assert output =~ "Session unknown"
    assert output =~ "openrouter -> deepinfra"
    assert output =~ "model     unknown"
  end
end
