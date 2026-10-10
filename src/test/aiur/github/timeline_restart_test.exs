defmodule Aiur.GitHub.TimelineRestartTest do
  use Aiur.TestSupport
  alias Aiur.GitHub.{DispatchAuthorization, ResourceStore}
  alias Aiur.Issue

  setup do
    dir = Aiur.TestSupport.tmp_root!("timeline-restart")
    Application.put_env(:aiur, :github_resource_store_path, Path.join(dir, "resources.json"))
    restart_store()
    DispatchAuthorization.clear_cache()

    on_exit(fn ->
      Application.delete_env(:aiur, :github_resource_store_path)
      File.rm_rf!(dir)
    end)

    :ok
  end

  test "first read after restart revalidates persisted provenance and current allowlist" do
    assert authorize(fn _ -> response("trusted") end).dispatch_authorized?
    reboot()

    assert authorize(fn request ->
             assert request.etag == "timeline-v1"
             {:ok, %{status: 304}}
           end).dispatch_authorized?

    refute authorize(fn _ -> flunk("decision already revalidated") end, ["someone-else"]).dispatch_authorized?
  end

  test "changed provenance replaces persisted evidence" do
    assert authorize(fn _ -> response("trusted") end).dispatch_authorized?
    reboot()

    refute authorize(fn request ->
             assert request.etag == "timeline-v1"
             response("outsider")
           end).dispatch_authorized?

    reboot()

    refute authorize(fn request ->
             assert request.etag == "timeline-v1"
             {:ok, %{status: 304}}
           end).dispatch_authorized?
  end

  test "corrupt persisted evidence falls back to an unconditional fetch" do
    key = ResourceStore.key(:issue_timeline, "owner", "repo", 42)
    :ok = ResourceStore.put_resource(key, %{"events" => "corrupt", "single_page" => true, "per_page" => 50}, etag: "bad")
    reboot()

    assert authorize(fn request ->
             refute Map.has_key?(request, :etag)
             response("trusted")
           end).dispatch_authorized?
  end

  test "a scalar corrupt body does not break cold fetch or eviction" do
    key = ResourceStore.key(:issue_timeline, "owner", "repo", 43)
    :ok = ResourceStore.put_resource(key, "corrupt", etag: "bad")
    reboot()

    assert authorize(fn request ->
             refute Map.has_key?(request, :etag)
             response("trusted")
           end).dispatch_authorized?
  end

  test "corrupt nested timeline fields are discarded before revalidation" do
    key = ResourceStore.key(:issue_timeline, "owner", "repo", 42)
    data = %{"events" => [%{"event" => "labeled", "label" => "agent:todo"}], "single_page" => true, "per_page" => 50}
    :ok = ResourceStore.put_resource(key, data, etag: "bad")
    reboot()

    assert authorize(fn request ->
             refute Map.has_key?(request, :etag)
             response("trusted")
           end).dispatch_authorized?
  end

  test "multi-page persisted evidence cannot use a page-one validator" do
    next = ~s(<https://api.github.com/repos/owner/repo/issues/42/timeline?per_page=50&page=2>; rel="next")

    assert authorize(fn request ->
             if request.url =~ "page=2", do: response("trusted"), else: {:ok, %{status: 200, body: [], headers: [{"etag", "timeline-v1"}, {"link", next}]}}
           end).dispatch_authorized?

    reboot()

    refute authorize(fn request ->
             refute Map.has_key?(request, :etag)
             response("outsider")
           end).dispatch_authorized?
  end

  test "truncated conditional response retries a smaller page with fresh evidence" do
    assert authorize(fn _ -> response("trusted") end).dispatch_authorized?
    reboot()

    refute authorize(fn request ->
             if request.url =~ "per_page=50" do
               assert request.etag == "timeline-v1"
               {:ok, %{status: 200, body: ""}}
             else
               assert request.url =~ "per_page=20"
               refute Map.has_key?(request, :etag)
               response("outsider")
             end
           end).dispatch_authorized?
  end

  test "a persisted smaller page is conditional on the first boot read" do
    assert authorize(fn request ->
             if request.url =~ "per_page=50", do: {:ok, %{status: 200, body: ""}}, else: response("trusted")
           end).dispatch_authorized?

    reboot()

    assert authorize(fn request ->
             assert request.url =~ "per_page=20"
             assert request.etag == "timeline-v1"
             {:ok, %{status: 304}}
           end).dispatch_authorized?
  end

  test "durable timeline bodies are bounded and oldest evidence is evicted" do
    for id <- 1..1_000 do
      data = %{"events" => [], "single_page" => true, "per_page" => 50, "stored_at_ms" => id}
      :ok = ResourceStore.put_resource(ResourceStore.key(:issue_timeline, "owner", "repo", id), data, etag: "old")
    end

    :ok = Aiur.GitHub.TimelineCache.put("owner", "repo", "1001", "new", [], true, 50)
    assert ResourceStore.fetch(ResourceStore.key(:issue_timeline, "owner", "repo", 1)) == :miss
    assert {:ok, %{etag: "old"}} = ResourceStore.fetch(ResourceStore.key(:issue_timeline, "owner", "repo", 2))
    assert length(ResourceStore.list_type(:issue_timeline, "owner/repo")) == 1_000
  end

  defp authorize(request_fun, allowed_users \\ ["trusted"]) do
    issue = %Issue{id: "42", identifier: "42", state: "todo", updated_at: ~U[2026-01-01 00:00:00Z]}
    DispatchAuthorization.authorize(issue, "owner", "repo", "agent", token: "test", allowed_users: allowed_users, request_fun: request_fun)
  end

  defp response(actor) do
    event = %{"id" => 10, "event" => "labeled", "label" => %{"name" => "agent:todo"}, "actor" => %{"login" => actor}, "created_at" => "2026-01-01T00:00:00Z"}
    {:ok, %{status: 200, body: [event], headers: [{"etag", "timeline-v1"}]}}
  end

  defp reboot do
    :ok = ResourceStore.flush()
    restart_store()
    DispatchAuthorization.clear_cache()
  end

  defp restart_store do
    :ok = Supervisor.terminate_child(Aiur.Supervisor, ResourceStore)
    {:ok, _} = Supervisor.restart_child(Aiur.Supervisor, ResourceStore)
  end
end
