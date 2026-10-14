defmodule Aiur.RepoBaseCase do
  @moduledoc false
  # Shared origin-repository setup and ledger fixtures for the `Aiur.RepoBase` tests.
  use ExUnit.CaseTemplate

  import ExUnit.Assertions

  alias Aiur.RepoBase

  using do
    quote do
      # async: false — refresh/3 broadcasts on the global "prewarm:phase" topic, so
      # the phase-event test must not race other tests emitting on the same topic.
      use ExUnit.Case, async: false

      import Aiur.RepoBaseCase

      alias Aiur.RepoBase
    end
  end

  setup do
    assert :ok = Aiur.TestSupport.ensure_runtime_children_running()

    # Recover the app-owned singleton if a sibling stopped this child alone.
    # An ExUnit-owned replacement would remove the shared name at teardown.
    if is_nil(Process.whereis(RepoBase)) do
      assert {:ok, _pid} = Supervisor.restart_child(Aiur.Supervisor, RepoBase)
    end

    assert is_pid(Process.whereis(RepoBase))

    tmp = Aiur.TestSupport.tmp_root!("aiur_rb")
    origin = Path.join(tmp, "origin")
    node = Path.join(tmp, "repo/owner/project")
    base = Path.join(node, "latest")
    File.mkdir_p!(origin)

    git!(["init", "--quiet", "-b", "main", origin])
    git!(["-C", origin, "config", "user.email", "test@example.com"])
    git!(["-C", origin, "config", "user.name", "Test"])
    File.write!(Path.join(origin, "README.md"), "v1\n")
    git!(["-C", origin, "add", "."])
    git!(["-C", origin, "commit", "--quiet", "-m", "init"])

    on_exit(fn -> Aiur.TestCleanup.rm_rf!(tmp) end)

    {:ok, tmp: tmp, origin: origin, node: node, base: base}
  end

  def finding(slug) do
    %{
      "slug" => slug,
      "observed_at" => "2026-08-02T04:30:00Z",
      "scope" => "aiur",
      "observed_in" => "owner/project",
      "instance" => "boot-123",
      "summary" => "a concise observation",
      "evidence" => ["#1464"],
      "cost" => "one hour",
      "ticket" => nil,
      "status" => "open"
    }
  end

  def operator_ask(id, title) do
    %{
      "id" => id,
      "title" => title,
      "body" => nil,
      "urgency" => "normal",
      "blocking" => false,
      "status" => "open",
      "created_at" => "2026-08-08T12:00:00Z",
      "created_by" => "executor"
    }
  end

  def git!(args) do
    {out, status} = System.cmd("git", args, stderr_to_stdout: true)
    assert status == 0, "git #{Enum.join(args, " ")} failed: #{out}"
    out
  end

  def head(repo) do
    {out, 0} = System.cmd("git", ["-C", repo, "rev-parse", "HEAD"], stderr_to_stdout: true)
    String.trim(out)
  end
end
