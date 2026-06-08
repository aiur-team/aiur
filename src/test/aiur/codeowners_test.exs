defmodule Aiur.CodeownersTest do
  use Aiur.TestSupport

  alias Aiur.Codeowners

  setup do
    repo_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-codeowners-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(repo_root)

    on_exit(fn -> File.rm_rf(repo_root) end)

    {:ok, repo_root: repo_root}
  end

  test "uses GitHub CODEOWNERS location order and last matching rule", %{repo_root: repo_root} do
    write_codeowners!(repo_root, "docs/CODEOWNERS", "* @docs-owner")
    write_codeowners!(repo_root, "CODEOWNERS", "* @root-owner")

    write_codeowners!(repo_root, ".github/CODEOWNERS", """
    * @global-owner
    elixir/ @elixir-owner
    *.ex @ex-owner
    elixir/lib/aiur/codeowners.ex @specific-owner
    """)

    assert Codeowners.owners_for_path("elixir/lib/aiur/codeowners.ex", repo_root: repo_root) == [
             "specific-owner"
           ]

    assert Codeowners.owners_for_path("elixir/lib/aiur/github/client.ex", repo_root: repo_root) == [
             "ex-owner"
           ]

    assert Codeowners.owners_for_path("README.md", repo_root: repo_root) == ["global-owner"]
  end

  test "matches root-relative and directory patterns", %{repo_root: repo_root} do
    write_codeowners!(repo_root, ".github/CODEOWNERS", """
    /README.md @readme-owner
    docs/ @docs-owner
    """)

    assert Codeowners.owners_for_path("README.md", repo_root: repo_root) == ["readme-owner"]
    assert Codeowners.owners_for_path("nested/README.md", repo_root: repo_root) == []
    assert Codeowners.owners_for_path("docs/plans/plan.md", repo_root: repo_root) == ["docs-owner"]
  end

  test "discovers CODEOWNERS from a parent repo root", %{repo_root: repo_root} do
    write_codeowners!(repo_root, ".github/CODEOWNERS", "* @repo-owner")
    nested = Path.join(repo_root, "elixir")
    File.mkdir_p!(nested)

    File.cd!(nested, fn ->
      assert Codeowners.owners_for_path("lib/app.ex") == ["repo-owner"]
    end)
  end

  test "missing CODEOWNERS keeps compatibility fallback except for agent comments", %{repo_root: repo_root} do
    assert Codeowners.owners_for_path("anything.ex", repo_root: repo_root) == []

    assert Codeowners.authoritative?("driveby", repo_root: repo_root, path: "anything.ex")
    refute Codeowners.authoritative?("aiur-agent", repo_root: repo_root, path: "anything.ex", agent_logins: ["aiur-agent"])
  end

  test "resolves team owners through request function and caches per run", %{repo_root: repo_root} do
    write_codeowners!(repo_root, ".github/CODEOWNERS", "* @acme/platform")
    test_pid = self()

    request_fun = fn req ->
      send(test_pid, {:team_request, req.url})

      {:ok,
       %{
         status: 200,
         body: [%{"login" => "owner-one"}, %{"login" => "owner-two"}]
       }}
    end

    opts = [repo_root: repo_root, token: "token", request_fun: request_fun]

    assert Codeowners.owners_for_path("lib/app.ex", opts) == ["owner-one", "owner-two"]
    assert Codeowners.owners_for_path("lib/other.ex", opts) == ["owner-one", "owner-two"]
    assert_receive {:team_request, "https://api.github.com/orgs/acme/teams/platform/members?per_page=100"}
    refute_receive {:team_request, _}
  end

  test "does not cache team-member fetch failures", %{repo_root: repo_root} do
    write_codeowners!(repo_root, ".github/CODEOWNERS", "* @acme/platform")

    request_fun = fn _req ->
      case Process.get(:team_call_count, 0) do
        0 ->
          Process.put(:team_call_count, 1)
          {:ok, %{status: 500, body: %{}}}

        _ ->
          {:ok, %{status: 200, body: [%{"login" => "owner-one"}]}}
      end
    end

    opts = [repo_root: repo_root, token: "token", request_fun: request_fun]

    assert Codeowners.owners_for_path("lib/app.ex", opts) == []
    assert Codeowners.owners_for_path("lib/other.ex", opts) == ["owner-one"]
  end

  test "matches CODEOWNER logins case-insensitively", %{repo_root: repo_root} do
    write_codeowners!(repo_root, ".github/CODEOWNERS", "* @Its-Everdred")

    assert Codeowners.authoritative?("its-everdred", repo_root: repo_root, path: "lib/app.ex")
    assert Codeowners.authoritative?("ITS-EVERDRED", repo_root: repo_root, path: "lib/app.ex")
  end

  test "classifies comments with reason metadata", %{repo_root: repo_root} do
    write_codeowners!(repo_root, ".github/CODEOWNERS", "elixir/ @its-everdred")
    context = Codeowners.ownership_for_paths(["elixir/lib/aiur/codeowners.ex"], repo_root: repo_root)

    owner_comment = %{"user" => %{"login" => "its-everdred"}, "body" => "Please change this."}
    outsider_comment = %{"user" => %{"login" => "driveby"}, "body" => "Maybe change this."}

    classified_owner = Codeowners.classify_comment(owner_comment, context)
    classified_outsider = Codeowners.classify_comment(outsider_comment, context)

    assert classified_owner.authoritative
    assert classified_owner.authority_reason =~ "CODEOWNER via @its-everdred"
    refute classified_outsider.authoritative
    assert classified_outsider.authority_reason == "Author is not a CODEOWNER for the relevant paths."
  end

  defp write_codeowners!(repo_root, relative_path, content) do
    path = Path.join(repo_root, relative_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end
end
