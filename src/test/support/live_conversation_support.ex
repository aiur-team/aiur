defmodule Aiur.LiveConversationSupport do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [start_supervised!: 1]

  alias Aiur.{LiveConversation, TrackerIdentity}

  def source(overrides \\ []) do
    Map.merge(
      %{
        identity: %TrackerIdentity{
          status: :joinable,
          kind: :github,
          owner: "owner",
          repository: "repo",
          provider_id: "opaque-provider",
          identifier: "42",
          reason: nil
        },
        run_id: "run-1",
        attempt_id: "attempt-1",
        backend: "codex",
        worker_generation: 1
      },
      Map.new(overrides)
    )
  end

  def assert_opaque_id(id) do
    assert String.starts_with?(id, "message:")
    assert byte_size(id) <= 64
  end

  def start_barrier_server do
    start_supervised!(
      Supervisor.child_spec(
        {LiveConversation, name: nil},
        id: make_ref()
      )
    )
  end

  def concurrent_calls(server, first_call, second_call) do
    :ok = :sys.suspend(server)
    baseline = message_queue_length(server)

    try do
      first = Task.async(first_call)
      assert_queue_length(server, baseline + 1, 100)

      second = Task.async(second_call)
      assert_queue_length(server, baseline + 2, 100)
      :ok = :sys.resume(server)

      {Task.await(first, 2_000), Task.await(second, 2_000)}
    after
      _ = :sys.resume(server)
    end
  end

  defp assert_queue_length(_server, _minimum, 0),
    do: flunk("concurrent projection calls were not queued")

  defp assert_queue_length(server, minimum, attempts) do
    if message_queue_length(server) >= minimum do
      :ok
    else
      Process.sleep(1)
      assert_queue_length(server, minimum, attempts - 1)
    end
  end

  defp message_queue_length(server) do
    case Process.info(server, :message_queue_len) do
      {:message_queue_len, count} ->
        count

      _other ->
        0
    end
  end
end
