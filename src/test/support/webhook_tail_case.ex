defmodule Aiur.TestSupport.WebhookTailCase do
  @moduledoc false
  # The boot and seams shared by the suites split out of `github_webhook_test.exs`.
  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised: 1]
  import Aiur.TestSupport, only: [write_workflow_file!: 2, restore_env: 2]

  alias Aiur.Events.{Exchange, Publisher}
  alias Aiur.TestSupport.WebhookPollFixture
  alias Aiur.Webhooks.ModeRegistry
  alias Aiur.Workflow

  @repo "owner/repo"

  defmacro __using__(_opts) do
    quote do
      use Aiur.TestSupport

      import Aiur.TestSupport.WebhookDeliveries
      import Aiur.TestSupport.WebhookTailCase

      setup :webhook_tail_setup
    end
  end

  def webhook_tail_setup(_context) do
    prev_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: @repo,
      tracker_label_prefix: "aiur"
    )

    Publisher.set_tracked_fn(fn _ -> true end)
    WebhookPollFixture.clear_replay_window()

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", prev_token)
      Publisher.set_tracked_fn(fn _ -> true end)
      WebhookPollFixture.clear_replay_window()

      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end
    end)

    :ok
  end

  def start_mode_registry(configured_repos) do
    name = :"webhook_tail_registry_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      start_supervised({ModeRegistry, name: name, configured_repos: configured_repos, silence_threshold_ms: 900_000, sweep_interval_ms: 3_600_000, alert_fun: fn _name, _message, _opts -> :ok end})

    name
  end

  # Test seam for the coalesce window: the production debounce is sized from
  # `polling.interval_seconds` (default 120s => 24s), far too long for a test to
  # wait through. The tail reads an Application override ahead of the computed
  # value, exactly like the receiver's `:webhook_admission_timeout_ms`.
  def override_reconcile_debounce(ms) do
    previous = Application.get_env(:aiur, :github_webhook_reconcile_debounce_ms)
    Application.put_env(:aiur, :github_webhook_reconcile_debounce_ms, ms)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:aiur, :github_webhook_reconcile_debounce_ms)
      else
        Application.put_env(:aiur, :github_webhook_reconcile_debounce_ms, previous)
      end
    end)
  end
end
