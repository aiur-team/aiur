defmodule Aiur.Machine.InstanceRecordTest do
  use ExUnit.Case, async: true
  alias Aiur.Machine.InstanceRecord

  @fields ~w(NODE INSTANCE_KEY SESSION SOCKET AGENT_SOCKET AGENT_TMPFILE SURFACE_MODE WORKSPACE_ROOT_FILE PROJECT_ROOT TEST_TICKET_IDS TEST_STATE_DIR GITHUB_BUDGET_DIR PROJECT_ROOT_SOURCE WRITTEN_AT)
  @required "AIUR_RECORD_NODE=node\nAIUR_RECORD_SESSION=session\nAIUR_RECORD_SOCKET=socket\nAIUR_RECORD_PROJECT_ROOT=/repo"

  @tag :tmp_dir
  test "round-trips every field written by bash printf %q", %{tmp_dir: dir} do
    values = ["node@host", "", "unicode-é-猫", "socket with spaces", "agents", "", "terminal", "", dir <> "/'\"$`()\\\n\t\r\a\b\e\f\v", "", "", "", "explicit", "2026-10-27T00:00:00Z"]
    args = Enum.zip_with(@fields, values, fn key, value -> [key, value] end) |> List.flatten()
    {record, 0} = System.cmd("bash", ["-c", "while (( $# )); do printf 'AIUR_RECORD_%s=%q\\n' \"$1\" \"$2\"; shift 2; done", "fixture" | args])
    assert {:ok, parsed} = InstanceRecord.parse(record)

    assert Map.drop(parsed, [:ignored_lines]) == %{
             node: "node@host",
             instance_key: "",
             session: "unicode-é-猫",
             socket: "socket with spaces",
             surface_mode: "terminal",
             project_root: Enum.at(values, 8),
             project_root_source: "explicit",
             written_at: List.last(values)
           }
  end

  @tag :tmp_dir
  test "rejects command substitution without executing its side effect", %{tmp_dir: dir} do
    path = Path.join(dir, "side-effect")
    result = InstanceRecord.parse(@required <> "\nAIUR_RECORD_NODE=$(touch #{path})")
    refute File.exists?(path)
    assert result == {:error, {:unsupported_value, "NODE"}}
  end

  test "ignores unknown keys and counts non-record lines" do
    assert {:ok, parsed} = InstanceRecord.parse(@required <> "\nAIUR_RECORD_FUTURE=$(bad)\ncomment\nBAD=value")
    assert parsed == %{node: "node", session: "session", socket: "socket", project_root: "/repo", ignored_lines: 2}
  end

  test "requires all four launcher keys to be nonempty" do
    for key <- ~w(NODE SESSION SOCKET PROJECT_ROOT) do
      lines = String.split(@required, "\n") |> Enum.reject(&String.starts_with?(&1, "AIUR_RECORD_#{key}=")) |> Enum.join("\n")
      assert InstanceRecord.parse(lines) == {:error, :incomplete}
      assert InstanceRecord.parse(lines <> "\nAIUR_RECORD_#{key}=''") == {:error, :incomplete}
    end
  end

  test "decodes hex and octal ANSI escapes and escaped shell punctuation" do
    assert {:ok, %{node: "A\n\t\\'B"}} = InstanceRecord.parse(@required <> "\nAIUR_RECORD_NODE=" <> ~S/$'\x41\n\t\\\'\102'/)
    assert {:ok, %{node: "$()`\"'"}} = InstanceRecord.parse(@required <> "\nAIUR_RECORD_NODE=" <> ~S/\$\(\)\`\"\'/)
  end

  test "rejects unsupported and incomplete quoting in all known fields" do
    for value <- ["$HOME", "`id`", "(cmd)", "'quoted'", "\"quoted\"", "trailing\\", "$'unterminated", "$'a'junk", "$'\\q'", "$'\\xGG'", "$'\\777'", "a;cmd", "a b"], key <- ["NODE", "AGENT_TMPFILE"] do
      assert InstanceRecord.parse(@required <> "\nAIUR_RECORD_#{key}=#{value}") == {:error, {:unsupported_value, key}}
    end
  end

  @tag :tmp_dir
  test "lists only records with independent errors and bounded reads", %{tmp_dir: dir} do
    valid = Path.join(dir, "a.instance")
    large = Path.join(dir, "b.instance")
    partial = Path.join(dir, "c.instance")
    missing = Path.join(dir, "d.instance")
    File.write!(valid, @required)
    File.write!(large, String.duplicate("x", 16 * 1024 + 1))
    File.write!(partial, "AIUR_RECORD_NODE=node")
    File.ln_s!(Path.join(dir, "absent"), missing)
    File.write!(Path.join(dir, "ignored"), @required)
    # Unreadable oversized file proves the stat size gate precedes opening it.
    File.chmod!(large, 0o000)
    assert [{^valid, {:ok, %{node: "node"}}}, {^large, {:error, :too_large}}, {^partial, {:error, :incomplete}}, {^missing, {:error, :enoent}}] = InstanceRecord.list(dir)
    File.chmod!(large, 0o600)
    assert InstanceRecord.list(Path.join(dir, "absent")) == [{Path.join(dir, "absent"), {:error, :enoent}}]
    assert InstanceRecord.parse(String.duplicate("x", 16 * 1024 + 1)) == {:error, :too_large}
    assert {:error, :incomplete} = InstanceRecord.parse(String.duplicate("x", 16 * 1024))
  end

  test "engine writer fixture guards future record format changes" do
    # Future-regression guard: any newly emitted key requires an explicit review here.
    writer = File.read!(Path.expand("../../../..", __DIR__) <> "/packaging/npm/aiur-cli/libexec/engine/instance.sh")
    emitted = Regex.scan(~r/printf 'AIUR_RECORD_([A-Z_]+)=%q/, writer) |> Enum.map(&List.last/1)
    assert Enum.sort(emitted) == Enum.sort(@fields)
    fixture = Enum.map_join(emitted, "\n", &"AIUR_RECORD_#{&1}=\\$")
    assert {:ok, parsed} = InstanceRecord.parse(fixture)
    assert parsed.node == "$"
    assert map_size(parsed) == 9
  end
end
