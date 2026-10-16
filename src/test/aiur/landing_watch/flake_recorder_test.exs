defmodule Aiur.LandingWatch.FlakeRecorderTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch.FlakeRecorder

  test "creates a labeled identity issue and emits the same evidence durably" do
    parent = self()
    journal = temp_path("flake-create")
    failure = %{module: "ExampleTest", name: "sometimes fails", job: "test", excerpt: "assertion failed at test/example_test.exs:12"}
    run = %{"id" => 804}

    request = fn
      %{method: :get, url: url} ->
        parsed = URI.parse(url)
        query = URI.decode_query(parsed.query || "")

        if parsed.path == "/search/issues" and query["per_page"] == "100" and
             query["q"] =~ "repo:test-org/test-repo is:issue in:body" and
             query["q"] =~ Base.encode16(:crypto.hash(:sha256, "ExampleTest :: sometimes fails"), case: :lower) and
             not Map.has_key?(query, "labels") do
          {:ok, %{status: 200, body: %{"items" => []}}}
        else
          flunk("expected bounded identity search, got #{url}")
        end

      %{method: :post, url: url, body: body} ->
        if String.contains?(url, "/issues/") do
          flunk("unexpected POST #{url}")
        else
          send(parent, {:created, body})
          {:ok, %{status: 201, body: %{"number" => 992}}}
        end
    end

    alert = fn topic, opts ->
      send(parent, {:alert, topic, opts})
      :ok
    end

    assert :ok = FlakeRecorder.record(failure, run, [17, 24], token: "test-gh-token", request_fun: request, journal_path: journal, alert_emitter: alert)
    assert_received {:created, body}
    assert body["title"] == "Flaky test: ExampleTest :: sometimes fails"
    assert body["labels"] == ["bug", "agent:todo", "priority:1"]
    assert body["body"] =~ "Run ID: 804"
    assert body["body"] =~ "Job: test"
    assert body["body"] =~ "Failing test: ExampleTest :: sometimes fails"
    assert body["body"] =~ "Error excerpt: assertion failed"
    assert body["body"] =~ "PRs that passed this test in another merge group containing the PR: #17, #24"

    assert_received {:alert, "system.pr.landing.flake_recorded", alert_opts}
    assert Keyword.fetch!(alert_opts, :durable)
    assert Keyword.fetch!(alert_opts, :exchange_payload)["flake_evidence"] == String.replace(body["body"], ~r/\A<!--.*?-->\n\n/s, "")
    File.rm(journal)
  end

  test "comments on an existing identity issue and keeps the evidence intact" do
    parent = self()
    journal = temp_path("flake-comment")
    identity = "ExampleTest :: retries"
    marker = "<!-- aiur-flake-key: #{Base.encode16(:crypto.hash(:sha256, identity), case: :lower)} -->"

    existing = %{
      "number" => 301,
      "body" => marker <> "\n\nold evidence",
      "labels" => [%{"name" => "bug"}, %{"name" => "agent:in-progress"}]
    }

    failure = %{module: "ExampleTest", name: "retries", job: "unit tests", excerpt: "runner exited early"}

    request = fn
      %{method: :get, url: url} ->
        parsed = URI.parse(url)
        query = URI.decode_query(parsed.query || "")

        if parsed.path == "/search/issues" and query["per_page"] == "100" and
             query["q"] =~ "repo:test-org/test-repo is:issue in:body" and
             query["q"] =~ Base.encode16(:crypto.hash(:sha256, identity), case: :lower) and
             not Map.has_key?(query, "labels") do
          {:ok, %{status: 200, body: %{"items" => [existing], "total_count" => 1}}}
        else
          flunk("expected bounded identity search, got #{url}")
        end

      %{method: :post, url: url, body: body} ->
        if String.contains?(url, "/issues/301/comments") do
          send(parent, {:comment, body["body"]})
          {:ok, %{status: 201, body: %{}}}
        else
          flunk("unexpected POST #{url}")
        end
    end

    assert :ok = FlakeRecorder.record(failure, %{"id" => 805}, [17], token: "test-gh-token", request_fun: request, journal_path: journal, alert_emitter: fn _, _ -> :ok end)
    assert_received {:comment, body}
    assert body =~ "Run ID: 805"
    assert body =~ "Job: unit tests"
    assert body =~ "Failing test: ExampleTest :: retries"
    assert body =~ "Error excerpt: runner exited early"
    assert body =~ "#17"
    File.rm(journal)
  end

  defp temp_path(prefix), do: Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}.json")
end
