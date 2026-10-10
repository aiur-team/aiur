defmodule Aiur.Events.GithubWebhookWakeTest do
  @moduledoc """
  When a delivery wakes the dispatcher, and how wakes coalesce. Split out of
  `github_webhook_test.exs`.
  """

  use Aiur.TestSupport.WebhookTailCase

  alias Aiur.Events.GithubWebhook
  alias Aiur.Events.GithubWebhookWakeTest.OrchestratorWakeProbe

  @repo "owner/repo"

  describe "state-owned events reconcile rather than publishing a parallel shape" do
    test "a reconcile delivery wakes the dispatcher once per quiet period" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      GithubWebhook.reset_reconcile_window()
      on_exit(&GithubWebhook.reset_reconcile_window/0)

      delivery = %{
        "action" => "labeled",
        "repository" => %{"full_name" => @repo},
        "issue" => %{"number" => String.to_integer(ticket), "updated_at" => "2026-06-24T12:00:00Z"}
      }

      request_refresh_fun = fn -> send(self(), :request_refresh) end

      for _ <- 1..3 do
        assert %{status: :reconciled} =
                 GithubWebhook.handle_delivery("issues", delivery, repo: @repo, request_refresh_fun: request_refresh_fun)
      end

      # A burst of N deliveries in one second produces one wake, not N.
      assert_receive :request_refresh, 500
      refute_receive :request_refresh, 200
    end

    test "a PR state change publish wakes the dispatcher" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      ticket_topic = "ticket.#{ticket}.pr.opened"
      GithubWebhook.reset_reconcile_window()
      on_exit(&GithubWebhook.reset_reconcile_window/0)

      request_refresh_fun = fn -> send(self(), :request_refresh) end

      delivery = %{
        "action" => "opened",
        "repository" => %{"full_name" => @repo},
        "sender" => %{"login" => "its-everdred"},
        "pull_request" => %{"number" => 901, "head" => %{"ref" => "aiur/#{ticket}-slug", "sha" => "abc123"}}
      }

      assert %{status: :published, published: [^ticket_topic]} =
               GithubWebhook.handle_delivery("pull_request", delivery, repo: @repo, request_refresh_fun: request_refresh_fun)

      assert_receive :request_refresh, 500
    end

    test "a PR merge publish wakes the dispatcher" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      ticket_topic = "ticket.#{ticket}.pr.merged"
      GithubWebhook.reset_reconcile_window()
      on_exit(&GithubWebhook.reset_reconcile_window/0)

      request_refresh_fun = fn -> send(self(), :request_refresh) end

      delivery = %{
        "action" => "closed",
        "repository" => %{"full_name" => @repo},
        "sender" => %{"login" => "its-everdred"},
        "pull_request" => %{
          "number" => 901,
          "merged" => true,
          "head" => %{"ref" => "aiur/#{ticket}-slug", "sha" => "abc123"},
          "updated_at" => "2026-06-24T12:00:00Z"
        }
      }

      assert %{status: :published, published: [^ticket_topic]} =
               GithubWebhook.handle_delivery("pull_request", delivery, repo: @repo, request_refresh_fun: request_refresh_fun)

      assert_receive :request_refresh, 500
    end

    test "a comment publish does not wake the dispatcher" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      ticket_topic = "ticket.#{ticket}.issue.commented"
      GithubWebhook.reset_reconcile_window()
      on_exit(&GithubWebhook.reset_reconcile_window/0)

      request_refresh_fun = fn -> send(self(), :request_refresh) end

      assert %{status: :published, published: [^ticket_topic]} =
               GithubWebhook.handle_delivery("issue_comment", issue_comment_delivery(ticket),
                 repo: @repo,
                 request_refresh_fun: request_refresh_fun
               )

      refute_receive :request_refresh, 200
    end

    test "a newly-opened ticket that already carries an active state label wakes the dispatcher" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      GithubWebhook.reset_reconcile_window()
      on_exit(&GithubWebhook.reset_reconcile_window/0)

      request_refresh_fun = fn -> send(self(), :request_refresh) end

      delivery = %{
        "action" => "opened",
        "repository" => %{"full_name" => @repo},
        "issue" => %{
          "number" => String.to_integer(ticket),
          "updated_at" => "2026-06-24T12:00:00Z",
          "labels" => [%{"name" => "aiur:todo"}]
        }
      }

      assert %{status: :reconciled, hint: %{kind: :issue_state, ticket: ^ticket, action: "opened"}} =
               GithubWebhook.handle_delivery("issues", delivery, repo: @repo, request_refresh_fun: request_refresh_fun)

      assert_receive :request_refresh, 500
    end

    test "a newly-opened issue with no actionable label is dropped and never wakes" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      GithubWebhook.reset_reconcile_window()
      on_exit(&GithubWebhook.reset_reconcile_window/0)

      request_refresh_fun = fn -> send(self(), :request_refresh) end

      delivery = %{
        "action" => "opened",
        "repository" => %{"full_name" => @repo},
        "issue" => %{"number" => String.to_integer(ticket), "updated_at" => "2026-06-24T12:00:00Z", "labels" => [%{"name" => "size:s"}]}
      }

      assert %{status: :dropped, reason: {:uninteresting_action, "issues", "opened"}} =
               GithubWebhook.handle_delivery("issues", delivery, repo: @repo, request_refresh_fun: request_refresh_fun)

      refute_receive :request_refresh, 200
    end

    test "a delivery with the default wake never raises, whatever the orchestrator answers" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      GithubWebhook.reset_reconcile_window()
      on_exit(&GithubWebhook.reset_reconcile_window/0)

      delivery = %{
        "action" => "labeled",
        "repository" => %{"full_name" => @repo},
        "issue" => %{"number" => String.to_integer(ticket)}
      }

      # The default `request_refresh_fun` is `Orchestrator.request_refresh/0`.
      # Against the live supervised orchestrator (running in the test app) it
      # succeeds; had the orchestrator been down it would return `:unavailable`
      # instead of raising (that unavailable path, and the window release that
      # goes with it, is pinned by "a wake that fails to land does not consume
      # the coalesce window"). Either way the delivery must not error.
      assert %{status: :reconciled} = GithubWebhook.handle_delivery("issues", delivery, repo: @repo)
    end

    # Blocking review finding #1: every other wake test injects
    # `:request_refresh_fun`, so the production default — the one behaviour that
    # distinguishes this wake from the raw `:run_poll_cycle` send it replaced —
    # was never executed by anything, and a mutant reverting the default to the
    # old `send(Process.whereis(Aiur.Orchestrator), :run_poll_cycle)` survived
    # the whole suite. This test runs the real default against a stand-in
    # registered as `Aiur.Orchestrator` (the live supervised orchestrator is
    # temporarily unregistered and restored on exit, the same swap
    # `agent_chat_broadcast_test` performs for its fake) and asserts the wake is
    # a `:request_refresh` GenServer call, not a raw `:run_poll_cycle` message.
    test "the real default wake is a request_refresh call, never a raw run_poll_cycle send" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      GithubWebhook.reset_reconcile_window()
      on_exit(&GithubWebhook.reset_reconcile_window/0)

      original = Process.whereis(Aiur.Orchestrator)
      if is_pid(original), do: Process.unregister(Aiur.Orchestrator)

      # `start_link` registers the probe under `Aiur.Orchestrator` now that the
      # live orchestrator has been unregistered for the duration of this test.
      {:ok, probe} = OrchestratorWakeProbe.start_link(self())
      Process.unlink(probe)

      on_exit(fn ->
        # Synchronous stop (unlike `Process.exit/2`, which is async and can
        # still hold the name when the live orchestrator is re-registered) so
        # the probe's registration is actually released first, then restore.
        if Process.alive?(probe) do
          try do
            GenServer.stop(probe)
          catch
            :exit, _ -> :ok
          end
        end

        if Process.whereis(Aiur.Orchestrator) == probe, do: Process.unregister(Aiur.Orchestrator)

        if is_pid(original) do
          try do
            Process.register(original, Aiur.Orchestrator)
          rescue
            ArgumentError -> :ok
          end
        end
      end)

      delivery = %{
        "action" => "labeled",
        "repository" => %{"full_name" => @repo},
        "issue" => %{"number" => String.to_integer(ticket)}
      }

      assert %{status: :reconciled} =
               GithubWebhook.handle_delivery("issues", delivery, repo: @repo)

      assert_receive :request_refresh_called, 500
      refute_receive :run_poll_cycle_received, 200
    end

    # Non-blocking review finding #4: the leading-edge coalesce folds every
    # delivery inside the window into the leading cycle, so state deposited just
    # after that cycle read would otherwise wait out the full poll interval. A
    # trailing wake at window close picks it up.
    test "a delivery folded into the coalesce window still gets a trailing wake" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      GithubWebhook.reset_reconcile_window()
      on_exit(&GithubWebhook.reset_reconcile_window/0)
      override_reconcile_debounce(200)

      # The trailing wake fires from a spawned process, so the seam must send to
      # an explicit pid rather than `self()` (which would resolve to the spawned
      # process and lose the message).
      parent = self()
      request_refresh_fun = fn -> send(parent, :request_refresh) end

      delivery = %{
        "action" => "labeled",
        "repository" => %{"full_name" => @repo},
        "issue" => %{"number" => String.to_integer(ticket), "updated_at" => "2026-06-24T12:00:00Z"}
      }

      # Leading edge: the first delivery wakes immediately.
      assert %{status: :reconciled} =
               GithubWebhook.handle_delivery("issues", delivery, repo: @repo, request_refresh_fun: request_refresh_fun)

      assert_receive :request_refresh, 500

      # A second delivery inside the window deposits its state and is coalesced.
      assert %{status: :reconciled} =
               GithubWebhook.handle_delivery("issues", delivery, repo: @repo, request_refresh_fun: request_refresh_fun)

      refute_receive :request_refresh, 100

      # At window close the trailing wake fires, so the second delivery's
      # deposit is acted on before the next scheduled tick.
      assert_receive :request_refresh, 1_000
    end

    # Blocking review finding #3, second half: the coalesce window is sized from
    # the poll cadence (`interval_seconds / 5`, floored at 2s) rather than being
    # a flat 2s, which is what bounds sustained webhook traffic to a fixed
    # multiple of the poll rate instead of a 60x amplification. Every other wake
    # test either injects the Application override or runs inside a single
    # window, so a mutant collapsing the sizing back to the flat floor survived
    # them all. This test reads the *computed* window: with a 15s poll interval
    # the window is 3s, so a delivery at 2.4s — past the flat floor, inside the
    # sized window — must still coalesce.
    test "the coalesce window is sized from the poll interval, not a flat floor" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      GithubWebhook.reset_reconcile_window()
      on_exit(&GithubWebhook.reset_reconcile_window/0)

      # No Application override: this test must exercise the computed branch.
      previous = Application.get_env(:aiur, :github_webhook_reconcile_debounce_ms)
      Application.delete_env(:aiur, :github_webhook_reconcile_debounce_ms)

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:aiur, :github_webhook_reconcile_debounce_ms)
        else
          Application.put_env(:aiur, :github_webhook_reconcile_debounce_ms, previous)
        end
      end)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: @repo,
        tracker_label_prefix: "aiur",
        poll_interval_seconds: 15
      )

      assert Aiur.Config.settings!().polling.interval_seconds == 15

      # The trailing wake fires from a spawned process, so the seam must send to
      # an explicit pid rather than `self()`.
      parent = self()
      request_refresh_fun = fn -> send(parent, :request_refresh) end

      delivery = %{
        "action" => "labeled",
        "repository" => %{"full_name" => @repo},
        "issue" => %{"number" => String.to_integer(ticket), "updated_at" => "2026-06-24T12:00:00Z"}
      }

      assert %{status: :reconciled} =
               GithubWebhook.handle_delivery("issues", delivery, repo: @repo, request_refresh_fun: request_refresh_fun)

      assert_receive :request_refresh, 500
      # Past a flat 2s floor, still inside the 3s window the 15s poll interval
      # implies. A flat-floor mutant claims a fresh leading edge here and wakes.
      Process.sleep(2_400)

      assert %{status: :reconciled} =
               GithubWebhook.handle_delivery("issues", delivery, repo: @repo, request_refresh_fun: request_refresh_fun)

      refute_receive :request_refresh, 300
    end

    # Non-blocking review finding #4: a wake that fails to land (the orchestrator
    # is not running) used to consume the coalesce window, so the failure also
    # suppressed the next window's worth of wakes. Releasing the window on
    # failure lets the next delivery retry.
    test "a wake that fails to land does not consume the coalesce window" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      GithubWebhook.reset_reconcile_window()
      on_exit(&GithubWebhook.reset_reconcile_window/0)
      override_reconcile_debounce(60_000)
      parent = self()

      request_refresh_fun = fn ->
        send(parent, :request_refresh_attempted)
        :unavailable
      end

      delivery = %{
        "action" => "labeled",
        "repository" => %{"full_name" => @repo},
        "issue" => %{"number" => String.to_integer(ticket)}
      }

      assert %{status: :reconciled} =
               GithubWebhook.handle_delivery("issues", delivery, repo: @repo, request_refresh_fun: request_refresh_fun)

      assert_receive :request_refresh_attempted, 500
      # With a 60s window a stuck failed claim would coalesce this second
      # delivery; the release means it claims a fresh leading edge and wakes.
      assert %{status: :reconciled} =
               GithubWebhook.handle_delivery("issues", delivery, repo: @repo, request_refresh_fun: request_refresh_fun)

      assert_receive :request_refresh_attempted, 500
    end
  end
end

defmodule Aiur.Events.GithubWebhookWakeTest.OrchestratorWakeProbe do
  @moduledoc """
  Stand-in registered as `Aiur.Orchestrator` so the delivery tail's *default*
  wake (`Orchestrator.request_refresh/0`) has a real process to call. Records a
  `:request_refresh` GenServer call as `:request_refresh_called` and a raw
  `:run_poll_cycle` message as `:run_poll_cycle_received`, so a test can tell
  the two wake shapes apart — the mutant that reverts the default to a raw
  `:run_poll_cycle` send would fail the `refute_receive`., 100
  """
  use GenServer
  # `start_link/1` is the conventional constructor, not a GenServer callback.
  def start_link(test) do
    GenServer.start_link(__MODULE__, test, name: Aiur.Orchestrator)
  end

  @impl true
  def init(test), do: {:ok, test}
  @impl true
  def handle_call(:request_refresh, _from, test) do
    send(test, :request_refresh_called)
    {:reply, %{queued: true, coalesced: false, requested_at: DateTime.utc_now(), operations: ["poll", "reconcile"]}, test}
  end

  # While the probe briefly holds the `Aiur.Orchestrator` name, any unrelated
  # caller must get a fast reply rather than a 5s GenServer timeout.
  @impl true
  def handle_call(_request, _from, test), do: {:reply, :unavailable, test}
  @impl true
  def handle_info(:run_poll_cycle, test) do
    send(test, :run_poll_cycle_received)
    {:noreply, test}
  end

  @impl true
  def handle_info(_message, test), do: {:noreply, test}
end
