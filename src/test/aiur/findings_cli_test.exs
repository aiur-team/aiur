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

    {:ok, repo: "https://github.com/owner/repo.git"}
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
