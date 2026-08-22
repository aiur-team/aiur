defmodule Aiur.AppServer.MessagesTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Aiur.AppServer.Messages

  test "emit_message/4 builds an event envelope with metadata and timestamp" do
    parent = self()

    Messages.emit_message(
      fn message -> send(parent, {:message, message}) end,
      :tool_result,
      %{details: "ok"},
      %{session_id: "s1"}
    )

    assert_receive {:message, message}
    assert message.event == :tool_result
    assert message.details == "ok"
    assert message.session_id == "s1"
    assert %DateTime{} = message.timestamp
  end

  test "normalize_tool_result/1 lifts first text content item into output" do
    assert Messages.normalize_tool_result(%{"contentItems" => [%{"text" => "done"}]})["output"] == "done"

    assert Messages.normalize_tool_result(%{"output" => "kept", "contentItems" => [%{"text" => "ignored"}]})[
             "output"
           ] == "kept"
  end

  test "normalize_tool_result/2 spills the complete successful frame over 100 KiB", %{tmp_dir: tmp_dir} do
    {_output, 0} = System.cmd("git", ["init", "-q"], cd: tmp_dir)
    output = String.duplicate("x", 100 * 1024 + 1)
    original = %{"success" => true, "output" => output, "contentItems" => [%{"text" => output}], "metadata" => %{"kind" => "design"}}

    result = Messages.normalize_tool_result(original, %{workspace: tmp_dir, response_id: 77})

    assert result["success"]
    assert result["output"] == hd(result["contentItems"])["text"]
    assert [path] = Regex.run(~r/saved as JSON to (.+)\. Read the file/, result["output"], capture: :all_but_first)
    assert String.starts_with?(path, Path.expand(tmp_dir))
    assert Jason.decode!(File.read!(path)) == original

    assert {_, 0} = System.cmd("git", ["check-ignore", "-q", path], cd: tmp_dir)
    assert private_mode?(Path.join(tmp_dir, ".aiur-runtime"), 0o700)
    assert private_mode?(Path.dirname(path), 0o700)
    assert private_mode?(path, 0o600)
    assert Path.wildcard(Path.join(Path.dirname(path), ".*.tmp")) == []
  end

  test "normalize_tool_result/2 measures duplicated content and envelope overhead", %{tmp_dir: tmp_dir} do
    {_output, 0} = System.cmd("git", ["init", "-q"], cd: tmp_dir)
    output = String.duplicate("x", 90 * 1024)
    content = String.duplicate("y", 20 * 1024)
    original = %{"success" => true, "output" => output, "contentItems" => [%{"type" => "inputText", "text" => content}]}

    result = Messages.normalize_tool_result(original, %{workspace: tmp_dir, response_id: "long-response-id"})

    assert result != original
    assert result["output"] =~ "saved as JSON"
  end

  test "normalize_tool_result/2 includes the full Claude wire envelope at the exact boundary", %{tmp_dir: tmp_dir} do
    {_output, 0} = System.cmd("git", ["init", "-q"], cd: tmp_dir)
    response_id = "boundary-id"
    empty = %{"success" => true, "output" => ""}
    overhead = claude_wire_size(response_id, empty)
    boundary = Map.put(empty, "output", String.duplicate("x", 100 * 1024 - overhead))

    assert claude_wire_size(response_id, boundary) == 100 * 1024
    assert Messages.normalize_tool_result(boundary, %{workspace: tmp_dir, response_id: response_id}) == boundary

    oversized = Map.update!(boundary, "output", &(&1 <> "x"))
    assert claude_wire_size(response_id, oversized) == 100 * 1024 + 1
    assert Messages.normalize_tool_result(oversized, %{workspace: tmp_dir, response_id: response_id})["output"] =~ "saved as JSON"
  end

  test "normalize_tool_result/2 keeps small and failed results unchanged", %{tmp_dir: tmp_dir} do
    small = %{"success" => true, "output" => "ok", "contentItems" => [%{"text" => "ok"}]}
    failed = %{"success" => false, "output" => String.duplicate("x", 110 * 1024)}

    assert Messages.normalize_tool_result(small, %{workspace: tmp_dir, response_id: 1}) == small
    assert Messages.normalize_tool_result(failed, %{workspace: tmp_dir, response_id: 2}) == failed
  end

  test "normalize_tool_result/2 rejects a runtime-directory symlink escape", %{tmp_dir: tmp_dir} do
    outside = Path.join(System.tmp_dir!(), "outside-spill-#{System.pid()}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)
    File.ln_s!(outside, Path.join(tmp_dir, ".aiur-runtime"))
    original = %{"success" => true, "output" => String.duplicate("x", 110 * 1024)}

    result = Messages.normalize_tool_result(original, %{workspace: tmp_dir, response_id: 3})
    refute result["success"]
    assert byte_size(Jason.encode!(%{"id" => 3, "result" => result}) <> "\n") < 1024
    assert File.ls!(outside) == []
  end

  test "normalize_tool_result/2 rejects a results-directory symlink escape", %{tmp_dir: tmp_dir} do
    runtime = Path.join(tmp_dir, ".aiur-runtime")
    outside = Path.join(System.tmp_dir!(), "outside-results-#{System.pid()}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(runtime)
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)
    File.ln_s!(outside, Path.join(runtime, "tool-results"))
    original = %{"success" => true, "output" => String.duplicate("x", 110 * 1024)}

    result = Messages.normalize_tool_result(original, %{workspace: tmp_dir, response_id: 4})
    refute result["success"]
    assert byte_size(Jason.encode!(%{"id" => 4, "result" => result}) <> "\n") < 1024
    assert File.ls!(outside) == []
  end

  test "normalize_tool_result/2 returns a bounded failure when git exclusion is unsafe", %{tmp_dir: tmp_dir} do
    {_output, 0} = System.cmd("git", ["init", "-q"], cd: tmp_dir)
    exclude = Path.join([tmp_dir, ".git", "info", "exclude"])
    outside = Path.join(tmp_dir, "outside-exclude")
    File.write!(outside, "unchanged\n")
    File.rm!(exclude)
    File.ln_s!(outside, exclude)
    original = %{"success" => true, "output" => String.duplicate("x", 110 * 1024)}

    result = Messages.normalize_tool_result(original, %{workspace: tmp_dir, response_id: 5})

    refute result["success"]
    assert byte_size(Jason.encode!(%{"jsonrpc" => "2.0", "id" => 5, "result" => result}) <> "\n") < 1024
    assert File.read!(outside) == "unchanged\n"
  end

  test "tool call helpers normalize blank names and missing arguments" do
    assert Messages.tool_call_name(%{"tool" => " emit_alert "}) == "emit_alert"
    assert Messages.tool_call_name(%{name: " "}) == nil
    assert Messages.tool_call_name(nil) == nil
    assert Messages.tool_call_arguments(%{"arguments" => %{"a" => 1}}) == %{"a" => 1}
    assert Messages.tool_call_arguments(%{}) == %{}
  end

  test "initialize_frame/0 contains the shared app-server handshake" do
    frame = Messages.initialize_frame()

    assert frame["id"] == 1
    assert frame["method"] == "initialize"
    assert frame["params"]["capabilities"]["experimentalApi"] == true
    assert frame["params"]["clientInfo"]["name"] == "aiur-orchestrator"
    assert is_binary(frame["params"]["clientInfo"]["version"])
    assert Messages.initialized_frame() == %{"method" => "initialized", "params" => %{}}
  end

  defp private_mode?(path, expected) do
    {:ok, %File.Stat{mode: mode}} = File.stat(path)
    Bitwise.band(mode, 0o777) == expected
  end

  defp claude_wire_size(id, result) do
    byte_size(Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}) <> "\n")
  end
end
