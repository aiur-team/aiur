defmodule Aiur.GitHub.TeamsTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.Teams

  @token_cache_key {Aiur.GitHub.Config, :resolved_token}

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    prev_cached_token = :persistent_term.get(@token_cache_key, :unset)
    :persistent_term.erase(@token_cache_key)
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", prev_token)

      case prev_cached_token do
        :unset -> :persistent_term.erase(@token_cache_key)
        token -> :persistent_term.put(@token_cache_key, token)
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo"
    )

    :ok
  end

  describe "fetch_team_members/3" do
    test "returns list of member logins" do
      members = [%{"login" => "alice"}, %{"login" => "bob"}]

      request_fun = fn %{method: :get, url: url} ->
        assert url =~ "/orgs/myorg/teams/backend/members"
        {:ok, %{status: 200, body: members, headers: []}}
      end

      assert {:ok, ["alice", "bob"]} =
               Teams.fetch_team_members("myorg", "backend", request_fun: request_fun)
    end

    test "returns error on 403 (insufficient scope)" do
      request_fun = fn _ -> {:ok, %{status: 403, body: %{"message" => "Forbidden"}}} end
      assert {:error, _} = Teams.fetch_team_members("myorg", "backend", request_fun: request_fun)
    end

    test "paginates across multiple pages" do
      request_fun = fn %{method: :get, url: url} ->
        if url =~ "page=2" do
          {:ok, %{status: 200, body: [%{"login" => "carol"}], headers: []}}
        else
          {:ok,
           %{
             status: 200,
             body: [%{"login" => "alice"}],
             headers: [{"link", "<https://api.github.com?page=2>; rel=\"next\""}]
           }}
        end
      end

      assert {:ok, logins} = Teams.fetch_team_members("myorg", "backend", request_fun: request_fun)
      assert "alice" in logins
      assert "carol" in logins
    end
  end

  describe "member_login_list/1" do
    test "extracts login from map" do
      assert Teams.member_login_list(%{"login" => "alice"}) == ["alice"]
    end

    test "returns empty for non-login maps" do
      assert Teams.member_login_list(%{"id" => 1}) == []
      assert Teams.member_login_list("not a map") == []
    end
  end
end
