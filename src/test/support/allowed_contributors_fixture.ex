defmodule Aiur.AllowedContributorsFixture do
  @moduledoc false
  # A fake GitHub for allowed-contributor intake tests: serves an allow-list
  # body from the default branch only, and answers org membership from a
  # mutable table. Every request is reported to the owning test process.

  @sha String.duplicate("c", 40)
  @head String.duplicate("e", 40)

  @spec sha() :: String.t()
  def sha, do: @sha

  @spec head() :: String.t()
  def head, do: @head

  @doc """
  Starts an intake server against the fake. Options: `:body` (allow-list
  text, or `:absent`), `:members` (`%{{org_login, user_login} => response}`),
  `:rate_limit`, `:aiur_logins`. The clock starts at the real wall time; move it with `advance/2`.
  Returns `{server, agent}`; update the agent to change GitHub's answers.
  """
  @spec start(map(), keyword()) :: {pid(), pid()}
  def start(context, opts \\ []) do
    test = self()
    {:ok, gh} = Agent.start_link(fn -> %{body: Keyword.get(opts, :body, "user 42\n"), members: Keyword.get(opts, :members, %{}), now: System.os_time(:millisecond)} end)
    dir = Path.join(System.tmp_dir!(), "aiur-ac-#{System.unique_integer([:positive])}")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    _ = context

    server =
      ExUnit.Callbacks.start_supervised!(
        {Aiur.AllowedContributors,
         name: nil,
         repo: {"acme", "app"},
         state_dir: Keyword.get(opts, :state_dir, dir),
         refresh_ms: :infinity,
         rate_limit: Keyword.get(opts, :rate_limit, 5),
         token_fun: fn -> "token" end,
         request_fun: fn req -> answer(gh, test, req) end,
         publish_fun: Keyword.get(opts, :publish_fun, fn topic, payload, popts -> send(test, {:published, topic, payload, popts}) && {:ok, 1, 1} end),
         alert_fun: fn name, message, _opts -> send(test, {:alert, name, message}) && :ok end,
         clock_fun: fn -> Agent.get(gh, & &1.now) end,
         aiur_logins_fun: fn -> Keyword.get(opts, :aiur_logins, ["aiur-bot", "aiur-daemon[bot]"]) end},
        id: Keyword.get(opts, :id, make_ref())
      )

    {server, gh}
  end

  @doc "Moves the fake's wall clock forward by `ms`."
  @spec advance(pid(), integer()) :: :ok
  def advance(gh, ms), do: Agent.update(gh, &%{&1 | now: &1.now + ms})

  @doc "A candidate as the webhook producer would build it."
  @spec candidate(keyword()) :: map()
  def candidate(fields \\ []) do
    Map.merge(
      %{
        number: 101,
        author_id: 42,
        author_login: "alice",
        author_type: "User",
        via_app?: false,
        created_at: DateTime.utc_now(),
        source: :webhook
      },
      Map.new(fields)
    )
  end

  @doc "A member response for `user_id` in org `org_id`."
  @spec member(pos_integer(), pos_integer(), String.t()) :: {:ok, map()}
  def member(org_id, user_id, state \\ "active"),
    do: {:ok, %{status: 200, body: %{"state" => state, "user" => %{"id" => user_id}, "organization" => %{"id" => org_id}}}}

  defp answer(gh, test, %{url: url} = req) do
    send(test, {:github_get, url})
    state = Agent.get(gh, & &1)

    cond do
      String.ends_with?(url, "/repos/acme/app") -> {:ok, %{status: 200, body: %{"default_branch" => "main"}}}
      String.ends_with?(url, "/branches/main") -> {:ok, %{status: 200, body: %{"commit" => %{"sha" => @head}}}}
      url =~ "/commits?sha=#{@head}&" -> commits(state.body)
      url =~ "/contents/.github/ALLOWED-CONTRIBUTORS?ref=#{@head}" -> contents(state.body)
      # Any other ref (a PR head, a fork, a same-named tag) serves an attacker's list.
      url =~ "/contents/" -> {:ok, %{status: 200, body: file("user 666\n")}}
      url =~ "/memberships/" -> membership(state.members, url)
      true -> {:error, {:unexpected_request, req}}
    end
  end

  defp commits(:absent), do: {:ok, %{status: 200, body: []}}
  defp commits({:error, _} = error), do: error
  defp commits(_body), do: {:ok, %{status: 200, body: [%{"sha" => @sha}]}}

  defp contents(body) when is_binary(body), do: {:ok, %{status: 200, body: file(body)}}

  defp membership(members, url) do
    [org, user] = url |> String.split("/orgs/") |> List.last() |> String.split("/memberships/")
    Map.get(members, {org, user}, {:ok, %{status: 404}})
  end

  defp file(body), do: %{"type" => "file", "encoding" => "base64", "content" => Base.encode64(body)}
end
