defmodule Aiur.LogCleanupTest do
  use ExUnit.Case, async: false

  @clear Path.expand("../../../scripts/aiur-clear-logs", __DIR__)
  @key "0123456789"

  setup do
    root = Aiur.TestSupport.tmp_root!("log-cleanup")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "clear removes only matching stale roots, preserving live and foreign evidence", %{root: root} do
    {dead_pid, 0} = System.cmd("bash", ["-c", "echo $$"])
    live = marked_root(root, "live", @key, :os.getpid())
    stale = marked_root(root, "stale", @key, String.trim(dead_pid))
    foreign = marked_root(root, "foreign", "aaaaaaaaaa", String.trim(dead_pid))
    invalid = marked_root(root, "invalid", @key, "0")
    unmarked = Path.join(root, "unmarked")
    File.mkdir_p!(unmarked)
    link = Path.join(root, "linked")
    File.ln_s!(foreign, link)

    {output, 0} = System.cmd("bash", [@clear, root, @key], stderr_to_stdout: true)
    assert output =~ "preserving live log root #{live}"
    refute File.exists?(stale)
    for kept <- [live, foreign, invalid], do: assert(File.read!(Path.join(kept, "evidence")) == "retain me")
    assert File.dir?(unmarked)
    assert File.read_link!(link) == foreign
  end

  test "clear refuses an unresolved instance without deleting evidence", %{root: root} do
    stale = marked_root(root, "stale", @key, "99999999")
    {output, 64} = System.cmd("bash", [@clear, root, ""], stderr_to_stdout: true)
    assert output =~ "refusing log cleanup"
    assert File.read!(Path.join(stale, "evidence")) == "retain me"
  end

  test "boot records the daemon PID and instance in the selected log root", %{root: root} do
    parent = root
    root = Path.join(parent, "run")
    original_key = System.get_env("AIUR_INSTANCE_KEY")
    original_env = Application.get_env(:aiur, :env)
    original_log = Application.get_env(:aiur, :log_file)

    on_exit(fn ->
      if original_key, do: System.put_env("AIUR_INSTANCE_KEY", original_key), else: System.delete_env("AIUR_INSTANCE_KEY")
      Application.put_env(:aiur, :env, original_env)
      Application.put_env(:aiur, :log_file, original_log)
    end)

    System.put_env("AIUR_INSTANCE_KEY", @key)
    Application.put_env(:aiur, :env, :dev)
    Application.put_env(:aiur, :log_file, Aiur.LogFile.default_log_file(root))

    assert :ok = Aiur.LogFile.ensure_session_log_file()
    assert File.read!(Path.join(root, ".aiur-owner")) == "#{@key}\n#{:os.getpid()}\n"
    assert {_, 0} = System.cmd("bash", [@clear, parent, @key], stderr_to_stdout: true)
    assert File.read!(Path.join(root, ".aiur-owner")) == "#{@key}\n#{:os.getpid()}\n"
  end

  test "test3 requires explicit opt-in to clear logs" do
    script = File.read!(Path.expand("../../../scripts/aiurdev", __DIR__))
    [_, parser] = Regex.run(~r/\n(debug_mode=0.*?\ndone)\n/s, script)
    command = parser <> "\nprintf '%s' \"$clear_mode\""
    assert {"0", 0} = System.cmd("bash", ["-c", command, "flags", "--test3"])
    assert {"1", 0} = System.cmd("bash", ["-c", command, "flags", "--test3", "--clear"])
  end

  defp marked_root(parent, name, key, pid) do
    root = Path.join(parent, name)
    File.mkdir_p!(root)
    File.write!(Path.join(root, ".aiur-owner"), "#{key}\n#{pid}\n")
    File.write!(Path.join(root, "evidence"), "retain me")
    root
  end
end
