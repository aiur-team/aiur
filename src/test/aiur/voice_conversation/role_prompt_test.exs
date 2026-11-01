defmodule Aiur.VoiceConversation.RolePromptTest do
  use ExUnit.Case, async: true

  alias Aiur.VoiceConversation.{OpenAIProvider, Provider}

  defmodule Credentials do
    def fetch(_provider, :probe), do: {:ok, :present}
    def fetch(_provider, :connect), do: {:ok, "test-key"}
  end

  test "both host providers preserve the selected role prompt on the wire" do
    owner = self()

    for {provider, provider_id, options} <- [
          {Provider, :elevenlabs, [agent_id: "test-agent"]},
          {OpenAIProvider, :openai_realtime, [voice_id: "cedar"]}
        ] do
      spec = %{
        owner: owner,
        credentials: {Credentials, provider_id},
        system_prompt: "Selected role and glossary",
        context: "Current context",
        first_message: nil,
        audio_in: :pcm_16000,
        audio_out: :pcm_16000,
        tools: [],
        llm: "test-model",
        fake: options,
        transport: __MODULE__.Transport,
        http: fn _, _ -> {:ok, 200, Jason.encode!(%{signed_url: "wss://test.example"})} end
      }

      :persistent_term.put({__MODULE__, provider_id}, owner)
      {:ok, pid} = provider.open(spec)
      on_exit(fn -> :persistent_term.erase({__MODULE__, provider_id}) end)
      assert_receive {:wire, frame}, 1_000

      instructions =
        case frame do
          %{"type" => "session.update", "session" => session} ->
            session["instructions"]

          %{"type" => "conversation_initiation_client_data"} ->
            get_in(frame, ["conversation_config_override", "agent", "prompt", "prompt"])
        end

      assert instructions == "Selected role and glossary\n\nCurrent context"
      provider.close(pid)
    end
  end

  defmodule Transport do
    def connect(url, _headers) do
      provider_id =
        if String.contains?(url, "openai.com"), do: :openai_realtime, else: :elevenlabs

      {:ok, :persistent_term.get({Aiur.VoiceConversation.RolePromptTest, provider_id})}
    end

    def send_text(owner, text) do
      send(owner, {:wire, Jason.decode!(text)})
      {:ok, owner}
    end

    def close(_), do: :ok
  end
end
