defmodule Aiur.TestSupport.DepositCase do
  @moduledoc false
  # The boot and read-through shared by the suites split out of `deposit_test.exs`.
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]
  import Aiur.TestSupport, only: [write_workflow_file!: 2, restore_env: 2]

  alias Aiur.Events.{Exchange, Publisher}
  alias Aiur.GitHub.{ResourceFetch, ResourceStore}
  alias Aiur.TestSupport.WebhookPollFixture
  alias Aiur.Workflow

  @repo "owner/repo"
  @bot "its-applekid"

  defmacro __using__(_opts) do
    quote do
      use Aiur.TestSupport
      use Aiur.TestSupport.EventTicket
      import Aiur.TestSupport.DepositFixture
      import Aiur.TestSupport.DepositCase
      import Aiur.TestSupport.WebhookPollFixture, only: [await_event: 1, refute_event: 1, restart_store!: 1, sweep: 1, clear_replay_window: 0]

      setup :deposit_setup
    end
  end

  def deposit_setup(_context) do
    prev_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: @repo,
      tracker_label_prefix: "aiur",
      tracker_bot_account: @bot
    )

    Publisher.set_tracked_fn(fn _ -> true end)
    WebhookPollFixture.clear_replay_window()
    ResourceStore.reset()

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", prev_token)
      Publisher.set_tracked_fn(fn _ -> true end)
      WebhookPollFixture.clear_replay_window()
      Application.delete_env(:aiur, :github_resource_store_path)

      if is_nil(Process.whereis(ResourceStore)) do
        Supervisor.restart_child(Aiur.Supervisor, ResourceStore)
      end

      ResourceStore.reset()

      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end)

    :ok
  end

  # The read-through a consumer performs: consult the store, and call the fetcher
  # only on a miss. The fetcher stands in for the upstream read — every
  # invocation of it is one request the consumer had to pay for — so the count it
  # returns is the number of upstream calls serving this resource cost.
  # Goes through the real read-before-spend path rather than a `case` the test
  # wrote for itself. That distinction is the whole assertion: counting a
  # test-local closure only ever proves `ResourceStore.fetch/1` did not miss,
  # whereas `ResourceFetch.need/3`'s fetcher is the one seam an upstream request
  # would actually leave through — so a zero here is a zero on the rate limit.
  def read_through(key) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    fetcher = fn _opts ->
      Agent.update(counter, &(&1 + 1))
      {:ok, :fetched_from_github}
    end

    {:ok, body, meta} = ResourceFetch.need(key, fetcher, freshness: :any)

    calls = Agent.get(counter, & &1)
    Agent.stop(counter)

    # `spent?` and the call count are two independent witnesses of the same
    # fact; they must never disagree.
    assert meta.spent? == calls > 0

    {calls, body}
  end
end
