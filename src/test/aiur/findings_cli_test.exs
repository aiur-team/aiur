defmodule Aiur.FindingsCLITest do
  use ExUnit.Case, async: false

  alias Aiur.{Findings, FindingsCLI}

  setup do
    root = Path.join(System.tmp_dir!(), "aiur_findings_cli_#{System.unique_integer([:positive])}")
    previous_root = Application.get_env(:aiur, :repo_base_root)
    Application.put_env(:aiur, :repo_base_root, root)

    on_exit(fn ->
      case previous_root do
        nil -> Application.delete_env(:aiur, :repo_base_root)
        value -> Application.put_env(:aiur, :repo_base_root, value)
      end

      File.rm_rf!(root)
    end)

    {:ok, repo: "owner/repo"}
  end

  test "records through the validated production writer", %{repo: repo} do
    record = finding(nil) |> Map.put("slug", "production-writer")
    output = Agent.start_link(fn -> [] end) |> elem(1)
    puts = fn line -> Agent.update(output, &[IO.iodata_to_binary(line) | &1]) end

    assert 0 == FindingsCLI.run(%{record: Jason.encode!(record), repo: repo}, puts)
    assert {:ok, [persisted]} = Findings.all()
    assert persisted["slug"] == "production-writer"
    assert Agent.get(output, &Enum.reverse/1) == []
  end

  test "rejects an invalid record through the CLI", %{repo: repo} do
    output = Agent.start_link(fn -> [] end) |> elem(1)
    puts = fn line -> Agent.update(output, &[IO.iodata_to_binary(line) | &1]) end

    assert 2 == FindingsCLI.run(%{record: ~s({"scope":"host"}), repo: repo}, puts)
    assert [message] = Agent.get(output, &Enum.reverse/1)
    assert message =~ "finding requires non-empty slug"
  end

  test "rejects a repository slug that could escape the state root" do
    output = Agent.start_link(fn -> [] end) |> elem(1)
    puts = fn line -> Agent.update(output, &[IO.iodata_to_binary(line) | &1]) end

    assert 2 == FindingsCLI.run(%{record: Jason.encode!(finding(nil)), repo: "../outside"}, puts)
    assert [message] = Agent.get(output, &Enum.reverse/1)
    assert message =~ "owner/repo slug"
  end

  test "renders a stable open-findings digest from latest slug state", %{repo: repo} do
    assert :ok = Findings.append(repo, finding(nil) |> Map.put("slug", "open-one"))

    assert :ok =
             Findings.append(
               repo,
               finding(1464, "filed") |> Map.put("slug", "resolved")
             )

    later =
      finding(1464, "resolved")
      |> Map.put("slug", "resolved")
      |> Map.put("observed_at", "2026-08-02T05:30:00Z")

    assert :ok = Findings.append(repo, later)
    output = Agent.start_link(fn -> [] end) |> elem(1)
    puts = fn line -> Agent.update(output, &[IO.iodata_to_binary(line) | &1]) end

    assert 0 == FindingsCLI.run(%{digest: true, scope: nil}, puts)
    digest = output |> Agent.get(&Enum.reverse/1) |> Enum.join("\n")
    assert digest =~ "# Open Aiur findings"
    assert digest =~ "`open-one`"
    refute digest =~ "`resolved`"
  end

  test "--unfiled returns non-zero only while an unfiled finding remains", %{repo: repo} do
    assert 0 == FindingsCLI.run(%{unfiled: true, slugs: false, scope: nil}, fn _ -> :ok end)

    assert :ok = Findings.append(repo, finding(nil))
    assert 1 == FindingsCLI.run(%{unfiled: true, slugs: false, scope: nil}, &send(self(), {:line, &1}))
    assert_received {:line, line}
    assert line =~ "unfiled"

    filed = finding(1464, "filed") |> Map.put("observed_at", "2026-08-02T04:31:00Z")
    assert :ok = Findings.append(repo, filed)
    assert 0 == FindingsCLI.run(%{unfiled: true, slugs: false, scope: nil}, fn _ -> flunk("filed finding was still unfiled") end)
  end

  test "reports corrupt ledger lines while rendering valid findings", %{repo: repo} do
    assert :ok = Findings.append(repo, finding(nil) |> Map.put("slug", "valid"))
    path = Aiur.RepoBase.findings_path(repo)
    File.write!(path, File.read!(path) <> "{not-json}\n")
    output = Agent.start_link(fn -> [] end) |> elem(1)

    assert 0 ==
             FindingsCLI.run(%{unfiled: false, slugs: false, scope: nil}, fn line ->
               Agent.update(output, &[IO.iodata_to_binary(line) | &1])
             end)

    lines = Agent.get(output, &Enum.reverse/1)
    assert Enum.any?(lines, &String.contains?(&1, ", 2,"))
    assert Enum.any?(lines, &String.contains?(&1, ~s("slug":"valid")))
  end

  test "--slugs emits de-duplicated join keys", %{repo: repo} do
    assert :ok = Findings.append(repo, finding(1464, "filed"))
    assert 0 == FindingsCLI.run(%{unfiled: false, slugs: true, scope: "aiur"}, &send(self(), {:slug, &1}))
    assert_received {:slug, "unfiled"}
  end

  defp finding(ticket, status \\ "open") do
    %{
      "slug" => "unfiled",
      "observed_at" => "2026-08-02T04:30:00Z",
      "scope" => "aiur",
      "observed_in" => "owner/repo",
      "instance" => "boot-123",
      "summary" => "a concise observation",
      "evidence" => ["#1464"],
      "cost" => "one hour",
      "ticket" => ticket,
      "status" => status
    }
  end
end
