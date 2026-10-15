defmodule Aiur.TestSupport.CIPollerFixture do
  @moduledoc false
  import Aiur.TestSupport
  alias Aiur.Events.GithubCIPoller
  alias Aiur.Workflow

  # Shared `setup` for every CI-poller test file.
  def ci_poller_env(_context) do
    previous_token = System.get_env("GITHUB_TOKEN")
    previous_store_path = Application.get_env(:aiur, :ci_approval_store_path)

    store_path =
      Aiur.TestSupport.tmp_root!("github_ci_poller") <> ".json"

    System.put_env("GITHUB_TOKEN", "test-gh-token")
    Application.put_env(:aiur, :ci_approval_store_path, store_path)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "agent"
    )

    ExUnit.Callbacks.on_exit(fn ->
      restore_env("GITHUB_TOKEN", previous_token)

      if is_nil(previous_store_path),
        do: Application.delete_env(:aiur, :ci_approval_store_path),
        else: Application.put_env(:aiur, :ci_approval_store_path, previous_store_path)

      File.rm(store_path)
    end)

    :ok
  end

  def pr_head(ref, sha) do
    %{
      "ref" => ref,
      "sha" => sha,
      "repo" => %{"full_name" => "owner/repo"}
    }
  end

  def poll(targets, opts) do
    GithubCIPoller.poll(targets, Keyword.put_new(opts, :required_check_fetcher, fn _ -> {:ok, []} end))
  end
end
