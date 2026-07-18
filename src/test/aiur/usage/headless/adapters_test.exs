defmodule Aiur.Usage.Headless.AdaptersTest do
  use ExUnit.Case, async: true

  alias Aiur.{TrackerIdentity, UsageEnvelope}
  alias Aiur.Usage.Headless.{Catalog, Compatibility, Context, Normalizer}
  alias Aiur.Usage.Headless.Claude.RequestUsage
  alias Aiur.Usage.Headless.Codex.{ThreadUsage, TurnUsage}
  alias Aiur.UsageEnvelope.RelationshipRegistry

  @ingested_at ~U[2026-07-17 12:00:02Z]
  @fixtures Path.join(["test", "fixtures", "usage", "headless"])

  describe "Codex thread (absolute) source" do
    test "maps the cumulative counter as an absolute thread envelope pinned to its revision" do
      {payload, raw} = fixture("codex-app-server-2026-07-token-count.json")

      assert [{:ok, envelope}] = ThreadUsage.extract(payload, raw, context(), @ingested_at)

      assert envelope.provider == :codex
      assert envelope.source == "codex.app_server.thread_token_usage"
      assert envelope.source_version == "codex-app-server-2026-07"
      assert envelope.measurement_kind == :absolute
      assert envelope.counter_scope == :thread
      assert envelope.update_kind == :full
      assert envelope.relationship_revision == "codex-thread-usage-2026-07"

      assert envelope.tokens == %{
               input: 1200,
               cached_input: 400,
               cache_creation_input: nil,
               output: 300,
               reasoning_output: 120,
               provider_reported_total: 1500
             }

      # No trusted provider occurrence time exists on this source; it stays unknown.
      assert envelope.occurred_at == nil
      assert :missing_trusted_occurrence_time in envelope.coverage_reasons

      assert {:ok, %{canonical_total: 1500, input_total: 1200, output_total: 300, status: :authoritative, coverage: :full}} =
               UsageEnvelope.reconcile(envelope, Catalog.relationship_catalog())
    end
  end

  describe "Codex overlapping absolute and delta streams" do
    test "emits two distinct envelopes so DASH-009 never sums them as independent" do
      {payload, raw} = fixture("codex-app-server-2026-07-token-count.json")

      assert %{envelopes: envelopes, coverages: []} = Normalizer.normalize(payload, raw, context(), @ingested_at)
      assert length(envelopes) == 2

      [absolute, delta] = Enum.sort_by(envelopes, &Atom.to_string(&1.measurement_kind))

      assert absolute.measurement_kind == :absolute
      assert absolute.counter_scope == :thread
      assert absolute.tokens.provider_reported_total == 1500

      assert delta.measurement_kind == :delta
      assert delta.counter_scope == :turn
      assert delta.tokens.provider_reported_total == 280

      assert absolute.source != delta.source
      refute absolute.idempotency_key == delta.idempotency_key
      refute absolute.counter_epoch == delta.counter_epoch
    end

    test "turn/completed usage maps to a turn-scoped delta only" do
      {payload, raw} = fixture("codex-app-server-2026-07-turn-completed.json")

      assert [] = ThreadUsage.extract(payload, raw, context(), @ingested_at)
      assert [{:ok, delta}] = TurnUsage.extract(payload, raw, context(), @ingested_at)
      assert delta.measurement_kind == :delta
      assert delta.counter_scope == :turn
      assert delta.tokens.input == 210
      assert delta.tokens.provider_reported_total == 300
    end
  end

  describe "Claude request source" do
    test "maps additive cache dimensions and an exact-decimal cost preserved from raw JSON" do
      {payload, raw} = fixture("claude-app-server-2026-07-turn-completed.json")

      assert [{:ok, envelope}] = RequestUsage.extract(payload, raw, claude_context(), @ingested_at)

      assert envelope.provider == :claude
      assert envelope.source == "claude.app_server.turn_completion"
      assert envelope.measurement_kind == :delta

      assert envelope.tokens == %{
               input: 100,
               cached_input: 30,
               cache_creation_input: 20,
               output: 10,
               reasoning_output: nil,
               provider_reported_total: nil
             }

      assert Decimal.equal?(envelope.cost.amount, Decimal.new("0.0001234567890123456789"))
      assert envelope.cost.currency == "USD"
      assert envelope.cost.measurement_kind == :delta
      assert envelope.cost.source == "claude.app_server.turn_completion.cost_usd"

      assert {:ok, %{canonical_total: 160, input_total: 150, output_total: 10, status: :derived, coverage: :full}} =
               UsageEnvelope.reconcile(envelope, Catalog.relationship_catalog())
    end

    test "missing cache dimensions stay nil and mark partial coverage rather than zero" do
      payload = %{"method" => "turn/completed", "params" => %{"usage" => %{"input_tokens" => 100, "output_tokens" => 10}}}
      raw = Jason.encode!(payload)

      assert [{:ok, envelope}] = RequestUsage.extract(payload, raw, claude_context(), @ingested_at)
      assert envelope.update_kind == :partial
      assert envelope.tokens.cached_input == nil
      assert envelope.tokens.cache_creation_input == nil
      refute envelope.tokens.cached_input == 0
      assert :partial_update in envelope.coverage_reasons
      assert envelope.cost == nil
    end
  end

  describe "relationship revision pinning" do
    test "an unknown revision cannot publish a canonical derived total or pricing input" do
      {payload, raw} = fixture("codex-app-server-2026-07-token-count.json")
      [{:ok, envelope}] = ThreadUsage.extract(payload, raw, context(), @ingested_at)

      assert {:ok, %{status: :authoritative}} = UsageEnvelope.reconcile(envelope, Catalog.relationship_catalog())

      {:ok, empty_catalog} = RelationshipRegistry.new([])
      assert {:ok, reconciliation} = UsageEnvelope.reconcile(envelope, empty_catalog)
      assert reconciliation.canonical_total == nil
      assert reconciliation.coverage == :unknown
      assert :missing_historic_relationship_revision in reconciliation.coverage_reasons
    end
  end

  describe "source version drift" do
    test "a drifted installed revision yields bounded coverage instead of current semantics" do
      {payload, raw} = fixture("codex-app-server-2026-07-token-count.json")
      drifted = context(observed_source_version: "codex-app-server-2099-01")

      assert %{envelopes: [], coverages: coverages} = Normalizer.normalize(payload, raw, drifted, @ingested_at)
      assert length(coverages) == 2
      assert Enum.all?(coverages, &(&1.class == :unsupported_source_revision))
      assert Enum.all?(coverages, &(&1.field == :source_version))
    end
  end

  describe "identity and account-generation attribution" do
    test "consumes trusted identity and a known generation" do
      {payload, raw} = fixture("codex-app-server-2026-07-token-count.json")
      [{:ok, envelope}] = ThreadUsage.extract(payload, raw, context(), @ingested_at)

      assert envelope.attribution.run_id == "run-1133"
      assert envelope.attribution.attempt_id == "attempt-1"
      assert envelope.attribution.tracker_identity == tracker_identity()
      assert envelope.auth_mode == :chatgpt
      assert envelope.account_generation.generation == "gen-known"
      assert envelope.account_generation.freshness == :current
    end

    test "an unknown generation stays explicit and rotates the raw identity" do
      {payload, raw} = fixture("codex-app-server-2026-07-token-count.json")
      [{:ok, known}] = ThreadUsage.extract(payload, raw, context(), @ingested_at)
      [{:ok, unknown}] = ThreadUsage.extract(payload, raw, context(account_generation: unknown_generation(:codex)), @ingested_at)

      assert unknown.account_generation.generation == nil
      assert unknown.account_generation.reason == :owner_unavailable
      assert :unknown_account_generation in unknown.coverage_reasons
      refute known.idempotency_key == unknown.idempotency_key
    end

    test "missing trusted identity stays missing rather than fabricated" do
      {payload, raw} = fixture("codex-app-server-2026-07-token-count.json")
      bare = context(tracker_identity: nil, attempt_id: nil, session_id: nil)

      [{:ok, envelope}] = ThreadUsage.extract(payload, raw, bare, @ingested_at)
      assert envelope.attribution.tracker_identity == nil
      assert envelope.attribution.attempt_id == nil
      assert envelope.attribution.session_id == nil
    end

    test "retry keeps identity stable while a new attempt or run rotates it" do
      {payload, raw} = fixture("codex-app-server-2026-07-token-count.json")

      [{:ok, first}] = ThreadUsage.extract(payload, raw, context(), @ingested_at)
      [{:ok, retry}] = ThreadUsage.extract(payload, raw, context(), @ingested_at)
      assert first.idempotency_key == retry.idempotency_key
      assert first.counter_epoch == retry.counter_epoch

      [{:ok, new_attempt}] = ThreadUsage.extract(payload, raw, context(attempt_id: "attempt-2"), @ingested_at)
      refute first.idempotency_key == new_attempt.idempotency_key
      refute first.counter_epoch == new_attempt.counter_epoch

      [{:ok, new_run}] = ThreadUsage.extract(payload, raw, context(run_id: "run-2"), @ingested_at)
      refute first.counter_epoch == new_run.counter_epoch
    end
  end

  describe "compatibility projection" do
    test "preserves the transient token shape and keeps canonicalize alive" do
      {payload, raw} = fixture("codex-app-server-2026-07-token-count.json")
      [{:ok, envelope}] = ThreadUsage.extract(payload, raw, context(), @ingested_at)

      assert {:ok, projection} = Compatibility.project(envelope)
      assert projection.input_tokens == 1200
      assert projection.output_tokens == 300
      assert projection.total_tokens == 1500

      # The legacy contract zero-fills; the envelope must not, and does not.
      assert Compatibility.canonical(%{"input_tokens" => 5}) == %{input_tokens: 5, output_tokens: 0, total_tokens: 0}
      assert envelope.tokens.cache_creation_input == nil
    end
  end

  describe "redaction" do
    test "provider payload, prompts, and local paths never enter the envelope" do
      {payload, _raw} = fixture("codex-app-server-2026-07-token-count.json")

      payload =
        payload
        |> put_in(["params", "prompt"], "SECRET-PROMPT-BODY")
        |> Map.put("workspace", "/Users/secret/workspace/path")

      raw = Jason.encode!(payload)
      [{:ok, envelope}] = ThreadUsage.extract(payload, raw, context(), @ingested_at)

      dump = inspect(envelope, limit: :infinity)
      refute dump =~ "SECRET-PROMPT-BODY"
      refute dump =~ "/Users/secret/workspace/path"
    end
  end

  defp fixture(name) do
    raw = @fixtures |> Path.join(name) |> File.read!()
    {Jason.decode!(raw), raw}
  end

  defp context(overrides \\ []) do
    struct(
      %Context{
        run_id: "run-1133",
        tracker_identity: tracker_identity(),
        attempt_id: "attempt-1",
        session_id: "session-1",
        thread_id: "thread-1",
        turn_id: "turn-1",
        request_id: nil,
        worker_generation: 7,
        agent_family: :codex,
        backend: :app_server,
        transport: :app_server,
        auth_mode: :chatgpt,
        requested_model: "gpt-5-codex",
        resolved_model: "gpt-5-codex",
        effort: "high",
        query_source: nil,
        account_generation: known_generation(:codex),
        source_sequence: 17,
        observed_source_version: nil
      },
      overrides
    )
  end

  defp claude_context do
    context(agent_family: :claude, account_generation: known_generation(:claude))
  end

  defp tracker_identity do
    %TrackerIdentity{
      status: :joinable,
      kind: :github,
      owner: "its-everdred",
      repository: "aiur",
      provider_id: "node-1133",
      database_id: 1133,
      identifier: "1133",
      reason: nil
    }
  end

  defp known_generation(provider) do
    %{provider: provider, backend: :app_server, generation: "gen-known", freshness: :current, health: :healthy, reason: nil}
  end

  defp unknown_generation(provider) do
    %{provider: provider, backend: :app_server, generation: nil, freshness: :unknown, health: :unavailable, reason: :owner_unavailable}
  end
end
