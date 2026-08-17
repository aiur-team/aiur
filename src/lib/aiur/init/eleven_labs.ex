defmodule Aiur.Init.ElevenLabs do
  @moduledoc """
  ElevenLabs voice opt-in flow for `aiur init`.

  This module owns the voice-input prompt and the `elevenlabs:` YAML block that
  backs Stream Deck voice input. The key is a secret, so the prompt steers the
  operator to a `$ELEVENLABS_API_KEY` env reference rather than an inline value.
  """

  alias Aiur.Init.Format

  @env_reference "$ELEVENLABS_API_KEY"

  # ISO-639-3, the code family the ElevenLabs speech-to-text API expects.
  @language_code "eng"

  @doc false
  @spec prompt_eleven_labs(Aiur.Init.io(), Aiur.Init.deps(), Path.t() | atom()) :: %{
          enabled: boolean(),
          api_key: String.t() | nil
        }
  def prompt_eleven_labs(io, _deps, _location) do
    if io.confirm.("Enable Stream Deck voice input with ElevenLabs speech-to-text?", false) do
      io.puts.([
        "Keep the default ",
        Format.dim(@env_reference),
        " and put the key in .env — aiur resolves the reference and never writes the secret into the config."
      ])

      %{enabled: true, api_key: io.input.("ElevenLabs API key", @env_reference, nil)}
    else
      %{enabled: false, api_key: nil}
    end
  end

  @doc """
  The `elevenlabs:` YAML block, or empty iodata when the operator declined.

  The single renderer for both `aiur init` paths — the fresh-setup template fill
  (`{{ELEVENLABS_SECTION}}`) and the resume backfill append — so the same answer
  always produces the same config. Declining renders nothing at all, which is
  what leaves the section *missing* and therefore offerable again on a later
  resume.
  """
  @spec eleven_labs_section_yaml(map()) :: iodata()
  def eleven_labs_section_yaml(%{enabled: true} = answer) do
    [
      "# === Voice input and playback (added by `aiur init`; ElevenLabs) ===\n",
      "# Stream Deck and dashboard microphones use speech-to-text. Set voice_id to enable spoken agent replies in the dashboard.\n",
      "# api_key is a SECRET: keep it as the literal `#{@env_reference}` reference and put the value in `.env`.\n",
      "# aiur scrubs every `*_API_KEY` variable from agent environments and never logs the key.\n",
      "elevenlabs:\n",
      "  api_key: #{api_key_value(answer)}\n",
      "  language_code: #{@language_code}  # ISO-639-3 transcription language (\"eng\" = English)\n",
      "  voice_id: null  # Stock or owned ElevenLabs voice; also grant the key Text to Speech permission\n"
    ]
  end

  def eleven_labs_section_yaml(_answer), do: []

  defp api_key_value(%{api_key: key}) when is_binary(key) do
    case String.trim(key) do
      "" -> @env_reference
      trimmed -> trimmed
    end
  end

  defp api_key_value(_answer), do: @env_reference

  @doc false
  @spec env_reference() :: String.t()
  def env_reference, do: @env_reference
end
