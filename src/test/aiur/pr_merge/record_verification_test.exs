defmodule Aiur.PrMerge.RecordVerificationTest do
  use ExUnit.Case, async: true
  alias Aiur.PrMerge.Record
  @head String.duplicate("a", 40)
  @merged String.duplicate("b", 40)

  defp encoded(changes \\ %{}) do
    %{repo: "owner/repo", pr: 9, sha: @head, merged_sha: @merged, actor: "forged", policy: "forged"}
    |> Map.merge(changes)
    |> Jason.encode!()
    |> Base.encode64()
  end

  defp raw(changes \\ %{}) do
    %{
      "merged" => true,
      "state" => "closed",
      "head" => %{"sha" => @head},
      "merge_commit_sha" => @merged,
      "base" => %{"ref" => "main"},
      "merged_by" => %{"login" => "actual-operator"},
      "merged_at" => "2026-10-11T01:00:00Z"
    }
    |> Map.merge(changes)
  end

  defp options(response) do
    parent = self()

    [
      settings: fn -> {:ok, %{tracker: %{github: %{repo: "owner/repo"}, base_branch: "main"}}} end,
      token: "daemon-read-token",
      request_fun: fn request ->
        send(parent, {:verification_request, request.url})
        response
      end,
      publish: fn topic, record, _opts ->
        send(parent, {:published, topic, record})
        {:ok, "event-id", 1}
      end
    ]
  end

  test "local merge JSON publishes only the independently verified GitHub outcome" do
    assert :ok = Record.verify_and_publish(encoded(), options({:ok, %{status: 200, body: raw()}}))
    assert_received {:verification_request, "https://api.github.com/repos/owner/repo/pulls/9"}
    assert_received {:published, "system.pr.merged", %{actor: "actual-operator", state: "merged", sha: @head, merged_sha: @merged} = event}
    refute Map.has_key?(event, :policy)
  end

  test "unmerged, mismatched and unobservable GitHub state never publishes a merge" do
    for response <- [
          {:ok, %{status: 200, body: raw(%{"merged" => false})}},
          {:ok, %{status: 200, body: raw(%{"head" => %{"sha" => "different-head"}})}},
          {:ok, %{status: 200, body: raw(%{"merge_commit_sha" => "different-merge"})}},
          {:ok, %{status: 200, body: raw(%{"base" => %{"ref" => "other-base"}})}},
          {:error, :unavailable}
        ] do
      assert {:error, :unverified_merge} = Record.verify_and_publish(encoded(), options(response))
      refute_receive {:published, _, _}, 0
    end
  end

  test "malformed or other-repository local JSON refuses before any verification request" do
    opts = options({:ok, %{status: 200, body: raw()}})

    for value <- ["invalid-base64", encoded(%{repo: "other/repo"}), encoded(%{pr: -1})] do
      assert {:error, :unverified_merge} = Record.verify_and_publish(value, opts)
      refute_receive {:verification_request, _}, 0
      refute_receive {:published, _, _}, 0
    end
  end
end
