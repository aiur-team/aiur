defmodule Aiur.GitHub.LabelCatalogueTest do
  use Aiur.TestSupport
  alias Aiur.GitHub.LabelCatalogue

  setup do
    LabelCatalogue.reset()
    on_exit(&LabelCatalogue.reset/0)
    :ok
  end

  defp label(name, description), do: %{"name" => name, "description" => description, "color" => "5319e7"}

  defp page(labels), do: {:ok, %{status: 200, body: labels, headers: []}}

  defp refresh(labels_by_page, send_to \\ self()) do
    LabelCatalogue.refresh(
      owner: "owner",
      repo: "repo",
      token: "test-token",
      base_url: "https://api.example.test",
      request_fun: fn request ->
        send(send_to, {:label_page, request.url})
        labels_by_page.(request.url)
      end
    )
  end

  test "a refresh reads every page and records only labels that carry a description" do
    full = for index <- 1..100, do: label("bulk:#{index}", "Bulk label #{index}")

    pages = fn
      "https://api.example.test/repos/owner/repo/labels?per_page=100&page=1" ->
        page([label("feature:mp-e7", "Feature collection: MP-E7 listener modes (steer, sync, async)") | full])

      "https://api.example.test/repos/owner/repo/labels?per_page=100&page=2" ->
        page([label("feature:mp-n1", "Feature collection: MP-N1 phone app shell"), label("no-description", nil), label("empty-description", "")])
    end

    assert :ok = refresh(pages)
    assert_received {:label_page, "https://api.example.test/repos/owner/repo/labels?per_page=100&page=1"}
    assert_received {:label_page, "https://api.example.test/repos/owner/repo/labels?per_page=100&page=2"}
    refute_received {:label_page, _}

    assert {:ok, descriptions, taken_at_ms} = LabelCatalogue.fetch("owner", "repo", 60_000)
    assert descriptions["feature:mp-e7"] == "Feature collection: MP-E7 listener modes (steer, sync, async)"
    assert descriptions["feature:mp-n1"] == "Feature collection: MP-N1 phone app shell"
    assert descriptions["bulk:100"] == "Bulk label 100"
    refute Map.has_key?(descriptions, "no-description")
    refute Map.has_key?(descriptions, "empty-description")
    assert is_integer(taken_at_ms)
  end

  test "a failed page leaves the previous catalogue in place" do
    assert :ok = refresh(fn _url -> page([label("feature:mp-e7", "Listener modes")]) end)
    assert {:ok, %{"feature:mp-e7" => "Listener modes"}, _taken} = LabelCatalogue.fetch("owner", "repo", 60_000)

    failing = fn
      "https://api.example.test/repos/owner/repo/labels?per_page=100&page=1" -> page(for i <- 1..100, do: label("bulk:#{i}", "Bulk #{i}"))
      _second_page -> {:error, :timeout}
    end

    assert {:error, _reason} = refresh(failing)
    assert {:ok, %{"feature:mp-e7" => "Listener modes"} = descriptions, _taken} = LabelCatalogue.fetch("owner", "repo", 60_000)
    refute Map.has_key?(descriptions, "bulk:1")
  end

  test "a read older than the caller's bound answers none so the chain falls back" do
    assert :ok = LabelCatalogue.record("owner", "repo", %{"feature:mp-e7" => "Listener modes"}, System.system_time(:millisecond) - 120_000)

    assert :none = LabelCatalogue.fetch("owner", "repo", 60_000)
    assert {:ok, %{"feature:mp-e7" => "Listener modes"}, _taken} = LabelCatalogue.fetch("owner", "repo", 300_000)
  end

  test "an unknown repository answers none rather than an empty catalogue" do
    assert :none = LabelCatalogue.fetch("owner", "other", 60_000)
  end

  test "a successful refresh broadcasts the change for the build index" do
    Phoenix.PubSub.subscribe(Aiur.PubSub, LabelCatalogue.topic())
    assert :ok = refresh(fn _url -> page([label("feature:mp-e7", "Listener modes")]) end)
    assert_received {:label_catalogue_changed, taken_at_ms} when is_integer(taken_at_ms)
  end

  test "fetch/1 reads the configured repository" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "agent"
    )

    assert :ok = LabelCatalogue.record("owner", "repo", %{"feature:mp-e7" => "Listener modes"})
    assert {:ok, %{"feature:mp-e7" => "Listener modes"}, _taken} = LabelCatalogue.fetch(60_000)
  end
end
