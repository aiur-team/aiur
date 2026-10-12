defmodule Aiur.RunTelemetry.RepoTimeline.GitHubTest do
  use ExUnit.Case, async: true
  alias Aiur.RunTelemetry.RepoTimeline

  setup do
    directory = Path.join(System.tmp_dir!(), "timeline-github-#{System.unique_integer([:positive])}")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(directory) end)
    {:ok, path: Path.join(directory, "repo-timeline.ndjson")}
  end

  test "nonexistent original PR preserves the revert commit with unknown target", %{path: path} do
    request = fn request ->
      if request.body["variables"]["number"], do: missing(), else: history([revert()], [])
    end

    assert :ok = RepoTimeline.capture(worker(path, request))
    assert [%{"type" => "commit", "sha" => "commit", "revert_of" => nil}] = rows(path)
  end

  test "missing, unsupported and cyclic nested tags preserve commits and valid tags", %{path: path} do
    tags = Enum.map(~w(missing unsupported cycle), &tag(&1, %{"__typename" => "Tag", "oid" => &1}))
    tags = [tag("valid", %{"__typename" => "Commit", "oid" => "commit", "committedDate" => timestamp()}) | tags]

    request = fn request ->
      case request.body["variables"]["oid"] do
        nil -> history([commit()], tags)
        "missing" -> missing()
        "unsupported" -> object(%{"__typename" => "Blob", "oid" => "blob"})
        "cycle" -> object(%{"__typename" => "Tag", "oid" => "cycle"})
      end
    end

    assert :ok = RepoTimeline.capture(worker(path, request))
    assert [%{"type" => "commit", "sha" => "commit"}, %{"type" => "tag", "tag" => "valid", "sha" => "commit"}] = rows(path)
    contents = File.read!(path)
    assert :ok = RepoTimeline.capture(worker(path, request))
    assert File.read!(path) == contents
  end

  test "regression guard: nested tag budget holds remain capture errors", %{path: path} do
    held = {:aiur, :locally_held, %{reason: :shared_budget}}

    request = fn request ->
      if request.body["variables"]["oid"], do: {:error, held}, else: history([commit()], [tag("held", %{"__typename" => "Tag", "oid" => "held"})])
    end

    assert {:error, ^held} = RepoTimeline.capture(worker(path, request))
    refute File.exists?(path)
  end

  test "regression guard: original PR transport errors remain capture errors", %{path: path} do
    request = fn request ->
      if request.body["variables"]["number"], do: {:error, :timeout}, else: history([revert()], [])
    end

    assert {:error, {:github, :timeout, %{reason: :timeout}}} = RepoTimeline.capture(worker(path, request))
    refute File.exists?(path)
  end

  test "regression guard: original PR budget holds remain capture errors", %{path: path} do
    held = {:aiur, :locally_held, %{reason: :shared_budget}}

    request = fn request ->
      if request.body["variables"]["number"], do: {:error, held}, else: history([revert()], [])
    end

    assert {:error, ^held} = RepoTimeline.capture(worker(path, request))
    refute File.exists?(path)
  end

  defp worker(path, request) do
    opts = [name: nil, path: path, repo: "owner/repo", branch: "main", token: "test", request_fun: request, enabled_fun: fn -> true end, boot_capture: false]
    start_supervised!({RepoTimeline, opts}, id: make_ref())
  end

  defp history(commits, tags) do
    history = %{"nodes" => commits, "pageInfo" => %{"hasNextPage" => false}}
    refs = %{"nodes" => tags, "pageInfo" => %{"hasNextPage" => false}}
    response(%{"data" => %{"repository" => %{"ref" => %{"target" => %{"history" => history}}, "refs" => refs}}})
  end

  defp object(target), do: response(%{"data" => %{"repository" => %{"object" => %{"target" => target}}}})
  defp missing, do: response(%{"errors" => [%{"type" => "NOT_FOUND", "message" => "Could not resolve object"}]})
  defp response(body), do: {:ok, %{status: 200, body: body, headers: %{}}}
  defp tag(name, target), do: %{"name" => name, "target" => target}
  defp timestamp, do: "2026-10-09T00:00:01Z"

  defp commit,
    do: %{
      "oid" => "commit",
      "committedDate" => timestamp(),
      "message" => "private",
      "messageHeadline" => "private",
      "associatedPullRequests" => %{"nodes" => []},
      "statusCheckRollup" => %{"state" => "SUCCESS"}
    }

  defp revert, do: Map.put(commit(), "messageHeadline", "Revert \"Original (#123)\"")
  defp rows(path), do: path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
end
