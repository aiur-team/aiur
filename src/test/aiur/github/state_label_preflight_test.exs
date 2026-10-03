defmodule Aiur.GitHub.StateLabelPreflightTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.Labels
  alias Aiur.GitHub.StateLabelPreflight

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "sym"
    )

    :ok
  end

  defp labels_response(names), do: {:ok, %{status: 200, body: Enum.map(names, &%{"name" => &1})}}

  test "reports the required state labels the repo does not carry" do
    parent = self()

    request_fun = fn request ->
      send(parent, {:request, request})
      labels_response(["bug", "sym:todo", "sym:done"])
    end

    assert {:ok, result} = StateLabelPreflight.check(request_fun: request_fun)

    assert result.repo == "owner/repo"
    assert Enum.sort(result.present) == ["sym:done", "sym:todo"]
    assert Enum.sort(result.missing) == Enum.sort(Labels.state_labels("sym") -- ["sym:todo", "sym:done"])
    refute "sym:todo" in result.missing

    assert_receive {:request, %{method: :get, url: url, token: "test-gh-token", timeout_ms: 10_000}}
    assert url =~ "/repos/owner/repo/labels?per_page=100&page=1"
  end

  test "the scan stops after ten full pages so a huge label set cannot hold the orchestrator" do
    parent = self()

    request_fun = fn %{url: url} ->
      send(parent, {:page, url})
      labels_response(Enum.map(1..100, &"filler-#{&1}"))
    end

    assert {:ok, %{missing: missing}} = StateLabelPreflight.check(request_fun: request_fun)
    assert missing == Labels.state_labels("sym")

    pages =
      Stream.repeatedly(fn ->
        receive do
          {:page, url} -> url
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(&(&1 != nil))

    assert length(pages) == 10
    assert List.last(pages) =~ "page=10"
  end

  test "an empty missing list means every state label exists, across pages" do
    parent = self()
    page_one = Enum.map(1..100, &"filler-#{&1}")

    request_fun = fn %{url: url} ->
      send(parent, {:page, url})

      if String.ends_with?(url, "page=1"),
        do: labels_response(page_one),
        else: labels_response(Labels.state_labels("sym"))
    end

    assert {:ok, %{missing: []}} = StateLabelPreflight.check(request_fun: request_fun)
    assert_receive {:page, url_one}
    assert_receive {:page, url_two}
    assert url_one =~ "page=1"
    assert url_two =~ "page=2"
  end

  test "a failed list call is an error, never a missing-label report" do
    assert {:error, {:github_api_status, 403}} = StateLabelPreflight.check(request_fun: fn _ -> {:ok, %{status: 403, body: %{}}} end)
    assert {:error, {:github_api_request, :econnrefused}} = StateLabelPreflight.check(request_fun: fn _ -> {:error, :econnrefused} end)
  end

  test "format_missing names the repo, each label, and a gh command per label" do
    text = StateLabelPreflight.format_missing(%{repo: "owner/repo", missing: ["sym:todo", "sym:rework"], present: []})

    assert text =~ "owner/repo is missing the workflow state labels sym:todo, sym:rework"
    assert text =~ "No ticket can be labelled into the workflow until they exist"
    assert text =~ "gh label create 'sym:todo' --repo owner/repo --description 'ready to be worked' --force"
    assert text =~ "gh label create 'sym:rework' --repo owner/repo"
  end
end
