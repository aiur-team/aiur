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
    assert get_in(config, ["aiur_metadata", "opencode_os_pid"]) == nil
  end

  test "serve and attach commands are shell escaped" do
    assert Protocol.serve_command(1234, "127.0.0.1", ["--flag"]) =~ "serve --port 1234 --hostname 127.0.0.1 --flag"
    assert Protocol.attach_command("http://127.0.0.1:1234", "session one") =~ "'session one'"
  end
end
