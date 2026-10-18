defmodule Aiur.RepoBase.BoundaryTest do
  use ExUnit.Case, async: false

  alias Aiur.RepoBase
  alias Aiur.RepoBase.{Clone, LedgerTransfer}

  defmodule Provider do
    def token, do: "workspace-boundary-token"
    def reject(_record), do: {:error, :owner_rejected}
  end

  setup do
    previous = for key <- [:repo_base_git_token, :repo_ledger_validators], do: {key, Application.fetch_env(:aiur, key)}

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, configured} -> Application.put_env(:aiur, key, configured)
          :error -> Application.delete_env(:aiur, key)
        end
      end
    end)

    root = Aiur.TestSupport.tmp_root!("workspace-boundary-ledger")
    File.mkdir_p!(root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "git environment uses the registered token provider and defaults to no token" do
    Application.put_env(:aiur, :repo_base_git_token, {Provider, :token, []})
    assert Clone.git_auth_env() == RepoBase.git_auth_env("workspace-boundary-token")
    Application.delete_env(:aiur, :repo_base_git_token)
    assert Clone.git_auth_env() == [{"GIT_TERMINAL_PROMPT", "0"}]
  end

  test "ledger read without a validator fails closed even for an empty ledger", %{root: root} do
    path = Path.join(root, "asks.ndjson")
    File.write!(path, "")
    assert {:error, {:no_validator, :asks}} = RepoBase.read_ledger(path, :asks, nil)
  end

  test "ledger migration uses registered validation and preserves rejected files", %{root: root} do
    source = Path.join([root, "legacy", "meta", "findings.ndjson"])
    destination = Path.join([root, "canonical", "meta", "findings.ndjson"])

    for path <- [source, destination] do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "{}\n")
    end

    Application.put_env(:aiur, :repo_ledger_validators, %{})
    assert {:error, {:no_validator, :findings}} = LedgerTransfer.merge_findings(source, destination)
    Application.put_env(:aiur, :repo_ledger_validators, %{findings: {Provider, :reject}})
    assert {:error, {:invalid_findings_ledger, ^destination, 1}} = LedgerTransfer.merge_findings(source, destination)
    assert File.read!(source) == "{}\n"
    assert File.read!(destination) == "{}\n"
  end
end
