defmodule Aiur.AppChildSquatGuardTest do
  use ExUnit.Case, async: true

  # A test that starts its own `Aiur.PubSub` or `Aiur.TaskSupervisor` while the
  # application's child is mid-restart takes the name. `Aiur.PubSub.Boot` then
  # waits 5s and fails, so `:rest_for_one` keeps retrying and every later child
  # (Exchange, DecisionStore, Orchestrator) stays down for later tests (#4798).
  # Restore the application child with `Aiur.TestSupport.ensure_pubsub_running/0`
  # or `Aiur.TestSupport.RuntimeChildren.ensure_aiur_supervisor_running/0`.
  @squat ~r/start_supervised!?\(\s*\{\s*(Phoenix\.PubSub|Task\.Supervisor)\s*,\s*name:\s*Aiur\.(PubSub|TaskSupervisor)\s*\}/

  test "no test starts a replacement for an application-owned PubSub or TaskSupervisor" do
    offenders =
      for path <- Path.wildcard(Path.join([__DIR__, "..", "**", "*.exs"])),
          Regex.match?(@squat, File.read!(path)),
          do: Path.relative_to(Path.expand(path), Path.expand(Path.join(__DIR__, "..")))

    assert offenders == []
  end
end
