defmodule Aiur.FindingsTest do
  use ExUnit.Case, async: false

  alias Aiur.{Findings, RepoBase}

  setup do
    # Host-unique, not just VM-unique: see `Aiur.TestSupport.tmp_root!/1`.
    root = Aiur.TestSupport.tmp_root!("aiur_findings")
    previous_root = Application.get_env(:aiur, :repo_base_root)
    Application.put_env(:aiur, :repo_base_root, root)

    on_exit(fn ->
      case previous_root do
        nil -> Application.delete_env(:aiur, :repo_base_root)
        value -> Application.put_env(:aiur, :repo_base_root, value)
      end

      File.rm_rf!(root)
    end)

    {:ok, repo: "https://github.com/owner/repo.git", second_repo: "https://github.com/other/project.git"}
  end

  test "appends validated findings and aggregates slugs across repository nodes", %{repo: repo, second_repo: second_repo} do
    assert :ok = Findings.append(repo, finding("shared-failure", nil))
    assert :ok = Findings.append(second_repo, finding("second-failure", 42, "repo"))

    assert {:ok, ["second-failure", "shared-failure"]} = Findings.slugs()
    assert {:ok, [unfiled]} = Findings.unfiled()
    assert unfiled["slug"] == "shared-failure"
    assert {:ok, [repo_finding]} = Findings.all(scope: "repo")
    assert repo_finding["slug"] == "second-failure"
  end

  test "retains prior findings when appending another record", %{repo: repo} do
    assert :ok = Findings.append(repo, finding("first-failure", nil))
    assert :ok = Findings.append(repo, finding("second-failure", 42))

    slugs =
      repo
      |> RepoBase.findings_path()
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.map(& &1["slug"])

    assert slugs == ["first-failure", "second-failure"]
  end

  test "keeps valid records and reports corrupt lines", %{repo: repo} do
    assert :ok = Findings.append(repo, finding("first-failure", nil))
    path = RepoBase.findings_path(repo)
    File.write!(path, File.read!(path) <> "{not-json}\n" <> Jason.encode!(finding("second-failure", 42)) <> "\n")

    assert {:ok, records, [{:invalid_finding_record, ^path, 2, "invalid JSON"}]} =
             Findings.all_with_diagnostics()

    assert Enum.map(records, & &1["slug"]) == ["first-failure", "second-failure"]
  end

  test "distinguishes an empty ledger from a ledger containing only corrupt lines", %{repo: repo} do
    path = RepoBase.findings_path(repo)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")

    assert {:ok, [], []} = Findings.all_with_diagnostics()

    File.write!(path, "{not-json}\n")

    assert {:ok, [], [{:invalid_finding_record, ^path, 1, "invalid JSON"}]} =
             Findings.all_with_diagnostics()
  end

  test "keeps other ledgers readable when one ledger file is unreadable", %{repo: repo, second_repo: second_repo} do
    assert :ok = Findings.append(repo, finding("first-failure", nil))
    assert :ok = Findings.append(second_repo, finding("second-failure", 42, "repo"))

    # A directory at the ledger path cannot be read; the other repo's ledger
    # must survive and the failure must be surfaced as a diagnostic.
    unreadable = RepoBase.findings_path(repo)
    File.rm!(unreadable)
    File.mkdir_p!(unreadable)

    assert {:ok, records, [{:finding_read_failed, ^unreadable, _reason}]} =
             Findings.all_with_diagnostics()

    assert Enum.map(records, & &1["slug"]) == ["second-failure"]
  end

  test "reports the physical line number after an interior blank line", %{repo: repo} do
    assert :ok = Findings.append(repo, finding("first-failure", nil))
    path = RepoBase.findings_path(repo)
    File.write!(path, File.read!(path) <> "\n" <> Jason.encode!(finding("second-failure", 42)) <> "\n")

    assert {:ok, records, [{:invalid_finding_record, ^path, 2, "invalid JSON"}]} =
             Findings.all_with_diagnostics()

    assert Enum.map(records, & &1["slug"]) == ["first-failure", "second-failure"]
  end

  test "uses the latest slug record to clear an unfiled finding without rewriting history", %{repo: repo} do
    assert :ok = Findings.append(repo, finding("shared-failure", nil))

    filed =
      finding("shared-failure", 1464)
      |> Map.put("observed_at", "2026-08-02T04:31:00Z")

    assert :ok = Findings.append(repo, filed)
    assert {:ok, []} = Findings.unfiled()
    assert {:ok, [open, current]} = Findings.all()
    assert open["status"] == "open"
    assert current["status"] == "filed"
  end

  test "rejects records over 4 KiB and invalid scopes before writing", %{repo: repo} do
    assert {:error, message} = Findings.append(repo, %{finding("too-large", nil) | "summary" => String.duplicate("x", 5_000)})
    assert message =~ "atomic append limit"
    refute File.exists?(RepoBase.findings_path(repo))

    assert {:error, "finding scope must be one of: aiur, repo"} = Findings.append(repo, %{finding("bad-scope", nil) | "scope" => "host"})
    refute File.exists?(RepoBase.findings_path(repo))
  end

  test "requires a slug", %{repo: repo} do
    assert {:error, "finding requires non-empty slug"} = Findings.append(repo, Map.delete(finding("missing", nil), "slug"))
  end

  test "requires an ISO-8601 observation timestamp", %{repo: repo} do
    finding = Map.put(finding("invalid-time", nil), "observed_at", "yesterday")
    assert {:error, "finding observed_at must be an ISO-8601 timestamp"} = Findings.append(repo, finding)
  end

  test "requires a ticket when a finding is filed or resolved", %{repo: repo} do
    finding = Map.put(finding("invalid-status", nil), "status", "resolved")

    assert {:error, "open findings require ticket null; filed and resolved findings require a ticket"} =
             Findings.append(repo, finding)
  end

  defp finding(slug, ticket, scope \\ "aiur") do
    %{
      "slug" => slug,
      "observed_at" => "2026-08-02T04:30:00Z",
      "scope" => scope,
      "observed_in" => "owner/repo",
      "instance" => "boot-123",
      "summary" => "a concise observation",
      "evidence" => ["#1464"],
      "cost" => "one hour",
      "ticket" => ticket,
      "status" => if(ticket, do: "filed", else: "open")
    }
  end
end
