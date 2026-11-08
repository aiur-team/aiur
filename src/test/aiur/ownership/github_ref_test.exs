defmodule Aiur.Ownership.GitHubRefTest do
  use ExUnit.Case, async: true

  alias Aiur.GitHub.ReadCache.Policy
  alias Aiur.Instance.LeaderFence
  alias Aiur.Ownership.{GitHubRef, Record}

  @repo "o/r"
  @ref "refs/aiur/owners/12"

  # In-memory git: blobs/trees/commits plus refs whose updateRefs compare-and-set is one atomic step.
  defmodule Stub do
    @moduledoc false
    use Agent

    alias Aiur.GitHub.Transport

    @zero String.duplicate("0", 40)

    def start, do: Agent.start_link(fn -> %{refs: %{}, objects: %{}, log: [], inject: [], n: 0, barrier: nil, arrived: 0} end)

    def inject(agent, faults), do: Agent.update(agent, &%{&1 | inject: faults})
    def barrier(agent, n), do: Agent.update(agent, &%{&1 | barrier: n})
    def log(agent), do: Agent.get(agent, &Enum.reverse(&1.log))
    def ref(agent, name), do: Agent.get(agent, & &1.refs[name])
    def commit(agent, sha), do: Agent.get(agent, & &1.objects[sha])

    def blob_of(agent, commit_sha) do
      Agent.get(agent, fn s ->
        %{tree: tree} = s.objects[commit_sha]
        s.objects[s.objects[tree].blob].content
      end)
    end

    def put_ref(agent, name, content) do
      Agent.update(agent, fn s ->
        {s, blob} = store(s, "b", %{content: content})
        {s, tree} = store(s, "t", %{blob: blob})
        {s, commit} = store(s, "c", %{tree: tree, parents: []})
        %{s | refs: Map.put(s.refs, name, commit)}
      end)
    end

    def request_fun(agent), do: fn req -> handle(agent, req) end

    defp handle(agent, req) do
      Agent.update(agent, &%{&1 | log: [req | &1.log]})

      cond do
        String.ends_with?(req.url, "/git/blobs") -> object(agent, "b", %{content: req.body["content"]})
        String.ends_with?(req.url, "/git/trees") -> object(agent, "t", %{blob: hd(req.body["tree"])["sha"]})
        String.ends_with?(req.url, "/git/commits") -> object(agent, "c", %{tree: req.body["tree"], parents: req.body["parents"]})
        req.url == Transport.graphql_url() and req.body["query"] =~ "updateRefs" -> update(agent, req.body["variables"]["input"])
        req.url == Transport.graphql_url() -> read(agent, req.body["variables"])
      end
    end

    defp store(s, prefix, object) do
      sha = prefix <> Integer.to_string(s.n)
      {%{s | n: s.n + 1, objects: Map.put(s.objects, sha, object)}, sha}
    end

    defp object(agent, prefix, object) do
      sha = Agent.get_and_update(agent, fn s -> store(s, prefix, object) |> then(fn {s, sha} -> {sha, s} end) end)
      {:ok, %{status: 201, body: %{"sha" => sha}}}
    end

    defp read(agent, %{"qualified" => name}) do
      body =
        Agent.get(agent, fn s ->
          case s.refs[name] do
            nil ->
              %{"id" => "R_stub", "ref" => nil, "object" => nil}

            sha ->
              text = s.objects[s.objects[sha].tree].blob |> then(&s.objects[&1].content)
              %{"id" => "R_stub", "ref" => %{"target" => %{"oid" => sha}}, "object" => %{"text" => text}}
          end
        end)

      {:ok, %{status: 200, body: %{"data" => %{"repository" => body}}}}
    end

    defp update(agent, %{"refUpdates" => [%{"name" => name, "beforeOid" => before, "afterOid" => new}]}) do
      wait_at_barrier(agent)
      fault = Agent.get_and_update(agent, fn s -> {List.first(s.inject), %{s | inject: Enum.drop(s.inject, 1)}} end)

      case fault do
        :timeout_before -> {:error, %Req.TransportError{reason: :timeout}}
        {:status_before, status, message} -> {:ok, %{status: status, headers: %{}, body: %{"message" => message}}}
        _ -> apply_update(agent, fault, name, before, new)
      end
    end

    defp apply_update(agent, fault, name, before, new) do
      result =
        Agent.get_and_update(agent, fn s ->
          current = s.refs[name] || @zero

          if current == before,
            do: {:applied, %{s | refs: Map.put(s.refs, name, new)}},
            else: {if(before == @zero, do: :create_lost, else: :advance_lost), s}
        end)

      case {result, fault} do
        {:applied, :timeout_after} -> {:error, %Req.TransportError{reason: :timeout}}
        {:applied, {:status_after, status}} -> {:ok, %{status: status, headers: %{}, body: %{"message" => "boom"}}}
        {:applied, _} -> {:ok, %{status: 200, body: %{"data" => %{"updateRefs" => %{}}}}}
        # The real loser shapes from MPG-101: a create loser is indistinguishable from a server fault.
        {:create_lost, _} -> errors([%{"message" => "Something went wrong while executing your query on 2026-11-06. Please include `X`"}])
        {:advance_lost, _} -> errors([%{"type" => "UNPROCESSABLE", "message" => "rejecting non-fast forward update"}])
      end
    end

    defp errors(list), do: {:ok, %{status: 200, body: %{"errors" => list}}}

    defp wait_at_barrier(agent) do
      case Agent.get_and_update(agent, fn s -> {s.barrier, %{s | arrived: s.arrived + 1}} end) do
        nil -> :ok
        n -> wait_until(agent, n)
      end
    end

    defp wait_until(agent, n) do
      if Agent.get(agent, & &1.arrived) >= n, do: :ok, else: Process.sleep(5) && wait_until(agent, n)
    end
  end

  @pc %{gateway_id: String.duplicate("a", 26), gateway_label: "pc", daemon_key: "pc", actor: %{kind: "daemon", id: "pc"}, reason: "dispatch"}
  @nook %{@pc | gateway_id: String.duplicate("b", 26), gateway_label: "nook", daemon_key: "nook"}

  setup do
    {:ok, agent} = Stub.start()
    {:ok, agent: agent, opts: [request_fun: Stub.request_fun(agent), token: "t", now: DateTime.utc_now()]}
  end

  defp writes(agent), do: Enum.count(Stub.log(agent), &(&1.method == :post and &1.url =~ "/git/"))
  defp query_has?(req, text), do: is_map(req[:body]) and String.contains?(to_string(req.body["query"]), text)
  defp updates(agent), do: Enum.count(Stub.log(agent), &query_has?(&1, "updateRefs"))

  test "concurrent claims give exactly one winner and one loser", %{agent: agent, opts: opts} do
    Stub.barrier(agent, 2)

    results =
      [@pc, @nook]
      |> Enum.map(&Task.async(fn -> GitHubRef.claim(@repo, "12", &1, opts) end))
      |> Task.await_many()

    assert [{:lost, loser_view}, {:won, %Record{epoch: 1, previous_epoch: 0} = won}] = Enum.sort_by(results, &elem(&1, 0))
    assert loser_view.gateway_id == won.gateway_id
    assert updates(agent) == 2
    # the loser's create error has no type: it was classified by one re-read after the failed write
    assert Enum.count(Stub.log(agent), &query_has?(&1, "ref(qualifiedName")) == 3
    assert Stub.commit(agent, Stub.ref(agent, @ref)).parents == []
  end

  test "a write that applied but timed out is won only because the re-read finds our commit", %{agent: agent, opts: opts} do
    Stub.inject(agent, [:timeout_after])
    assert {:won, %Record{epoch: 1}} = GitHubRef.claim(@repo, "12", @pc, opts)
  end

  test "a timeout before the write applied is unknown, never won", %{agent: agent, opts: opts} do
    Stub.inject(agent, [:timeout_before])
    assert {:unknown, :timeout} = GitHubRef.claim(@repo, "12", @pc, opts)
    assert Stub.ref(agent, @ref) == nil
  end

  test "a 5xx after the write applied is won via the re-read", %{agent: agent, opts: opts} do
    Stub.inject(agent, [{:status_after, 502}])
    assert {:won, _} = GitHubRef.claim(@repo, "12", @pc, opts)
  end

  test "a 422 that did not apply is unknown with the message, never lost", %{agent: agent, opts: opts} do
    Stub.inject(agent, [{:status_before, 422, "Validation Failed"}])
    assert {:unknown, {:http, 422, "Validation Failed"}} = GitHubRef.claim(@repo, "12", @pc, opts)
  end

  test "a 422 that applied is won", %{agent: agent, opts: opts} do
    Stub.inject(agent, [{:status_after, 422}])
    assert {:won, _} = GitHubRef.claim(@repo, "12", @pc, opts)
  end

  test "claim and transfer bump the epoch; a claim of a released ticket continues the epoch", %{agent: agent, opts: opts} do
    {:won, %{epoch: 1}} = GitHubRef.claim(@repo, "12", @pc, opts)
    {:ok, observed} = GitHubRef.read(@repo, "12", opts)
    assert {:won, %Record{epoch: 2, previous_epoch: 1, state: "released", reason: "release"}} = GitHubRef.release(@repo, "12", observed, opts)

    assert {:won, %Record{epoch: 3, previous_epoch: 2, state: "owned", gateway_id: id}} = GitHubRef.claim(@repo, "12", @nook, opts)
    assert id == @nook.gateway_id

    {:ok, observed} = GitHubRef.read(@repo, "12", opts)
    assert {:won, %Record{epoch: 4, previous_epoch: 3, reason: "transfer", daemon_key: "pc"}} = GitHubRef.transfer(@repo, "12", observed, @pc, opts)

    # history is the audit log: every advance has the previous head as its parent
    head = Stub.ref(agent, @ref)
    assert [parent] = Stub.commit(agent, head).parents
    assert Stub.commit(agent, parent).parents != []
  end

  test "a stale beforeOid is lost and leaves the ref alone", %{agent: agent, opts: opts} do
    {:won, _} = GitHubRef.claim(@repo, "12", @pc, opts)
    {:ok, stale} = GitHubRef.read(@repo, "12", opts)
    {:won, %{epoch: 2}} = GitHubRef.transfer(@repo, "12", stale, @nook, opts)
    head = Stub.ref(agent, @ref)

    assert {:lost, %Record{epoch: 2}} = GitHubRef.transfer(@repo, "12", stale, @pc, opts)
    assert Stub.ref(agent, @ref) == head
  end

  test "claims of an owned ticket write nothing; same gateway but another daemon_key loses", %{agent: agent, opts: opts} do
    {:won, record} = GitHubRef.claim(@repo, "12", @pc, opts)
    writes = writes(agent)

    assert {:lost, %Record{gateway_id: id}} = GitHubRef.claim(@repo, "12", @nook, opts)
    assert id == @pc.gateway_id
    assert {:won, ^record} = GitHubRef.claim(@repo, "12", @pc, opts)
    assert {:lost, %Record{daemon_key: "pc"}} = GitHubRef.claim(@repo, "12", %{@pc | daemon_key: "pc-test"}, opts)
    assert writes(agent) == writes
  end

  test "the stored record carries daemon_key beside gateway_id", %{agent: agent, opts: opts} do
    {:won, _} = GitHubRef.claim(@repo, "12", @pc, opts)
    assert {:ok, %Record{daemon_key: "pc", gateway_id: id}} = agent |> Stub.blob_of(Stub.ref(agent, @ref)) |> Record.decode()
    assert id == @pc.gateway_id
  end

  test "a corrupt record is unknown, never absent, and nothing is written", %{agent: agent, opts: opts} do
    Stub.put_ref(agent, @ref, ~s({"schema":"x"}))

    assert {:unknown, {:undecodable, _}} = GitHubRef.read(@repo, "12", opts)
    assert {:unknown, {:undecodable, _}} = GitHubRef.claim(@repo, "12", @pc, opts)
    assert updates(agent) == 0
  end

  test "an invalid ticket is refused before any request", %{agent: agent, opts: opts} do
    assert {:unknown, {:invalid_ticket, "../x"}} = GitHubRef.claim(@repo, "../x", @pc, opts)
    assert Stub.log(agent) == []
  end

  test "pr-anchored tickets use their own ref name", %{agent: agent, opts: opts} do
    assert {:won, _} = GitHubRef.claim(@repo, "pr-45", @pc, opts)
    assert Stub.ref(agent, "refs/aiur/owners/pr-45")
  end

  test "reads bypass the read cache and every request declares its caller", %{agent: agent, opts: opts} do
    GitHubRef.read(@repo, "12", opts)
    GitHubRef.read(@repo, "12", opts)
    {:won, _} = GitHubRef.claim(@repo, "13", @pc, opts)

    [read | _] = Stub.log(agent)
    assert {:no_cache, _} = Policy.classify(read)
    assert Enum.all?(Stub.log(agent), &(&1.caller in ["ownership_ref_read", "ownership_ref_write"]))
    refute LeaderFence.repo_global_write?(%{method: :post, caller: "ownership_ref_write"})
  end

  test "one successful claim of an absent ticket is one read, three objects and one updateRefs", %{agent: agent, opts: opts} do
    {:won, _} = GitHubRef.claim(@repo, "12", @pc, opts)
    assert Stub.log(agent) |> Enum.count() == 1 + 3 + 1
    assert writes(agent) == 3
    assert updates(agent) == 1
  end
end
