defmodule Aiur.Orchestrator.DockerCleanupTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.DockerCleanup

  test "stops and removes only containers labelled for the terminal ticket" do
    owner = self()

    command = fn executable, args, _opts ->
      send(owner, {:docker, executable, args})

      case args do
        ["ps", "-aq", "--filter", "label=aiur.ticket=AIUR-42"] -> {"abc123\ndef456\n", 0}
        ["rm", "-f", "abc123"] -> {"", 0}
        ["rm", "-f", "def456"] -> {"", 0}
      end
    end

    assert :ok = DockerCleanup.cleanup_ticket("AIUR-42", command: command)
    assert_received {:docker, "docker", ["ps", "-aq", "--filter", "label=aiur.ticket=AIUR-42"]}
    assert_received {:docker, "docker", ["rm", "-f", "abc123"]}
    assert_received {:docker, "docker", ["rm", "-f", "def456"]}
    refute_received {:docker, "docker", ["rm", "-f", "other-ticket"]}
  end

  test "terminal cleanup remains best effort when Docker is unavailable" do
    command = fn _executable, _args, _opts -> raise ErlangError, original: :enoent end

    assert :ok = DockerCleanup.cleanup_ticket("AIUR-42", command: command)
  end
end
