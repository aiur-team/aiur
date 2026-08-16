defmodule Aiur.CodeownersTest do
  use Aiur.TestSupport

  alias Aiur.Codeowners
  alias Aiur.GitHub.CodeOwners

  # Use ExUnit's per-test `:tmp_dir` (project-local `tmp/`) instead of the shared
  # `System.tmp_dir!()` tmpfs: under `--cover` the shared `/tmp` can hit 100% and
  # fail the setup mkdir/writes. See #1212.
  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # Keep the OS-global (VM-wide) cwd stable across tests: the parent-root
    # discovery test below changes cwd, and restoring here stops this module
    # from leaking a stale cwd into later modules if that ever fails to unwind.
    # The location-order test itself is cwd-independent — it passes `repo_root:`
    # explicitly, so the `:tmp_dir` switch is its real fix. See #1212.
    original_cwd = File.cwd!()
    on_exit(fn -> File.cd!(original_cwd) end)

    {:ok, repo_root: tmp_dir}
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

  # Regression: this used to return `true` for every commenter, so on a public
  # repo without CODEOWNERS any drive-by comment was accepted as an
  # authoritative instruction.
  test "missing CODEOWNERS does not make a drive-by commenter authoritative", %{repo_root: repo_root} do
    assert Codeowners.owners_for_path("anything.ex", repo_root: repo_root) == []

    refute Codeowners.authoritative?("driveby", repo_root: repo_root, path: "anything.ex")
    refute Codeowners.authoritative?("aiur-agent", repo_root: repo_root, path: "anything.ex", agent_logins: ["aiur-agent"])

    classified =
      Codeowners.classify_comment(
        %{author: %{login: "driveby"}},
        Codeowners.ownership_for_path("anything.ex", repo_root: repo_root)
      )

    refute classified.authoritative
    assert classified.authority_reason =~ "only explicitly configured trusted accounts"
  end

  # Degraded mode has one owner, `Aiur.GitHub.CodeOwners`. Answering a flat
  # `false` here instead of delegating would silently drop the operator's own
  # comments from the agent digest and leave review threads permanently
  # unresolvable — a fail-closed gate that presents as a hang.
  test "missing CODEOWNERS still trusts the configured accounts the GenServer resolves", %{repo_root: repo_root} do
    server = start_trust_server(repo_root, "operator")

    assert Codeowners.authoritative?("operator", repo_root: repo_root, path: "anything.ex", trust_server: server)
    refute Codeowners.authoritative?("driveby", repo_root: repo_root, path: "anything.ex", trust_server: server)
  end

  # `aiur init` writes a comments-only CODEOWNERS when the operator declines to
  # name an owner. It grants ownership to nobody, so it is the degraded case and
  # must report itself as such rather than as "you are not a CODEOWNER".
  test "a comments-only CODEOWNERS is the degraded case, not a populated one", %{repo_root: repo_root} do
    write_codeowners!(repo_root, ".github/CODEOWNERS", "# Aiur trust boundary\n#\n# Add owners below.\n")

    ownership = Codeowners.ownership_for_path("anything.ex", repo_root: repo_root)

    refute ownership.codeowners_present

    classified = Codeowners.classify_comment(%{author: %{login: "driveby"}}, ownership)

    refute classified.authoritative
    assert classified.authority_reason =~ "No CODEOWNERS rules found"
  end

  # The GenServer resolves trust from its own configured source. Pointing it at
  # a populated file while the repo under test has none is exactly the shape
  # that matters: `Aiur.Codeowners` must report the GenServer's answer, not
  # invent its own.
  defp start_trust_server(repo_root, trusted_login) do
    path = Path.join(repo_root, "trust-codeowners")
    File.write!(path, "* @#{trusted_login}\n")
    name = String.to_atom("codeowners_trust_#{System.unique_integer([:positive])}")

    {:ok, _pid} = CodeOwners.start_link(name: name, path: path, refresh_seconds: 86_400)

    name
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
