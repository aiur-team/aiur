defmodule Aiur.VoiceCLI do
  @moduledoc "Thin host wrapper for the standalone transcript reader."
  import Aiur.ControlCLI.Protocol, only: [exit_marker: 1, guarded: 2]

  @spec transcripts([String.t()]) :: :ok
  def transcripts(args) do
    guarded("voice transcripts", fn ->
      code =
        case Aiur.Config.Paths.voice_conversation_state_dir() do
          {:ok, root} ->
            Aiur.VoiceConversation.print_transcripts(root, args)

          {:error, reason} ->
            IO.puts(:stderr, "Cannot resolve voice transcript root: #{inspect(reason)}")
            1
        end

      exit_marker(code)
    end)
  end
end
