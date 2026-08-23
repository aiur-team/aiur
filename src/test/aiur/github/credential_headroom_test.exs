defmodule Aiur.GitHub.CredentialHeadroomTest do
  use ExUnit.Case, async: false

  alias Aiur.GitHub.{Budget, CredentialHeadroom}

  setup do
    unless Process.whereis(CredentialHeadroom), do: start_supervised!(CredentialHeadroom)
    CredentialHeadroom.reset()
    on_exit(&CredentialHeadroom.reset/0)
    :ok
  end

  defp response(resource, limit, remaining, reset_at) do
    {:ok,
     %{
       status: 200,
       headers: [
         {"x-ratelimit-resource", resource},
         {"x-ratelimit-limit", Integer.to_string(limit)},
         {"x-ratelimit-remaining", Integer.to_string(remaining)},
         {"x-ratelimit-reset", Integer.to_string(DateTime.to_unix(reset_at))}
       ]
     }}
  end

  test "keeps windows separate per credential and per resource" do
    later = DateTime.add(DateTime.utc_now(), 900)

    CredentialHeadroom.observe(%{token: "a", url: "https://api.github.com/graphql"}, response("graphql", 5_000, 400, later))
    CredentialHeadroom.observe(%{token: "b", url: "https://api.github.com/graphql"}, response("graphql", 5_000, 4_800, later))
    CredentialHeadroom.observe(%{token: "a", url: "https://api.github.com/repos/o/r"}, response("core", 5_000, 4_912, later))

    assert %{remaining: 400} = CredentialHeadroom.window(Budget.token_key("a"), "graphql")
    assert %{remaining: 4_800} = CredentialHeadroom.window(Budget.token_key("b"), "graphql")
    assert %{remaining: 4_912, used: 88} = CredentialHeadroom.window(Budget.token_key("a"), "core")
    assert CredentialHeadroom.window(Budget.token_key("b"), "core") == nil
  end

  test "a window whose reset has passed is not returned" do
    past = DateTime.add(DateTime.utc_now(), -30)

    CredentialHeadroom.observe(%{token: "a", url: "https://api.github.com/graphql"}, response("graphql", 5_000, 0, past))

    assert CredentialHeadroom.window(Budget.token_key("a"), "graphql") == nil
    assert CredentialHeadroom.snapshot() == %{}
  end

  test "last_observed keeps the expired window so a stale meter can show its age" do
    past = DateTime.add(DateTime.utc_now(), -30)

    CredentialHeadroom.observe(%{token: "a", url: "https://api.github.com/graphql"}, response("graphql", 5_000, 0, past))

    # `window/3` and `snapshot/1` refuse the expired window — headroom that
    # cannot be spent — but `last_observed/2` keeps it, with its observed time,
    # so the cache page can say how long ago the credential was last seen.
    assert CredentialHeadroom.window(Budget.token_key("a"), "graphql") == nil

    last = CredentialHeadroom.last_observed(Budget.token_key("a"), "graphql")
    assert %{observed_at: %DateTime{}, reset_at: reset_at} = last
    assert reset_at == DateTime.truncate(past, :second)

    assert CredentialHeadroom.last_observed(Budget.token_key("a"), "core") == nil
    assert CredentialHeadroom.last_observed(nil, "graphql") == nil
  end

  test "an error result, a missing token and incomplete headers are all ignored" do
    later = DateTime.add(DateTime.utc_now(), 900)

    assert CredentialHeadroom.observe(%{token: "a"}, {:error, :timeout}) == :ok
    assert CredentialHeadroom.observe(%{url: "https://api.github.com/graphql"}, response("graphql", 5_000, 1, later)) == :ok
    assert CredentialHeadroom.observe(%{token: "a"}, {:ok, %{headers: [{"x-ratelimit-remaining", "1"}]}}) == :ok

    assert CredentialHeadroom.snapshot() == %{}
  end

  test "snapshot groups by credential" do
    later = DateTime.add(DateTime.utc_now(), 900)

    CredentialHeadroom.observe(%{token: "a", url: "https://api.github.com/graphql"}, response("graphql", 5_000, 400, later))

    assert %{"graphql" => %{remaining: 400}} = CredentialHeadroom.snapshot()[Budget.token_key("a")]
  end

  test "a stable credential window survives token rotation" do
    later = DateTime.add(DateTime.utc_now(), 900)
    key = Budget.identity_key("app_installation:1:2:primary")

    CredentialHeadroom.observe(%{token: "old-token", credential_key: key, url: "https://api.github.com/graphql"}, response("graphql", 5_000, 400, later))

    assert %{remaining: 400} = CredentialHeadroom.window(key, "graphql")
    assert %{remaining: 400} = CredentialHeadroom.snapshot()[key]["graphql"]
  end
end
