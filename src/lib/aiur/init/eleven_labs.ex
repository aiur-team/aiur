defmodule Aiur.Init.ElevenLabs do
  @moduledoc """
  ElevenLabs speech-to-text opt-in flow for `aiur init`.

  This module owns the voice-input prompt and the `elevenlabs:` YAML block that
  backs Stream Deck voice input. The key is a secret, so the prompt steers the
  operator to a `$ELEVENLABS_API_KEY` env reference rather than an inline value.
  """

  alias Aiur.Init.Format

  @env_reference "$ELEVENLABS_API_KEY"

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

  @doc false
  @spec eleven_labs_section_yaml(map()) :: iodata()
  def eleven_labs_section_yaml(answer) do
    [
      "# === Stream Deck voice input (added by `aiur init`) ===\n",
      "elevenlabs:\n",
      "  api_key: #{api_key_value(answer)}\n",
      "  language_code: eng\n"
    ]
  end

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
