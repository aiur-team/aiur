defmodule Aiur.Usage.Headless.EmitterTest do
  use ExUnit.Case, async: true

  alias Aiur.{Issue, TrackerIdentity, UsageEnvelope}
  alias Aiur.Usage.Headless.Emitter

  @ingested_at ~U[2026-07-17 12:00:02Z]
  @fixtures Path.join(["test", "fixtures", "usage", "headless"])

  test "emits and publishes envelopes on the normal-run path, independent of debug or dashboard" do
    parent = self()
    message = claude_message()

    outcome = Emitter.observe(issue(), "claude", message, opts(usage_publisher: fn envelope -> send(parent, {:published, envelope}) end))

    assert %{envelopes: [envelope], coverages: []} = outcome
    assert envelope.provider == :claude
    assert envelope.backend == :app_server
    assert envelope.account_generation.generation == "gen-known"
    assert_received {:published, %UsageEnvelope{} = published}
    assert published == envelope
  end

  test "publishes nothing for a backend that is not a supported headless provider" do
    parent = self()
    result = Emitter.observe(issue(), "claude-repl", claude_message(), opts(usage_publisher: fn _ -> send(parent, :published) end))

    assert result == :skip
    refute_received :published
  end

  test "a malformed event fails closed without crashing or publishing" do
    parent = self()

    malformed = %{
      event: :turn_completed,
      payload: %{"method" => "turn/completed", "params" => %{"usage" => "not-a-map"}},
      raw: "}{ not json",
      timestamp: @ingested_at
    }

    assert %{envelopes: [], coverages: []} =
             Emitter.observe(issue(), "codex", malformed, opts(usage_publisher: fn _ -> send(parent, :published) end))

    refute_received :published
  end

  test "publication faults never propagate into the worker turn" do
    result = Emitter.observe(issue(), "claude", claude_message(), opts(usage_publisher: fn _ -> raise "sink is down" end))

    assert %{envelopes: [_envelope]} = result
  end

  defp claude_message do
    raw = @fixtures |> Path.join("claude-app-server-2026-07-turn-completed.json") |> File.read!()
    %{event: :turn_completed, payload: Jason.decode!(raw), raw: raw, timestamp: @ingested_at}
  end

  defp opts(extra) do
    [
      run_id: "run-1133",
      attempt_id: "attempt-1",
      session_id: "session-1",
      worker_generation: 7,
      source_sequence: 17,
      account_generation: %{
        schema_version: 1,
        provider: :claude,
        backend: :app_server,
        generation: "gen-known",
        source: :confirmed,
        freshness: :current,
        health: :healthy,
        reason: nil,
        observed_at: @ingested_at
      }
    ] ++ extra
  end

  defp issue do
    %Issue{
      identifier: "1133",
      tracker_identity: %TrackerIdentity{
        status: :joinable,
        kind: :github,
        owner: "its-everdred",
        repository: "aiur",
        provider_id: "node-1133",
        database_id: 1133,
        identifier: "1133",
        reason: nil
      }
    }
  end
end
