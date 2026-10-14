defmodule Aiur.BuildOrder.TicketDetailInputValidationTest do
  use ExUnit.Case, async: false

  alias Aiur.{BuildOrder.TicketDetail, TrackerIdentity}
  alias Aiur.BuildOrder.TicketDetail.{Failure, Snapshot}
  alias Aiur.GitHub.{ReadCache, ResourceStore}

  # `Aiur.GitHub.ResourceStore` is global by design — the whole point is that a
  # resource fetched by one reader satisfies every other — so without this a body
  # stored for issue 42 by one case is served to the next case instead of its own
  # stub, and the stub it injected is never called. The read cache is the same
  # shared app child and now caches `/issues/{n}` reads (`:issue`, #2352), so a
  # transport-backed case (e.g. the oversized-response abort) must not be served
  # a body an earlier case deposited.
  setup do
    ResourceStore.reset()
    ReadCache.reset()
    :ok
  end

  @configured {"owner", "repo"}
  @token_cache_key {Aiur.GitHub.Config, :resolved_token}
  @transport_test_options_key :github_transport_test_options

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:req)
    :ok
  end

  test "uses configured credentials through the default request path" do
    identity = identity(42, "I42")
    previous_token = System.get_env("GITHUB_TOKEN")
    previous_cached_token = :persistent_term.get(@token_cache_key, :unset)
    previous_request_options = Application.get_env(:aiur, @transport_test_options_key, :unset)
    :persistent_term.erase(@token_cache_key)
    System.put_env("GITHUB_TOKEN", "configured-detail-token")
    Application.put_env(:aiur, @transport_test_options_key, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      case previous_token do
        nil -> System.delete_env("GITHUB_TOKEN")
        token -> System.put_env("GITHUB_TOKEN", token)
      end

      case previous_cached_token do
        :unset -> :persistent_term.erase(@token_cache_key)
        token -> :persistent_term.put(@token_cache_key, token)
      end

      case previous_request_options do
        :unset -> Application.delete_env(:aiur, @transport_test_options_key)
        options -> Application.put_env(:aiur, @transport_test_options_key, options)
      end
    end)

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/repos/owner/repo/issues/42"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer configured-detail-token"]
      Req.Test.json(conn, issue(42, "I42"))
    end)

    assert {:ok, %Snapshot{title: "Configured ticket"}} =
             fetch(identity,
               configured_repo: @configured
             )
  end

  test "rejects another repository before the request function is invoked" do
    foreign = identity(42, "Foreign42", {"other", "repo"})

    assert {:error, %Failure{kind: :nonfetchable_repository}} =
             fetch(foreign,
               configured_repo: @configured,
               request_fun: fn _request -> flunk("transport must not be called") end
             )
  end

  test "rejects malformed repository components before the request function is invoked" do
    for {field, value} <- [owner: "owner name", owner: "owner?query", repository: "repo#fragment", repository: ".."] do
      malformed = Map.put(identity(42, "I42"), field, value)

      assert {:error, %Failure{kind: :nonfetchable_repository}} =
               fetch(malformed,
                 configured_repo: @configured,
                 request_fun: fn _request -> flunk("transport must not be called") end
               )
    end

    assert {:error, %Failure{kind: :configuration}} =
             fetch(identity(42, "I42"),
               configured_repo: {"owner?query", "repo"},
               request_fun: fn _request -> flunk("transport must not be called") end
             )
  end

  test "rejects repository delimiters before configuration or provider work" do
    for {field, value} <- [
          owner: "owner/path",
          owner: "owner?query",
          owner: "owner#fragment",
          owner: " owner",
          owner: "owner ",
          owner: ".",
          repository: "repo/path",
          repository: "repo?query",
          repository: "repo#fragment",
          repository: "..",
          repository: String.duplicate("r", 101)
        ] do
      malformed = Map.put(identity(42, "I42"), field, value)

      assert {:error, %Failure{kind: :nonfetchable_repository}} =
               fetch(malformed,
                 configured_repo: fn -> flunk("configuration reader must not be invoked") end,
                 request_fun: fn _request -> flunk("transport must not be called") end
               )
    end
  end

  test "rejects an unjoinable identity before transport work" do
    identity = TrackerIdentity.unjoinable(:legacy, owner: "owner", repository: "repo", identifier: 42)

    assert {:error, %Failure{kind: :nonfetchable_repository}} =
             fetch(identity,
               configured_repo: @configured,
               request_fun: fn _request -> flunk("transport must not be called") end
             )
  end

  test "bounds a ticket identifier before provider URL construction" do
    identity = identity(42, "I42")
    boundary = %{identity | identifier: String.duplicate("9", 19)}
    oversized = %{identity | identifier: String.duplicate("9", 20)}

    assert {:ok, ^boundary, @configured} =
             TicketDetail.fetchable_identity(boundary, configured_repo: @configured)

    assert {:error, %Failure{kind: :nonfetchable_repository}} =
             fetch(oversized,
               configured_repo: @configured,
               request_fun: fn _request -> flunk("transport must not be called") end
             )
  end

  test "does not accept same-number data for a different provider node" do
    identity = identity(42, "I42")

    assert {:error, %Failure{kind: :provider_identity_mismatch}} =
             fetch(identity,
               configured_repo: @configured,
               request_fun: fn _request -> {:ok, %{status: 200, body: issue(42, "OtherNode")}} end
             )
  end

  test "does not accept noncanonical response repository or lifecycle data in a complete snapshot" do
    identity = identity(42, "I42")

    for repository_url <- [
          "https://api.github.com/repos/other/repo",
          "https://user@api.github.com/repos/owner/repo",
          "https://api.github.com:443/repos/owner/repo",
          "https://api.github.com:444/repos/owner/repo",
          "https://api.github.com/not-repos/owner/repo",
          "https://api.github.com/repos/owner/repo/extra",
          "https://api.github.com/repos/owner/repo?private=1",
          "https://api.github.com/repos/owner/repo#fragment"
        ] do
      response = Map.put(issue(42, "I42"), "repository_url", repository_url)

      assert {:error, %Failure{kind: :provider_identity_mismatch}} =
               fetch(identity,
                 configured_repo: @configured,
                 request_fun: fn _request -> {:ok, %{status: 200, body: response}} end
               )
    end

    invalid_lifecycle = Map.put(issue(42, "I42"), "state", "invented")

    assert {:error, %Failure{kind: :validation}} =
             fetch(identity,
               configured_repo: @configured,
               request_fun: fn _request ->
                 {:ok, %{status: 200, body: invalid_lifecycle}}
               end
             )

    for invalid_lifecycle <- [
          Map.delete(issue(42, "I42"), "state"),
          Map.delete(issue(42, "I42"), "state_reason"),
          issue(42, "I42") |> Map.put("state", "open") |> Map.put("state_reason", "completed"),
          issue(42, "I42") |> Map.put("state", "closed") |> Map.put("state_reason", nil)
        ] do
      complete_lifecycle? =
        Map.has_key?(invalid_lifecycle, "state") and
          Map.has_key?(invalid_lifecycle, "state_reason")

      expected_kind = if complete_lifecycle?, do: :validation, else: :schema

      assert {:error, %Failure{kind: ^expected_kind}} =
               fetch(identity,
                 configured_repo: @configured,
                 request_fun: fn _request ->
                   {:ok, %{status: 200, body: invalid_lifecycle}}
                 end
               )
    end
  end

  defp fetch(identity, opts) do
    opts =
      opts
      |> Keyword.put_new(:relationship_reader, fn _identity, _repository ->
        {:ok, %{nodes: [], truncated?: false}}
      end)
      # These cases are about how one response body normalizes, and several of
      # them stub a different body for the *same* issue in the same test. Reads
      # now resolve against the shared store first, so without this the second
      # stub is never reached and the case silently asserts against the first
      # body. `revalidate: true` is the caller saying "actually read it", which
      # is what a normalization test means.
      |> Keyword.put_new(:revalidate, true)

    TicketDetail.fetch(identity, opts)
  end

  defp identity(number, node_id, repository \\ @configured) do
    {:ok, identity} =
      TrackerIdentity.from_github(
        %{"node_id" => node_id, "number" => number},
        repository,
        repository
      )

    identity
  end

  defp issue(number, node_id) do
    %{
      "node_id" => node_id,
      "number" => number,
      "title" => "Configured ticket",
      "body" => "A bounded description",
      "html_url" => "https://github.com/owner/repo/issues/#{number}",
      "repository_url" => "https://api.github.com/repos/owner/repo",
      "state" => "open",
      "state_reason" => nil,
      "created_at" => "2026-07-01T10:00:00Z",
      "updated_at" => "2026-07-02T11:00:00Z"
    }
  end
end
