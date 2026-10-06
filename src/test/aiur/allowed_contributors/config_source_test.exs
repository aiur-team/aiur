defmodule Aiur.AllowedContributors.ConfigSourceTest do
  use ExUnit.Case, async: true
  alias Aiur.AllowedContributors
  alias Aiur.AllowedContributorsFixture, as: Fixture
  alias Aiur.Config.Schema

  defp config(value), do: Schema.parse(%{"tracker" => %{"github" => %{"allowed_contributors" => value}}})

  test "config only admits numeric users without a token or file", context do
    {server, _gh} = Fixture.start(context, body: :absent, token_fun: fn -> nil end, allowed_contributors: %{"users" => [42]})
    assert {:accept, "user"} = AllowedContributors.observe(Fixture.candidate(), server)
    refute_received {:github_get, _url}
    assert_received {:alert, "allowed_contributors.changed", message}
    assert message =~ "config"
    records = :sys.get_state(server).audit_path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert [%{"allowlist_source" => "config", "allowlist_sha" => nil, "decision" => "accept"}] = records
  end

  test "config wins over an existing file and does not fetch it", context do
    {server, _gh} = Fixture.start(context, body: "user 666\n", allowed_contributors: %{"users" => [42]})
    assert {:accept, "user"} = AllowedContributors.observe(Fixture.candidate(), server)
    assert {:reject, :not_allowed} = AllowedContributors.observe(Fixture.candidate(number: 102, author_id: 666), server)
    refute_received {:github_get, _url}
  end

  test "explicit empty config admits nobody without reading the fallback file", context do
    for value <- [%{}, nil, %{"users" => [], "orgs" => []}] do
      assert {:ok, settings} = config(value)
      {server, _gh} = Fixture.start(context, allowed_contributors: settings.tracker.github.allowed_contributors)
      assert {:reject, :not_allowed} = AllowedContributors.observe(Fixture.candidate(), server)
      refute_received {:github_get, _url}
    end
  end

  test "config orgs use the existing numeric membership checks", context do
    assert {:ok, settings} = config(%{"users" => [50], "orgs" => [%{"id" => 77, "login" => "acme-org"}]})

    {server, _gh} =
      Fixture.start(context,
        allowed_contributors: settings.tracker.github.allowed_contributors,
        members: %{{"acme-org", "alice"} => Fixture.member(77, 42)}
      )

    assert {:accept, "org:77"} = AllowedContributors.observe(Fixture.candidate(), server)
    assert_received {:github_get, "https://api.github.com/orgs/acme-org/memberships/alice"}
    refute_received {:github_get, _url}
  end

  test "startup rejects malformed config entries with the dotted key" do
    for invalid <- [
          false,
          "alice",
          [],
          %{"users" => ["42"]},
          %{"users" => [0]},
          %{"users" => [1.5]},
          %{"users" => [9_223_372_036_854_775_808]},
          %{"users" => nil},
          %{"unexpected" => []},
          %{"orgs" => [%{"id" => 77, "login" => "../evil"}]},
          %{"orgs" => [%{"id" => "77", "login" => "acme"}]},
          %{"orgs" => [%{"id" => 77}]},
          %{"orgs" => [%{"id" => 77, "login" => "acme", "extra" => true}]},
          %{"orgs" => [%{"id" => 77, "login" => "acme"}, %{"id" => 77, "login" => "other"}]}
        ] do
      assert {:error, {:invalid_workflow_config, message}} = config(invalid)
      assert message =~ "tracker.github.allowed_contributors"
    end
  end

  test "reload replaces config entries and alerts the added and removed ids", context do
    {:ok, selection} = Agent.start_link(fn -> %{"users" => [42]} end)
    {server, _gh} = Fixture.start(context, config_fun: fn -> Agent.get(selection, & &1) end)
    assert {:accept, "user"} = AllowedContributors.observe(Fixture.candidate(), server)
    assert_received {:alert, "allowed_contributors.changed", _initial}
    Agent.update(selection, fn _ -> %{"users" => [43]} end)
    Phoenix.PubSub.broadcast(Aiur.PubSub, "workflow_store:configuration", {:workflow_config_updated, 2})
    _ = :sys.get_state(server)
    assert {:reject, :not_allowed} = AllowedContributors.observe(Fixture.candidate(number: 102), server)
    assert {:accept, "user"} = AllowedContributors.observe(Fixture.candidate(number: 103, author_id: 43), server)
    assert_received {:alert, "allowed_contributors.changed", message}
    assert message =~ ~s(added ["user:43"])
    assert message =~ ~s(removed ["user:42"])
    assert message =~ "config -> config"
    refute_received {:github_get, _url}
  end

  test "restart remembers explicit empty config and alerts a source switch", context do
    dir = Path.join(System.tmp_dir!(), "aiur-ac-config-restart-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {first, _gh} = Fixture.start(context, state_dir: dir, allowed_contributors: %{}, id: :config_boot)
    _ = :sys.get_state(first)
    assert_received {:alert, "allowed_contributors.changed", initial}
    assert initial =~ "config"
    stop_supervised!(:config_boot)
    {second, _gh} = Fixture.start(context, state_dir: dir, allowed_contributors: %{}, id: :config_restart)
    _ = :sys.get_state(second)
    refute_received {:alert, _, _}
    stop_supervised!(:config_restart)
    {file, _gh} = Fixture.start(context, state_dir: dir)
    _ = :sys.get_state(file)
    assert_received {:alert, "allowed_contributors.changed", switched}
    assert switched =~ "config -> file@#{Fixture.sha()}"
  end

  test "removing config revokes its users even when the fallback cannot be read", context do
    {:ok, selection} = Agent.start_link(fn -> %{config: %{"users" => [42]}, token: nil} end)

    {server, gh} =
      Fixture.start(context,
        body: "user 43\n",
        config_fun: fn -> Agent.get(selection, & &1.config) end,
        token_fun: fn -> Agent.get(selection, & &1.token) end
      )

    assert {:accept, "user"} = AllowedContributors.observe(Fixture.candidate(), server)
    assert_received {:alert, "allowed_contributors.changed", _initial}
    Agent.update(selection, &%{&1 | config: nil})
    :ok = AllowedContributors.refresh(server)
    assert {:deferred, :allowlist_unavailable} = AllowedContributors.observe(Fixture.candidate(number: 102), server)
    refute_received {:github_get, _url}
    assert_received {:alert, "allowed_contributors.changed", removed}
    assert removed =~ "config -> file@unavailable"
    assert removed =~ ~s(removed ["user:42"])
    Agent.update(selection, &%{&1 | token: "token"})
    Agent.update(gh, &%{&1 | body: {:error, :timeout}})
    :ok = AllowedContributors.refresh(server)
    assert {:deferred, :allowlist_unavailable} = AllowedContributors.observe(Fixture.candidate(number: 103), server)
    Agent.update(gh, &%{&1 | body: "user 43\n"})
    :ok = AllowedContributors.refresh(server)
    assert {:reject, :not_allowed} = AllowedContributors.observe(Fixture.candidate(number: 103), server)
    assert {:accept, "user"} = AllowedContributors.observe(Fixture.candidate(number: 104, author_id: 43), server)
  end

  test "a raised fallback read cannot restore revoked config trust", context do
    {:ok, selection} = Agent.start_link(fn -> %{"users" => [42]} end)

    {server, _gh} =
      Fixture.start(context,
        config_fun: fn -> Agent.get(selection, & &1) end,
        request_fun: fn _req -> raise "transport crashed" end
      )

    assert {:accept, "user"} = AllowedContributors.observe(Fixture.candidate(), server)
    Agent.update(selection, fn _ -> nil end)
    :ok = AllowedContributors.refresh(server)
    assert {:deferred, :allowlist_unavailable} = AllowedContributors.observe(Fixture.candidate(number: 102), server)
    assert :sys.get_state(server).snapshot == nil
  end

  test "invalid config source fails closed and identifies config in its alert", context do
    {server, _gh} = Fixture.start(context, allowed_contributors: %{"users" => ["alice"]})
    assert {:reject, :allowlist_invalid} = AllowedContributors.observe(Fixture.candidate(), server)
    assert_received {:alert, "allowed_contributors.invalid", message}
    assert message =~ "config"
    refute_received {:github_get, _url}
  end
end
