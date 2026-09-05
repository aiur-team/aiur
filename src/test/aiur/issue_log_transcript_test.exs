defmodule Aiur.IssueLogTranscriptTest do
  @moduledoc """
  The durable transcript's on-disk encoding.

  There was no coverage of this writer at all, which is how a `nil` `turn_id`
  came to be persisted as the *string* `"nil"` and stayed that way. That string
  is truthy, so the Stream Deck's group-by-turn saw every turn-less entry as
  belonging to one turn and collapsed a whole page of activity into a single
  event key.
  """

  use Aiur.TestSupport

  alias Aiur.{AgentEvents, IssueLog}

  setup do
    original_log_file = Application.get_env(:aiur, :log_file)
    identifier = "transcript-#{System.unique_integer([:positive])}"
    tmp = Aiur.TestSupport.tmp_root!("aiur-transcript")
    File.mkdir_p!(Path.join(tmp, "log"))
    Application.put_env(:aiur, :log_file, Path.join(tmp, "log/aiur.log"))

    on_exit(fn ->
      if original_log_file, do: Application.put_env(:aiur, :log_file, original_log_file), else: Application.delete_env(:aiur, :log_file)
      File.rm_rf!(tmp)
    end)

    %{identifier: identifier}
  end

  test "persists an absent turn as JSON null, never the string \"nil\"", %{identifier: identifier} do
    record = write_transcript(identifier, AgentEvents.transcript_event(:assistant, "no turn on this one"))

    assert Map.fetch!(record, "turn_id") == nil
    refute Map.get(record, "turn_id") == "nil"
    assert Map.fetch!(record, "msg_id") == nil
  end

  test "persists a real turn identifier unchanged", %{identifier: identifier} do
    record = write_transcript(identifier, AgentEvents.transcript_event(:assistant, "in a turn", turn_id: "854098fc"))

    assert Map.fetch!(record, "turn_id") == "854098fc"
  end

  # `true`/`false` are atoms too, and the same catch-all clause stringified them.
  # A consumer testing a boolean field would then have read every value as truthy.
  test "persists booleans as JSON booleans", %{identifier: identifier} do
    record =
      write_transcript(
        identifier,
        AgentEvents.transcript_event(:tool, "edit lib/a.ex", payload: %{tool: "edit", output: "+ok", truncated: false})
      )

    assert Map.get(record, "payload") == nil or is_map(Map.get(record, "payload"))
    assert is_binary(Map.fetch!(record, "role"))
  end

  # An atom that genuinely carries a name still round-trips as its name; the fix
  # narrows the catch-all rather than removing it.
  test "still persists a named atom as its string name", %{identifier: identifier} do
    record = write_transcript(identifier, AgentEvents.transcript_event(:assistant, "hello"))

    assert Map.fetch!(record, "role") == "assistant"
  end

  # #2557. `Phoenix.PubSub.subscribe/2` registers, and `Registry` links every
  # registered process to the partition it registered in — so every live writer
  # holds a link to an `Aiur.PubSub` partition. Before this guard that link was
  # fatal: one PubSub crash killed every writer at once and
  # `Aiur.IssueLog.Supervisor` restarted one per active ticket, so any run with
  # more than three open tickets blew that `DynamicSupervisor`'s 3-in-5 budget
  # and it exited `:shutdown`. That is a *second*, independent child death
  # inside `Aiur.Supervisor` while `Aiur.PubSub` is still restarting, and it
  # arrives from child #6 rather than from PubSub at child #1 — which defeats
  # `:rest_for_one`'s ordering guarantee (#2525) and takes the application tree
  # down with it.
  #
  # The signal is delivered directly rather than by crashing the shared
  # registry: this asserts the writer's own contract — an exit signal from a
  # dependency does not kill it, and it still has its subscription afterwards —
  # without making the case's result depend on what else in the partition
  # happens to be subscribed.
  test "a writer outlives an exit signal from its PubSub partition and stays subscribed", %{identifier: identifier} do
    :ok = IssueLog.attach(identifier)
    pid = writer_pid(identifier)
    on_exit(fn -> Aiur.TestSupport.safe_stop(pid) end)
    ref = Process.monitor(pid)

    Process.exit(pid, :killed)

    refute_receive {:DOWN, ^ref, :process, _pid, _reason}, 500
    assert Process.alive?(pid)

    Aiur.AgentPubSub.broadcast_transcript(identifier, AgentEvents.transcript_event(:assistant, "after the partition died"))
    _ = :sys.get_state(pid)

    assert identifier
           |> IssueLog.transcript_path()
           |> File.read!() =~ "after the partition died"
  end

  defp write_transcript(identifier, event) do
    :ok = IssueLog.attach(identifier)
    pid = writer_pid(identifier)
    on_exit(fn -> Aiur.TestSupport.safe_stop(pid) end)

    send(pid, {:transcript_event, event})
    _ = :sys.get_state(pid)

    identifier
    |> IssueLog.transcript_path()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> List.last()
    |> Jason.decode!()
  end

  defp writer_pid(identifier) do
    transcript_path = IssueLog.transcript_path(identifier)

    Aiur.IssueLog.Supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
    |> Enum.find(fn pid -> :sys.get_state(pid).transcript_path == transcript_path end)
  end
end
