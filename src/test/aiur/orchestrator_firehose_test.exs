defmodule Aiur.OrchestratorFirehoseTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator
  alias Aiur.Workflow

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "aiur"
    )

    on_exit(fn -> restore_env("GITHUB_TOKEN", prev_token) end)

    :ok
  end

  test "orchestrator preserves the GitHub firehose event watermark" do
    page_1 = ignored_events("burst", 30)
    page_2 = [ignored_event("last-seen")]
    parent = self()

    stub = fn req ->
      page = request_page(req)
      send(parent, {:events_page_requested, page})

      body =
        case page do
          "1" -> page_1
          "2" -> page_2
        end

      {:ok, %{status: 200, headers: [{"ETag", ~s("next-etag")}], body: body}}
    end

    state = %Orchestrator.State{
      events_etag: ~s("previous-etag"),
      events_last_id: "last-seen"
    }

    next = Orchestrator.poll_github_firehose_for_test(state, request_fun: stub)

    assert next.events_etag == ~s("next-etag")
    assert next.events_last_id == "burst-1"
    assert_receive {:events_page_requested, "1"}
    assert_receive {:events_page_requested, "2"}
  end

  defp request_page(%{url: url}) do
    url
    |> URI.parse()
    |> Map.fetch!(:query)
    |> URI.decode_query()
    |> Map.fetch!("page")
  end

  defp ignored_events(prefix, count) do
    Enum.map(1..count, &ignored_event("#{prefix}-#{&1}"))
  end

  defp ignored_event(id) do
    %{
      "id" => id,
      "type" => "IssuesEvent",
      "actor" => %{"login" => "noise"},
      "repo" => %{"name" => "owner/repo"},
      "payload" => %{}
    }
  end
end
