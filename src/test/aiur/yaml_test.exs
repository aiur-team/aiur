defmodule Aiur.YamlTest do
  use ExUnit.Case, async: false

  alias Aiur.Workflow
  alias Aiur.Yaml

  @document """
  tracker:
    kind: github
    labels: [a, b]
  on: true
  count: 3
  """

  describe "parity with YamlElixir" do
    test "decodes strings exactly as YamlElixir does" do
      assert Yaml.read_from_string(@document) == YamlElixir.read_from_string(@document)
      assert {:ok, %{"tracker" => %{"kind" => "github", "labels" => ["a", "b"]}, "count" => 3}} = Yaml.read_from_string(@document)
    end

    test "decodes files and reports a missing file as YamlElixir does" do
      path = Path.join(Aiur.TestSupport.tmp_root!("yaml-parity"), "doc.yml")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, @document)

      assert Yaml.read_from_file(path) == YamlElixir.read_from_file(path)
      assert {:error, %YamlElixir.FileNotFoundError{}} = Yaml.read_from_file(path <> ".missing")
    end

    test "reports malformed YAML as a parsing error" do
      assert {:error, %YamlElixir.ParsingError{}} = Yaml.read_from_string("a: [unclosed")
      assert Yaml.read_from_string("a: [unclosed") == YamlElixir.read_from_string("a: [unclosed")
    end
  end

  # The #2474 wedge: `Application.stop(:aiur)` holds `:application_controller`
  # while the tree terminates. A shutdown-path config read with the
  # WorkflowStore down parses YAML, and YamlElixir's per-read
  # `Application.start(:yamerl)` then waits on that same controller forever.
  # A suspended controller stands in for the busy one without stopping the app.
  describe "with :application_controller unable to answer" do
    setup do
      Aiur.TestSupport.reset_global_state!()
      :ok = :sys.suspend(:application_controller)
      on_exit(fn -> :sys.resume(:application_controller) end)
    end

    test "a read still returns" do
      assert {:ok, {:ok, %{"count" => 3}}} = run_bounded(fn -> Yaml.read_from_string(@document) end)
    end

    test "deriving config with the WorkflowStore down still returns" do
      :ok = Supervisor.terminate_child(Aiur.Supervisor, Aiur.WorkflowStore)

      try do
        assert {:ok, {:ok, %{config: %{}}}} = run_bounded(&Workflow.current/0)
      after
        :sys.resume(:application_controller)
        Aiur.TestSupport.ensure_workflow_store_running()
      end
    end
  end

  defp run_bounded(fun) do
    task = Task.async(fun)
    Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)
  end
end
