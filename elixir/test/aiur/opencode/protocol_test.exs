defmodule Aiur.Opencode.ProtocolTest do
  use Aiur.TestSupport, async: false

  alias Aiur.Opencode.Protocol

  test "message part builders return opencode-shaped messages" do
    assert Protocol.user_message_part("hi") == %{role: "user", parts: [%{type: "text", text: "hi"}]}
    assert Protocol.assistant_text_message("hello") == %{role: "assistant", parts: [%{type: "text", text: "hello"}]}
    assert Protocol.system_message_part("boot") == %{role: "assistant", parts: [%{type: "text", text: "**system:** boot"}]}
    assert Protocol.alert_message_part("heads up") == %{role: "assistant", parts: [%{type: "text", text: "**alert:** heads up"}]}
  end

  test "command message uses native tool call and result parts" do
    message = Protocol.assistant_command_message("mix test", "ok", exit_code: 0)

    assert message.role == "assistant"
    assert [%{type: "tool_call", name: "bash"}, %{type: "tool_result", output: "ok"}] = message.parts
  end

  test "opencode_json locks the provider and model to Aiur" do
    config =
      Protocol.opencode_json(%{
        bridge_url: "http://127.0.0.1:4097",
        bridge_token: "secret",
        identifier: "MT-1",
        opencode_os_pid: nil
      })

    assert Map.keys(config["provider"]) == ["aiur"]
    assert config["model"] == "aiur/issue-MT-1"
    assert get_in(config, ["provider", "aiur", "options", "apiKey"]) == "secret"
    refute inspect(config) =~ "anthropic"
    refute Map.has_key?(config["provider"], "openai")
    refute Map.has_key?(config, "aiur_metadata")
  end

  test "opencode_json model name uses the identifier so chat chrome reads `aiur · issue-X`" do
    config =
      Protocol.opencode_json(%{
        bridge_url: "http://127.0.0.1:4097",
        bridge_token: "secret",
        identifier: "_slot-1",
        opencode_os_pid: nil,
        extra_identifiers: ["13", "7"]
      })

    models = get_in(config, ["provider", "aiur", "models"])

    # Model NAME must equal the model KEY (the identifier), so opencode
    # renders `aiur · issue-13` instead of `Aiur · Aiur`.
    for {key, %{"name" => name}} <- models do
      assert key == name, "model #{inspect(key)} should have name=#{inspect(key)} but had name=#{inspect(name)}"
    end

    # Identifier set is the union (slot sentinel + extras), de-duplicated.
    assert Enum.sort(Map.keys(models)) == Enum.sort(["issue-_slot-1", "issue-13", "issue-7"])
  end

  test "aiur_metadata returns the reap-path sidecar shape" do
    assert Protocol.aiur_metadata(%{identifier: "MT-1", opencode_os_pid: 4242}) == %{
             "identifier" => "MT-1",
             "opencode_os_pid" => 4242
           }
  end

  test "tui_json selects the custom aiur theme so the terminal background shows through" do
    assert Protocol.tui_json() == %{
             "$schema" => "https://opencode.ai/tui.json",
             "theme" => "aiur"
           }
  end

  test "aiur_theme_json keeps every background surface as `none`" do
    theme = Protocol.aiur_theme_json()
    backgrounds = ~w(background backgroundPanel backgroundElement diffAddedBg diffRemovedBg diffContextBg diffAddedLineNumberBg diffRemovedLineNumberBg)

    for key <- backgrounds do
      assert get_in(theme, ["theme", key]) == "none", "expected #{key} to be \"none\""
    end
  end

  describe "SQLite row builders" do
    test "assistant_message_data carries every required AssistantMessage key" do
      data = Protocol.assistant_message_data(%{identifier: "MT-13", parent_id: "msg_root", cwd: "/tmp/workspace"})

      assert %{
               "role" => "assistant",
               "parentID" => "msg_root",
               "modelID" => "issue-MT-13",
               "providerID" => "aiur",
               "mode" => "build",
               "agent" => "build",
               "path" => %{"cwd" => "/tmp/workspace", "root" => "/"},
               "cost" => 0,
               "tokens" => %{"input" => 0, "output" => 0, "reasoning" => 0, "cache" => %{"read" => 0, "write" => 0}},
               "time" => %{"created" => created, "completed" => completed},
               "finish" => "stop"
             } = data

      assert is_integer(created)
      assert is_integer(completed)
    end

    test "assistant_message_data round-trips through Jason" do
      data = Protocol.assistant_message_data(%{identifier: "MT-13", parent_id: "msg_root"})

      assert {:ok, encoded} = Jason.encode(data)
      assert {:ok, decoded} = Jason.decode(encoded)
      assert decoded == data
    end

    test "assistant_message_data accepts a custom finish reason" do
      assert %{"finish" => "tool-calls"} =
               Protocol.assistant_message_data(%{identifier: "MT-1", parent_id: "msg_root", finish: "tool-calls"})
    end

    test "user_message_data shape matches an observed opencode row" do
      data = Protocol.user_message_data("MT-13")

      assert %{
               "role" => "user",
               "agent" => "build",
               "model" => %{"providerID" => "aiur", "modelID" => "issue-MT-13"},
               "summary" => %{"diffs" => []},
               "time" => %{"created" => _}
             } = data
    end

    test "text_part_data is plain by default and synthetic when opted in" do
      assert Protocol.text_part_data("hello") == %{"type" => "text", "text" => "hello"}

      assert Protocol.text_part_data("hi", synthetic: true) == %{
               "type" => "text",
               "text" => "hi",
               "synthetic" => true
             }
    end

    test "tool_part_data wraps bash command + output as a completed tool state" do
      data = Protocol.tool_part_data(tool: "bash", input: %{command: "ls"}, output: "file1\n", title: "$ ls", call_id: "call_xyz")

      assert %{
               "type" => "tool",
               "tool" => "bash",
               "callID" => "call_xyz",
               "state" => %{
                 "status" => "completed",
                 "input" => %{command: "ls"},
                 "output" => "file1\n",
                 "title" => "$ ls",
                 "time" => %{"start" => _, "end" => _}
               }
             } = data
    end

    test "step_start_part_data and step_finish_part_data wrap a turn" do
      assert Protocol.step_start_part_data() == %{"type" => "step-start"}

      finish = Protocol.step_finish_part_data(reason: "tool-calls")

      assert %{
               "type" => "step-finish",
               "reason" => "tool-calls",
               "cost" => 0,
               "tokens" => %{"input" => 0, "output" => 0, "reasoning" => 0, "cache" => _}
             } = finish
    end

    test "aiur_owned? distinguishes Aiur sessions from opencode-provider ones" do
      assert Protocol.aiur_owned?(%{"providerID" => "aiur", "modelID" => "issue-1"})
      assert Protocol.aiur_owned?(%{providerID: "aiur"})
      refute Protocol.aiur_owned?(%{"providerID" => "opencode", "modelID" => "big-pickle"})
      refute Protocol.aiur_owned?(nil)
    end
  end

  test "serve and attach commands are shell escaped" do
    assert Protocol.serve_command(1234, "127.0.0.1", ["--flag"]) =~ "serve --port 1234 --hostname 127.0.0.1 --flag"
    assert Protocol.attach_command("http://127.0.0.1:1234", "session one") =~ "'session one'"
  end
end
