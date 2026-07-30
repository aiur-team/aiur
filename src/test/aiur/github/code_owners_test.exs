defmodule Aiur.GitHub.CodeOwnersTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.CodeOwners
  alias Aiur.Workflow

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "aiur_codeowners_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    path = Path.join(tmp_dir, "CODEOWNERS")

    prev_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "aiur"
    )

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", prev_token)
      File.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir, path: path}
  end

  defp start_owners(path, opts \\ []) do
    name = String.to_atom("co_#{System.unique_integer([:positive])}")
    opts = Keyword.merge([name: name, path: path, refresh_seconds: 86_400], opts)
    {:ok, pid} = CodeOwners.start_link(opts)
    {pid, name}
  end

  describe "parse + allowlist with bot account" do
    test "user tokens become allowlist entries", %{path: path} do
      File.write!(path, "* @alice @bob\n")
      configure_bot_account("aiur-bot")

      {_pid, name} = start_owners(path)
      snap = CodeOwners.snapshot(name)

      assert "alice" in snap
      assert "bob" in snap
      assert "aiur-bot" in snap
    end

    test "missing file → allowlist is bot-only", %{path: path} do
      configure_bot_account("aiur-bot")

      {_pid, name} = start_owners(path)
      assert CodeOwners.snapshot(name) == ["aiur-bot"]
    end

    test "empty file → allowlist is bot-only", %{path: path} do
      File.write!(path, "\n\n# comment only\n")
      configure_bot_account("aiur-bot")

      {_pid, name} = start_owners(path)
      assert CodeOwners.snapshot(name) == ["aiur-bot"]
    end

    test "trusted accounts are included without becoming bot self-loop authors", %{path: path} do
      File.write!(path, "* @alice\n")
      configure_github(trusted_accounts: ["its-everdred"])

      {_pid, name} = start_owners(path)
      snap = CodeOwners.snapshot(name)

      assert "alice" in snap
      assert "its-everdred" in snap
      refute "aiur-bot" in snap

      assert CodeOwners.codeowners_snapshot(name) == ["alice"]
    end

    test "trusted accounts survive CODEOWNERS team resolution failures", %{path: path} do
      File.write!(path, "* @myorg/myteam\n")
      configure_github(trusted_accounts: ["its-everdred"])

      request_fun = fn _ -> {:ok, %{status: 404, headers: [], body: ""}} end

      {_pid, name} = start_owners(path, request_fun: request_fun)
      snap = CodeOwners.snapshot(name)

      assert snap == ["its-everdred"]
      assert CodeOwners.allowed?("its-everdred", name)
    end

    test "comment-only lines do not contribute entries", %{path: path} do
      File.write!(path, "# this is a comment\n# @notreal\n")
      configure_bot_account("aiur-bot")

      {_pid, name} = start_owners(path)
      assert CodeOwners.snapshot(name) == ["aiur-bot"]
    end

    test "is case-insensitive on author lookup", %{path: path} do
      File.write!(path, "* @Alice\n")
      configure_bot_account("aiur-bot")

      {_pid, name} = start_owners(path)
      assert CodeOwners.allowed?("alice", name)
      assert CodeOwners.allowed?("ALICE", name)
      assert CodeOwners.allowed?("Alice", name)
    end

    test "@org/team is resolved via fetch_team_members", %{path: path} do
      File.write!(path, "* @myorg/myteam\n")
      configure_bot_account("aiur-bot")

      request_fun = fn %{url: url, method: :get} ->
        if String.contains?(url, "/orgs/myorg/teams/myteam/members") do
          {:ok,
           %{
             status: 200,
             headers: [],
             body: [%{"login" => "charlie"}, %{"login" => "diana"}]
           }}
        else
          {:ok, %{status: 404, headers: [], body: ""}}
        end
      end

      {_pid, name} = start_owners(path, request_fun: request_fun)
      snap = CodeOwners.snapshot(name)

      assert "charlie" in snap
      assert "diana" in snap
      assert "aiur-bot" in snap
    end

    test "@org/team that 403s is skipped (read:org scope missing); other entries survive",
         %{path: path} do
      File.write!(path, "* @alice @badorg/team\n")
      configure_bot_account("aiur-bot")

      request_fun = fn _ -> {:ok, %{status: 403, headers: [], body: ""}} end

      {_pid, name} = start_owners(path, request_fun: request_fun)
      snap = CodeOwners.snapshot(name)

      assert "alice" in snap
      assert "aiur-bot" in snap
      refute Enum.any?(snap, &String.contains?(&1, "team"))
    end

    test "missing file + nil bot_account → falls back to trusting the repo owner",
         %{path: path} do
      # Both bot_account unset and file missing. Rather than trust nobody —
      # which silently disables the whole review-comment → rework loop (#693)
      # by dropping every comment as :untrusted_author — the allowlist falls
      # back to the repo owner ("owner" of "owner/repo"). The owner is
      # inherently trusted (unlike an arbitrary third party, #687), so the
      # operator's comments still drive rework; a random login stays untrusted.
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "aiur"
      )

      {_pid, name} = start_owners(path)
      snap = CodeOwners.snapshot(name)
      assert "owner" in snap
      refute "__codeowners_bootstrap__" in snap
      assert CodeOwners.allowed?("owner", name)
      refute CodeOwners.allowed?("alice", name)
    end

    test "refresh/1 re-parses the file in place", %{path: path} do
      File.write!(path, "* @alice\n")
      configure_bot_account("aiur-bot")

      {_pid, name} = start_owners(path)
      assert "alice" in CodeOwners.snapshot(name)
      refute "bob" in CodeOwners.snapshot(name)

      File.write!(path, "* @alice @bob\n")
      :ok = CodeOwners.refresh(name)

      snap = CodeOwners.snapshot(name)
      assert "alice" in snap
      assert "bob" in snap
    end
  end

  defp configure_bot_account(bot) do
    configure_github(bot_account: bot)
  end

  defp configure_github(opts) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "aiur",
      tracker_bot_account: Keyword.get(opts, :bot_account),
      tracker_trusted_accounts: Keyword.get(opts, :trusted_accounts, [])
    )
  end
end
