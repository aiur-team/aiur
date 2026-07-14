defmodule Aiur.Orchestrator.ControlLifecycleTest do
  use ExUnit.Case, async: true

  alias Aiur.TrackerIdentity
  alias Aiur.Orchestrator.ControlLifecycle

  @now ~U[2026-07-13 12:00:00Z]

  test "a request becomes applied only after its accepted generation acknowledges it" do
    lifecycle = ControlLifecycle.new(now: @now)

    {:ok, requested, lifecycle} =
      ControlLifecycle.request(lifecycle, request_attrs(request_id: "pause-1", generation: "worker-1"), now: @now)

    assert requested.status == :requested

    {:ok, accepted, lifecycle} = ControlLifecycle.accept(lifecycle, "pause-1", "worker-1", now: @now)
    assert accepted.status == :accepted

    assert {:ignored, ^lifecycle} = ControlLifecycle.apply(lifecycle, "pause-1", "worker-2", now: @now)

    {:ok, applied, _lifecycle} = ControlLifecycle.apply(lifecycle, "pause-1", "worker-1", now: @now)
    assert applied.status == :applied
    assert applied.applied_at == @now
  end

  test "a same-id retry is idempotent and never creates a second request" do
    lifecycle = ControlLifecycle.new(now: @now)
    attrs = request_attrs(request_id: "pause-1")

    {:ok, requested, lifecycle} = ControlLifecycle.request(lifecycle, attrs, now: @now)
    {:duplicate, duplicate, lifecycle} = ControlLifecycle.request(lifecycle, attrs, now: DateTime.add(@now, 1, :second))

    assert duplicate == requested
    assert ControlLifecycle.history(lifecycle, "issue-1") == [requested]
  end

  test "a conflicting new action explicitly supersedes an older pending request" do
    lifecycle = ControlLifecycle.new(now: @now)

    {:ok, _pause, lifecycle} =
      ControlLifecycle.request(lifecycle, request_attrs(request_id: "pause-1", action: :pause), now: @now)

    {:ok, resume, lifecycle} =
      ControlLifecycle.request(lifecycle, request_attrs(request_id: "resume-1", action: :resume), now: @now)

    assert resume.status == :requested
    assert %{status: :rejected, rejection: %{class: :superseded}} = ControlLifecycle.get(lifecycle, "pause-1")
    assert ControlLifecycle.current_pending(lifecycle, "issue-1").request_id == "resume-1"
  end

  test "a request with non-joinable tracker identity is rejected without entering history" do
    lifecycle = ControlLifecycle.new(now: @now)

    attrs =
      request_attrs(tracker_identity: TrackerIdentity.unjoinable(:legacy, identifier: "101"))

    assert {:error, %{class: :not_eligible}, ^lifecycle} = ControlLifecycle.request(lifecycle, attrs, now: @now)
    assert ControlLifecycle.history(lifecycle, "issue-1") == []
  end

  test "expired and restart recovery requests cannot later apply" do
    lifecycle = ControlLifecycle.new(now: @now)

    {:ok, _requested, lifecycle} =
      ControlLifecycle.request(lifecycle, request_attrs(request_id: "pause-1"), now: @now)

    {:ok, _accepted, lifecycle} = ControlLifecycle.accept(lifecycle, "pause-1", "worker-1", now: @now)
    {:ok, expired, lifecycle} = ControlLifecycle.expire(lifecycle, "pause-1", :timeout, now: @now)

    assert expired.status == :expired
    assert expired.expiry.reason == :timeout
    assert {:ignored, ^lifecycle} = ControlLifecycle.apply(lifecycle, "pause-1", "worker-1", now: @now)

    {:ok, _requested, lifecycle} =
      ControlLifecycle.request(lifecycle, request_attrs(request_id: "resume-1", action: :resume), now: @now)

    {recovered, lifecycle} = ControlLifecycle.expire_unresolved(lifecycle, :daemon_restart, now: @now)

    assert [%{request_id: "resume-1", status: :expired, expiry: %{reason: :daemon_restart}}] = recovered
    assert %{status: :expired} = ControlLifecycle.get(lifecycle, "resume-1")
  end

  test "bounded acknowledgement windows expire only overdue unresolved requests" do
    lifecycle = ControlLifecycle.new(now: @now)
    {:ok, _request, lifecycle} = ControlLifecycle.request(lifecycle, request_attrs(request_id: "pause-1"), now: @now)

    {expired, lifecycle} = ControlLifecycle.expire_due(lifecycle, 1_000, now: DateTime.add(@now, 1, :second))
    assert expired == []
    assert %{status: :requested} = ControlLifecycle.get(lifecycle, "pause-1")

    {[expired], lifecycle} = ControlLifecycle.expire_due(lifecycle, 1_000, now: DateTime.add(@now, 2, :second))
    assert %{request_id: "pause-1", status: :expired, expiry: %{reason: :timeout}} = expired
    assert %{status: :expired} = ControlLifecycle.get(lifecycle, "pause-1")
  end

  test "routing failure rejects the pending request with a stable class" do
    lifecycle = ControlLifecycle.new(now: @now)

    {:ok, _request, lifecycle} =
      ControlLifecycle.request(lifecycle, request_attrs(request_id: "pause-1"), now: @now)

    {:ok, rejected, lifecycle} =
      ControlLifecycle.reject(lifecycle, "pause-1", :worker_unavailable, now: @now)

    assert rejected.status == :rejected
    assert rejected.rejection.class == :worker_unavailable
    assert is_nil(ControlLifecycle.current_pending(lifecycle, "issue-1"))
    assert {:ignored, ^lifecycle} = ControlLifecycle.apply(lifecycle, "pause-1", "worker-1", now: @now)
  end

  test "events use an allowlist and do not expose sensitive request metadata" do
    lifecycle = ControlLifecycle.new(now: @now)

    attrs =
      request_attrs(
        request_id: "pause-1",
        metadata: %{workspace_path: "/private/workspace", token: "secret", capability_url: "https://example.test"}
      )

    {:ok, request, _lifecycle} = ControlLifecycle.request(lifecycle, attrs, now: @now)
    payload = ControlLifecycle.event_payload(request)

    assert payload.request_id == "pause-1"
    assert payload.action == :pause
    refute Map.has_key?(payload, :metadata)
    refute inspect(payload) =~ "workspace"
    refute inspect(payload) =~ "secret"
    refute inspect(payload) =~ "capability"
  end

  defp request_attrs(overrides) do
    defaults = %{
      request_id: "request-1",
      issue_id: "issue-1",
      tracker_identity: tracker_identity(),
      action: :pause,
      generation: "worker-1",
      expected_status: :working,
      expected_version: 3,
      requester: :operator
    }

    Map.merge(defaults, Map.new(overrides))
  end

  defp tracker_identity do
    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: "its-everdred",
      repository: "aiur",
      provider_id: "I_kwDOissue1",
      identifier: "101",
      reason: nil
    }
  end
end
