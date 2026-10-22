defmodule VoiceConverse.Testing.FakeProvider do
  @moduledoc """
  Scriptable provider with no network. `open/1` starts an `Agent` linked to the caller; its pid
  is the ref. Every call after `open/1` is recorded; read them in order with `calls/1`.

  Script it from the spec's optional `:fake` keyword:

    * `script: [event]` — events delivered to the owner right after `open/1`, in order
    * `open_error: %Events.Error{}` — `open/1` fails with it
    * `preflight_error: %Events.Error{}` — `preflight/1` fails with it
    * `render: %{audio:, format:, alignment:}` — what `render_speech/1` returns (default: silence
      with one 250 ms segment per word of the text)
    * `render_error: %Events.Error{}` — `render_speech/1` fails with it
    * `render_delay: ms` — `render_speech/1` sleeps this long first (for deadline tests)

  `render_speech/1` fetches its credential like a real adapter: without one it returns a
  `:provider_auth` error before rendering anything.

  `emit/2` delivers one more event. All deliveries leave the ref's process, so the owner sees
  them in emit order. Only `VoiceConverse.Events` structs are accepted.
  """
  @behaviour VoiceConverse.Provider

  alias VoiceConverse.Events

  @impl true
  def descriptor do
    %{
      id: :fake,
      family: :speech_to_speech,
      label: "Fake",
      modes: [:voice, :text],
      needs: [],
      privacy: %{audio_stored_by_provider: false, deletable?: true}
    }
  end

  @impl true
  def capabilities, do: %{events: Events.all(), text_only?: false, client_parts: [], manual_truncation: true}

  @impl true
  def preflight(spec) do
    case fake_opt(spec, :preflight_error) do
      nil -> :ok
      %Events.Error{} = error -> {:error, error}
    end
  end

  @impl true
  def open(%{owner: owner} = spec) when is_pid(owner) do
    case fake_opt(spec, :open_error) do
      %Events.Error{} = error ->
        {:error, error}

      nil ->
        {:ok, ref} = Agent.start_link(fn -> %{owner: owner, calls: []} end)
        Enum.each(fake_opt(spec, :script) || [], &emit(ref, &1))
        {:ok, ref}
    end
  end

  @impl true
  def push_audio(ref, b64), do: record(ref, {:push_audio, b64})

  @impl true
  def send_context(ref, text), do: record(ref, {:send_context, text})

  @impl true
  def send_user_text(ref, text), do: record(ref, {:send_user_text, text})

  @impl true
  def tool_result(ref, call_id, result), do: record(ref, {:tool_result, call_id, result})

  @impl true
  def announce(ref, text, opts), do: record(ref, {:announce, text, opts})

  @impl true
  def truncate(ref, turn_id, played_until_ms), do: record(ref, {:truncate, turn_id, played_until_ms})

  @impl true
  def close(ref), do: record(ref, :close)

  @impl true
  def render_speech(%{credentials: {credentials, provider_id}} = spec) do
    if delay = fake_opt(spec, :render_delay), do: Process.sleep(delay)

    with {:ok, _secret} <- fetch_secret(credentials, provider_id) do
      case {fake_opt(spec, :render_error), fake_opt(spec, :render)} do
        {%Events.Error{} = error, _} ->
          {:error, error}

        {error, _} when not is_nil(error) ->
          raise ArgumentError, "render_error must be an Events.Error: #{inspect(error)}"

        {nil, nil} ->
          {:ok, silence(spec)}

        {nil, result} ->
          {:ok, result}
      end
    end
  end

  @doc "Sends `{:voice_conversation, ref, event}` to the owner. Raises `ArgumentError` for a non-event."
  @spec emit(pid(), Events.t()) :: :ok
  def emit(ref, event) do
    unless Events.event?(event), do: raise(ArgumentError, "not a VoiceConverse.Events struct: #{inspect(event)}")
    Agent.get(ref, fn %{owner: owner} -> send(owner, {:voice_conversation, ref, event}) end)
    :ok
  end

  @doc "Recorded calls, oldest first."
  @spec calls(pid()) :: [tuple() | :close]
  def calls(ref), do: ref |> Agent.get(& &1.calls) |> Enum.reverse()

  defp record(ref, call), do: Agent.update(ref, &%{&1 | calls: [call | &1.calls]})

  defp fake_opt(spec, key), do: spec |> Map.get(:fake, []) |> Keyword.get(key)

  @word_ms 250

  defp fetch_secret(credentials, provider_id) do
    case credentials.fetch(provider_id, :render) do
      {:ok, secret} -> {:ok, secret}
      {:error, :missing} -> {:error, Events.Error.new(:provider_auth, "no credential for #{provider_id}")}
    end
  end

  defp silence(%{text: text, format: format}) do
    words = String.split(text)

    alignment =
      words
      |> Enum.with_index()
      |> Enum.map(fn {w, i} -> %{text: w, start_ms: i * @word_ms, end_ms: (i + 1) * @word_ms} end)

    samples = div(length(words) * @word_ms * VoiceConverse.Narration.sample_rate(format), 1000)
    %{audio: :binary.copy(<<0, 0>>, samples), format: format, alignment: alignment}
  end
end
