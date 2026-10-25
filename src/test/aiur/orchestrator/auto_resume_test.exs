defmodule Aiur.Orchestrator.AutoResumeTest do
  use Aiur.TestSupport

  import Aiur.Orchestrator.AutoResumeTestSupport

  alias Aiur.Orchestrator.{AutoResume, Dispatcher, State}

  @issue_id "issue-transient"
  @enabled enabled_config()

  setup :auto_resume_setup

  describe "classify/1" do
    test "classifies transient tracker failures" do
      assert AutoResume.classify({:github, :rate_limited, %{status: 403}}) == :rate_limit
      assert AutoResume.classify({:github, :timeout, %{reason: :timeout}}) == :transient_tracker
      assert AutoResume.classify({:github, :transport, %{reason: :econnrefused}}) == :transient_tracker
      assert AutoResume.classify({:github, :http, %{status: 500}}) == :transient_tracker
    end

    test "classifies provider timeouts" do
      assert AutoResume.classify(:timeout) == :provider_timeout
      assert AutoResume.classify({:error, :timeout}) == :provider_timeout
      assert AutoResume.classify({:timeout, %{url: "x"}}) == :provider_timeout
    end

    # #2429 / #2427: a DNS transport failure (`:nxdomain`) is transient, but the
    # raw shapes bypass `Errors.retryable_github_error?/1` (which only recognizes
    # the classified `{:github, kind, _}` tuple). A retry-exhausted ticket must
    # auto-resume once DNS recovers instead of parking in `agent:error` — closing
    # the `AutoResume.classify/1` vs `Errors`/`HumanReview` taxonomy disagreement
    # the project owner flagged on #2431.
    test "classifies a DNS transport failure as transient" do
      assert AutoResume.classify(:nxdomain) == :transient_tracker
      assert AutoResume.classify({:error, :nxdomain}) == :transient_tracker
      assert AutoResume.classify({:error, %Req.TransportError{reason: :nxdomain}}) == :transient_tracker
      assert AutoResume.classify(%Req.TransportError{reason: :nxdomain}) == :transient_tracker
      assert AutoResume.classify({:github, :dns, %{reason: :nxdomain}}) == :transient_tracker

      assert AutoResume.classify({:workspace_github_connectivity_failed, "/workspaces/123", {:github, :dns, %{reason: :nxdomain}}}) == :transient_tracker

      assert AutoResume.classify({:workspace_github_connectivity_failed, "/workspaces/123", {:error, %Req.TransportError{reason: :nxdomain}}}) == :transient_tracker
    end

    # #2427 review: a raw `%Req.TransportError{}` (the shape the transport
    # error funnel surfaces) is normalised through the shared taxonomy before
    # classifying, so a reason the shared classifier calls transient always
    # schedules a re-claim. `:nxdomain` is the regression: it is transient to
    # the shared classifier but was never in the provider-timeout whitelist,
    # so the raw struct used to classify as `nil` (no re-claim).
    test "classifies a raw transport struct through the shared taxonomy" do
      assert AutoResume.classify(%Req.TransportError{reason: :closed}) == :transient_tracker
      assert AutoResume.classify(%Req.TransportError{reason: :nxdomain}) == :transient_tracker
      assert AutoResume.classify(%Req.TransportError{reason: :econnrefused}) == :transient_tracker
      assert AutoResume.classify(%Req.TransportError{reason: {:tls_alert, :handshake_failure}}) == :transient_tracker
      assert AutoResume.classify(%Req.TransportError{reason: :timeout}) == :transient_tracker
    end

    # #2409: a local GitHub budget hold is a transient infrastructure fault, so
    # a ticket parked in `agent:error` by one auto-resumes once the hold lifts
    # instead of waiting for an operator. Recognized in the raw
    # `{:aiur, :locally_held, hold}` shape, the `:local_hold` classification
    # `Errors.classify_error` now assigns (#2429), the legacy
    # transport-classified shape a tracker poll used to see, and the wrapped
    # shapes an agent exits with when its workspace preflight is held (#2339).
    test "classifies a local GitHub budget hold as transient" do
      hold = %{reason: :shared_budget, resource: "core", reset_at: DateTime.add(DateTime.utc_now(), 30, :second)}

      assert AutoResume.classify({:aiur, :locally_held, hold}) == :local_budget_hold
      assert AutoResume.classify({:github, :local_hold, %{reason: {:aiur, :locally_held, hold}, hold: hold}}) == :local_budget_hold
      assert AutoResume.classify({:github, :transport, %{reason: {:aiur, :locally_held, hold}}}) == :local_budget_hold

      assert AutoResume.classify(
               {:workspace_github_connectivity_failed, "/workspaces/2339", {:github_auth_preflight_failed, %{classification: :local_hold, detail: %{reason: {:aiur, :locally_held, hold}, hold: hold}}}}
             ) == :local_budget_hold

      assert AutoResume.classify({:workspace_github_connectivity_failed, "/workspaces/2339", {:aiur, :locally_held, hold}}) == :local_budget_hold
    end

    # #2361: a preflight that dies on a transport fault surfaces as
    # `{:github_auth_preflight_failed, diagnostic}` with the taxonomy embedded
    # in `detail` (or a raw 408/429/5xx `status`). The claim-release path feeds
    # this reason to `classify/1`, and it must auto-resume on it rather than
    # treat the ticket as a genuine agent failure parked with no scheduled
    # re-claim.
    test "classifies an auth-preflight transport failure as transient" do
      assert AutoResume.classify({:github_auth_preflight_failed, %{detail: {:github, :timeout, %{reason: :closed}}}}) ==
               :transient_tracker

      assert AutoResume.classify({:github_auth_preflight_failed, %{detail: {:github, :transport, %{reason: :econnrefused}}}}) ==
               :transient_tracker

      assert AutoResume.classify({:github_auth_preflight_failed, %{reason: :http_status, status: 502}}) == :transient_tracker
      assert AutoResume.classify({:github_auth_preflight_failed, %{reason: :http_status, status: 500}}) == :transient_tracker

      assert AutoResume.classify({:github_auth_preflight_failed, %{reason: :invalid_or_expired_token, status: 401}}) == nil
    end

    test "returns nil for terminal and operator causes" do
      assert AutoResume.classify({:github, :auth, %{status: 401}}) == nil
      assert AutoResume.classify({:github, :permission, %{status: 403}}) == nil
      assert AutoResume.classify({:github, :http, %{status: 403}}) == nil
      assert AutoResume.classify(:operator_pause) == nil
      assert AutoResume.classify(nil) == nil
    end
  end

  describe "schedule/3" do
    test "records a pending resume and reports the backoff" do
      state = AutoResume.schedule(%State{}, @issue_id, :rate_limit)

      assert %{attempt: 1, cause: :rate_limit} = state.auto_resume[@issue_id]
      assert AutoResume.retry_in_ms(state, @issue_id, System.monotonic_time(:millisecond)) <= 120_000
      assert AutoResume.retry_in_ms(state, @issue_id, System.monotonic_time(:millisecond)) > 0
    end

    test "honors a rate-limit retry-after before attempting re-claim" do
      state = AutoResume.schedule(%State{}, @issue_id, :rate_limit, retry_after: 600)

      assert AutoResume.retry_in_ms(state, @issue_id, System.monotonic_time(:millisecond)) > 590_000
    end

    test "advances through the bounded backoff schedule" do
      state = %State{}
      assert AutoResume.backoff_ms(1) == 120_000
      assert AutoResume.backoff_ms(2) == 300_000
      assert AutoResume.backoff_ms(3) == 900_000

      # A fourth schedule drops the entry (bounded at max_attempts).
      max_attempts = AutoResume.max_attempts()

      state =
        Enum.reduce(1..max_attempts, state, fn _i, acc ->
          AutoResume.schedule(acc, @issue_id, :transient_tracker)
        end)

      assert %{attempt: ^max_attempts} = state.auto_resume[@issue_id]

      state = AutoResume.schedule(state, @issue_id, :transient_tracker)
      refute Map.has_key?(state.auto_resume, @issue_id)
    end

    test "keeps the released-claim record when automatic recovery exhausts" do
      state = %State{released_claims: %{@issue_id => %{cause: :rate_limit, details: %{}, released_at_ms: 1}}}

      state =
        Enum.reduce(1..(AutoResume.max_attempts() + 1), state, fn _i, acc ->
          AutoResume.schedule(acc, @issue_id, :rate_limit)
        end)

      refute Map.has_key?(state.auto_resume, @issue_id)
      assert %{cause: :rate_limit} = state.released_claims[@issue_id]
    end

    test "exhausting the attempt budget emits the operator alert the docstring promises" do
      # #1453 review P2a: `schedule/3` documents "an operator alert is emitted"
      # once the bounded budget is spent, but the original implementation only
      # logged. Exhaustion must surface as a needs-attention alert so a parked
      # ticket is diagnosable rather than silently dropped.
      parent = self()

      state =
        Enum.reduce(1..AutoResume.max_attempts(), %State{}, fn _i, acc ->
          AutoResume.schedule(acc, @issue_id, :rate_limit)
        end)

      state =
        AutoResume.schedule(state, @issue_id, :rate_limit, fn name, opts ->
          send(parent, {:exhaustion_alert, name, opts})
          :ok
        end)

      assert_receive {:exhaustion_alert, "ticket.#{@issue_id}.agent.auto_resume_exhausted", opts}, 1000
      assert Keyword.get(opts, :needs_attention) == true
      refute Map.has_key?(state.auto_resume, @issue_id)
    end
  end

  describe "Dispatcher.auto_resume_admission/1" do
    @tag config: @enabled
    test "holds during a global pause" do
      assert {:hold, :global_pause} = Dispatcher.auto_resume_admission(%State{globally_paused: true})
    end

    @tag config: @enabled
    test "holds at concurrent-agent capacity" do
      state = %State{
        max_concurrent_agents: 1,
        running: %{"other" => %{control: %{status: :working}}}
      }

      assert {:hold, :max_concurrent_agents} = Dispatcher.auto_resume_admission(state)
    end

    @tag config: @enabled
    test "admits a free-capacity, unpaused fleet without host-pressure holds" do
      # Pin the host probes so the result does not depend on the CI host's live
      # load/FD sample; with free capacity the mirror of the normal admission
      # path admits, so the auto-resume can dispatch.
      Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "0.0 0.0 0.0 1/1 1\n"} end)

      Application.put_env(:aiur, :file_descriptor_sample_override, fn ->
        %{pid: "1", used: 10, limit: 100_000, available: 99_990, headroom_ratio: 0.9999}
      end)

      on_exit(fn ->
        Application.delete_env(:aiur, :loadavg_source_override)
        Application.delete_env(:aiur, :file_descriptor_sample_override)
      end)

      assert :dispatch = Dispatcher.auto_resume_admission(%State{})
    end
  end
end
