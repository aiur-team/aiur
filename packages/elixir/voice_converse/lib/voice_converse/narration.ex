defmodule VoiceConverse.Narration do
  @moduledoc """
  Batch narration: text to audio plus text alignment, with no live session. It uses the same
  provider seam as a session, through the optional `c:VoiceConverse.Provider.render_speech/1`.

  Options:

    * `:provider` (required) — a `VoiceConverse.Provider` module
    * `:credentials` (required) — `{credentials_module, provider_id}`; the adapter fetches the
      secret during the call (purpose `:render`) and nothing here holds it
    * `:format` — `:pcm_16000 | :pcm_24000 | :pcm_44100` (default `:pcm_24000`)
    * `:voice_id` — provider voice
    * `:max_chars` — longest text accepted (default 5000)
    * `:timeout_ms` — deadline for the provider call (default 60000); past it the render is
      killed and the result is a `:provider_unavailable` error

  Any other option is passed to the adapter unchanged.

  Errors: `{:error, :unsupported}` when the provider has no batch render;
  `{:error, %{field: atom(), reason: atom()}}` for a bad option; `{:error, %Events.Error{}}`
  for a provider failure (a missing credential is `:provider_auth`).
  """

  alias VoiceConverse.{Events, Provider}

  @formats [:pcm_16000, :pcm_24000, :pcm_44100]

  @default_max_chars 5_000
  @default_timeout_ms 60_000

  @type error :: :unsupported | %{field: atom(), reason: atom()} | Events.Error.t()

  @doc "Renders `text` and returns the raw PCM audio and its alignment."
  @spec render(String.t(), keyword()) :: {:ok, Provider.render_result()} | {:error, error()}
  def render(text, opts) do
    with {:ok, provider, spec, timeout_ms} <- build(text, opts),
         :ok <- supported(provider) do
      provider |> call_with_deadline(spec, timeout_ms) |> check_return()
    end
  end

  @doc """
  Renders `text` to a WAV file at `path`. The file is written to a temporary sibling, synced and
  renamed, so a reader sees the old file or the whole new one, never a partial one. Nothing is
  written when the render fails.
  """
  @spec render_to_file(String.t(), Path.t(), keyword()) ::
          {:ok, %{path: Path.t(), format: Events.AgentAudio.format(), alignment: [Provider.alignment_segment()]}}
          | {:error, error() | {:write_failed, term()}}
  def render_to_file(text, path, opts) do
    with {:ok, %{format: format, alignment: alignment} = result} <- render(text, opts),
         :ok <- write_atomically(path, wav(result)) do
      {:ok, %{path: path, format: format, alignment: alignment}}
    end
  end

  @doc "Samples per second for a PCM format."
  @spec sample_rate(Events.AgentAudio.format()) :: pos_integer()
  def sample_rate(:pcm_16000), do: 16_000
  def sample_rate(:pcm_24000), do: 24_000
  def sample_rate(:pcm_44100), do: 44_100

  defp build(text, opts) do
    opts = Map.new(opts)
    {provider, spec} = Map.pop(opts, :provider)
    {max_chars, spec} = Map.pop(spec, :max_chars, @default_max_chars)
    {timeout_ms, spec} = Map.pop(spec, :timeout_ms, @default_timeout_ms)
    spec = spec |> Map.put_new(:format, :pcm_24000) |> Map.put(:text, text)

    cond do
      not is_binary(text) or String.trim(text) == "" -> {:error, %{field: :text, reason: :empty}}
      not is_integer(max_chars) or max_chars < 1 -> {:error, %{field: :max_chars, reason: :invalid}}
      String.length(text) > max_chars -> {:error, %{field: :text, reason: :too_long}}
      not is_integer(timeout_ms) or timeout_ms < 1 -> {:error, %{field: :timeout_ms, reason: :invalid}}
      not is_atom(provider) or is_nil(provider) -> {:error, %{field: :provider, reason: :missing}}
      not match?({m, id} when is_atom(m) and is_atom(id), spec[:credentials]) -> credentials_error(spec)
      spec.format not in @formats -> {:error, %{field: :format, reason: :unsupported}}
      true -> {:ok, provider, spec, timeout_ms}
    end
  end

  defp credentials_error(%{credentials: _}), do: {:error, %{field: :credentials, reason: :invalid}}
  defp credentials_error(_), do: {:error, %{field: :credentials, reason: :missing}}

  defp supported(provider) do
    if Code.ensure_loaded?(provider) and function_exported?(provider, :render_speech, 1),
      do: :ok,
      else: {:error, :unsupported}
  end

  # A hung provider must not hang the host: past the deadline the call is killed.
  defp call_with_deadline(provider, spec, timeout_ms) do
    task = Task.async(fn -> provider.render_speech(spec) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, reply} -> reply
      _ -> {:error, Events.Error.new(:provider_unavailable, "render timed out")}
    end
  end

  # The adapter boundary: anything but a well-formed result or an Events.Error becomes a provider
  # error, so raw provider data never reaches the host.
  defp check_return({:ok, result}), do: check_result(result)
  defp check_return({:error, %Events.Error{}} = error), do: error
  defp check_return(_), do: invalid_result()

  defp check_result(%{audio: audio, format: format, alignment: alignment} = result)
       when is_binary(audio) and rem(byte_size(audio), 2) == 0 and format in @formats and is_list(alignment) do
    if Enum.all?(alignment, &segment?/1) and ordered?(alignment),
      do: {:ok, Map.take(result, [:audio, :format, :alignment])},
      else: invalid_result()
  end

  defp check_result(_), do: invalid_result()

  defp segment?(%{text: text, start_ms: s, end_ms: e})
       when is_binary(text) and is_integer(s) and is_integer(e) and s >= 0 and e >= s,
       do: true

  defp segment?(_), do: false

  defp ordered?(alignment) do
    alignment |> Enum.map(& &1.start_ms) |> Enum.chunk_every(2, 1, :discard) |> Enum.all?(fn [a, b] -> a <= b end)
  end

  defp invalid_result, do: {:error, Events.Error.new(:provider_error, "provider returned an invalid render result")}

  # 16-bit little-endian mono PCM in a RIFF/WAVE container.
  defp wav(%{audio: audio, format: format}) do
    rate = sample_rate(format)
    size = byte_size(audio)

    [
      "RIFF",
      <<36 + size::little-32>>,
      "WAVEfmt ",
      <<16::little-32, 1::little-16, 1::little-16, rate::little-32, rate * 2::little-32, 2::little-16, 16::little-16>>,
      "data",
      <<size::little-32>>,
      audio
    ]
  end

  defp write_atomically(path, data) do
    tmp = "#{path}.#{System.unique_integer([:positive])}.tmp"

    result =
      with {:ok, fd} <- :file.open(tmp, [:write, :exclusive, :raw, :binary]) do
        written = with :ok <- :file.write(fd, data), do: :file.sync(fd)
        :file.close(fd)
        with :ok <- written, do: :file.rename(tmp, path)
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        File.rm(tmp)
        {:error, {:write_failed, reason}}
    end
  end
end
