defmodule Mix.Tasks.Aiur.CostReportTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Aiur.GitHub.Config
  alias Aiur.RunTelemetry.Summaries
  alias Aiur.TestSupport.UsageAggregate, as: Aggregate
  alias Aiur.TrackerIdentity
  alias Aiur.UsageAggregate.{Checkpoint, Projection}
  alias Mix.Tasks.Aiur.CostReport

  setup do
    state_dir = Path.join(System.tmp_dir!(), "aiur-cost-report-#{System.unique_integer([:positive])}")
    File.mkdir_p!(state_dir)
    on_exit(fn -> File.rm_rf(state_dir) end)
    %{state_dir: state_dir}
  end

  describe "parse_args/1" do
    test "accepts --ticket, --build, --json, --state-dir" do
      assert {:ok, parsed} = CostReport.parse_args(["--ticket", "930", "--json"])
      assert parsed.ticket == "930"
      assert parsed.json == true

      assert {:ok, parsed} = CostReport.parse_args(["--build", "analytics-optimizations"])
      assert parsed.build == "analytics-optimizations"
    end

    test "rejects unknown options and positional arguments" do
      assert {:error, message} = CostReport.parse_args(["--nope"])
      assert message =~ "unknown options"

      assert {:error, message} = CostReport.parse_args(["surprise"])
      assert message =~ "unexpected arguments"
    end

    test "--help returns the usage doc" do
      assert {:help, usage} = CostReport.parse_args(["--help"])
      assert usage =~ "cost_report"
    end
  end

  describe "ticket_identity/1" do
    test "builds a joinable GitHub identity for the tracked repository" do
      [owner, name] = String.split(Config.repo(), "/")

      assert {:ok, identity} = CostReport.ticket_identity("930")
      assert Aiur.TrackerIdentity.github_key(identity) == {:github, owner, name, "930"}
    end
  end

  describe "run/1 end to end" do
    test "--help prints the usage doc" do
      output = capture_io(fn -> assert :ok = CostReport.run(["--help"]) end)
      assert output =~ "mix aiur.cost_report"
    end

    test "rejects an unknown option" do
      assert_raise Mix.Error, ~r/unknown options/, fn ->
        CostReport.run(["--nope"])
      end
    end

    test "reports a missing checkpoint clearly", %{state_dir: state_dir} do
      assert_raise Mix.Error, ~r/no usage aggregate checkpoint/, fn ->
        CostReport.run(["--ticket", "930", "--state-dir", state_dir])
      end
    end

    test "reports a corrupt checkpoint clearly", %{state_dir: state_dir} do
      File.write!(Path.join(state_dir, "checkpoint.json"), "{not json")

      assert_raise Mix.Error, ~r/checkpoint corrupt/, fn ->
        CostReport.run(["--ticket", "930", "--state-dir", state_dir])
      end
    end

    test "prints a ticket-scoped report with token totals", %{state_dir: state_dir} do
      write_checkpoint!(state_dir, [930])

      output =
        capture_io(fn ->
          assert :ok = CostReport.run(["--ticket", "930", "--state-dir", state_dir])
        end)

      assert output =~ "ticket set (1 ticket(s))"
      assert output =~ "gpt-5.6-terra"
      assert output =~ "1000000 tokens"
      assert output =~ "Spend by model:"
      assert output =~ "Spend by agent family:"
      assert output =~ "Spend by ticket:"
    end

    test "--json emits a machine-readable snapshot", %{state_dir: state_dir} do
      write_checkpoint!(state_dir, [930])

      output =
        capture_io(fn ->
          assert :ok = CostReport.run(["--ticket", "930", "--state-dir", state_dir, "--json"])
        end)

      decoded = Jason.decode!(output)
      assert decoded["scope"]["kind"] == "explicit_ticket_set"
      assert decoded["currency"] == "USD"
      assert decoded["contributors"]["by_ticket"] != []
    end

    test "defaults to the current run and renders empty dimensions", %{state_dir: state_dir} do
      # Checkpoint cells carry run "run-A" which never matches the live boot's
      # run id, so the current-run scope selects nothing and renders empty.
      write_checkpoint!(state_dir, [930])

      output =
        capture_io(fn ->
          assert :ok = CostReport.run(["--state-dir", state_dir])
        end)

      assert output =~ "run "
      assert output =~ "(none recorded)"
    end

    test "--build resolves members from the state node build pack", %{state_dir: state_dir} do
      write_checkpoint!(state_dir, [930, 931])
      slug = write_build_pack!([930, "931"])

      output =
        capture_io(fn ->
          assert :ok = CostReport.run(["--build", slug, "--state-dir", state_dir])
        end)

      assert output =~ "ticket set (2 ticket(s))"
    end

    test "--build reads members from a materialized build summary", %{state_dir: state_dir} do
      write_checkpoint!(state_dir, [930])
      node = Summaries.state_node()
      slug = "summary-build-#{System.unique_integer([:positive])}"
      pack_dir = Path.join([node, "builds", slug])
      File.mkdir_p!(pack_dir)

      File.write!(
        Path.join(pack_dir, "build-summary.json"),
        Jason.encode!(%{"tickets" => [%{"id" => "TB-001", "ticket" => 930}]})
      )

      on_exit(fn -> File.rm_rf(pack_dir) end)

      output =
        capture_io(fn ->
          assert :ok = CostReport.run(["--build", slug, "--state-dir", state_dir])
        end)

      assert output =~ "ticket set (1 ticket(s))"
    end

    test "--build reports a missing build pack", %{state_dir: state_dir} do
      write_checkpoint!(state_dir, [930])

      assert_raise Mix.Error, ~r/no build order or summary found/, fn ->
        CostReport.run(["--build", "no-such-build-#{System.unique_integer([:positive])}", "--state-dir", state_dir])
      end
    end

    test "--build reports a pack with no ticket members", %{state_dir: state_dir} do
      write_checkpoint!(state_dir, [930])
      slug = write_build_pack!([])
      assert_raise Mix.Error, ~r/has no ticket members/, fn -> CostReport.run(["--build", slug, "--state-dir", state_dir]) end
    end
  end

  ## ---- helpers ----

  defp ticket_identity(number) do
    [owner, name] = String.split(Config.repo(), "/", parts: 2)

    %TrackerIdentity{
      status: :joinable,
      kind: :github,
      owner: owner,
      repository: name,
      provider_id: to_string(number),
      identifier: to_string(number),
      reason: nil
    }
  end

  defp envelope_with_ticket(number, run_id) do
    Aggregate.envelope(%{
      attribution: %{
        run_id: run_id,
        tracker_identity: ticket_identity(number),
        attempt_id: "attempt-1",
        session_id: "session-1",
        thread_id: "thread-1",
        turn_id: "turn-1",
        request_id: "request-1"
      }
    })
  end

  defp write_checkpoint!(state_dir, numbers) do
    records =
      numbers
      |> Enum.with_index(1)
      |> Enum.map(fn {number, position} ->
        Aggregate.record(position, envelope_with_ticket(number, "run-A"), %{
          tokens: %{input: 1_000_000},
          cost: Aggregate.money("2.50")
        })
      end)

    projection = Projection.apply_records(Projection.new(), records)
    assert :ok = Checkpoint.write(Path.join(state_dir, "checkpoint.json"), projection)
  end

  defp write_build_pack!(numbers) do
    node = Summaries.state_node()
    slug = "cost-report-build-#{System.unique_integer([:positive])}"
    pack_dir = Path.join([node, "builds", slug])
    File.mkdir_p!(pack_dir)

    tickets =
      Enum.with_index(numbers, 1)
      |> Enum.map(fn {number, index} -> %{"id" => "TB-#{index}", "ticket" => number} end)

    File.write!(Path.join(pack_dir, "build-order.json"), Jason.encode!(%{"tickets" => tickets}))
    on_exit(fn -> File.rm_rf(pack_dir) end)
    slug
  end
end
