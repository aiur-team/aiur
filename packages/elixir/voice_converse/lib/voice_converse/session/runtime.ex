defmodule VoiceConverse.Session.Runtime do
  @moduledoc false

  alias VoiceConverse.{Events, Tools, TranscriptStore}

  def open(session, state, phase) do
    provider = state.provider
    spec = provider_spec(state, session)
    Task.start(fn -> send(session, {:provider_opened, phase, safely(fn -> provider.open(spec) end)}) end)
  end

  def close(session, provider, ref, action) do
    Task.start(fn ->
      _ = safely(fn -> provider.close(ref) end)
      send(session, {:provider_closed, action})
    end)
  end

  def close_current(provider, ref), do: safely(fn -> provider.close(ref) end)

  def enqueue_audio(_session, %{provider_ref: nil} = state, _audio_b64, _max), do: state

  def enqueue_audio(session, state, audio_b64, max) do
    if :queue.len(state.audio_queue) >= max do
      state
    else
      state
      |> Map.update!(:audio_queue, &:queue.in(audio_b64, &1))
      |> start_next_audio(session)
    end
  end

  def start_next_audio(%{audio_task?: true} = state, _session), do: state

  def start_next_audio(%{provider_ref: nil} = state, _session),
    do: %{state | audio_queue: :queue.new(), audio_task?: false}

  def start_next_audio(state, session) do
    case :queue.out(state.audio_queue) do
      {{:value, audio_b64}, audio_queue} ->
        provider = state.provider
        ref = state.provider_ref
        Task.start(fn -> send(session, {:audio_pushed, ref, safely(fn -> provider.push_audio(ref, audio_b64) end)}) end)
        %{state | audio_queue: audio_queue, audio_task?: true}

      {:empty, _audio_queue} ->
        %{state | audio_task?: false}
    end
  end

  def cancel_timer(timer) when is_reference(timer), do: Process.cancel_timer(timer)
  def cancel_timer(_timer), do: false

  def preflight_spec(config, target, provider, provider_opts) do
    provider_id = provider.descriptor().id

    %{
      owner: self(),
      credentials: {config.credentials, provider_id},
      system_prompt: "",
      first_message: nil,
      context: "",
      tools: [],
      audio_in: :pcm_16000,
      audio_out: :pcm_16000,
      llm: config.llm,
      target: target,
      fake: provider_opts
    }
  end

  defp safely(fun) do
    case fun.() do
      {:error, %Events.Error{code: code}} -> {:error, provider_code(code)}
      {:ok, _ref} = result -> result
      :ok -> :ok
      other -> other
    end
  rescue
    _error -> {:error, :provider_error}
  catch
    _kind, _reason -> {:error, :provider_error}
  end

  defp provider_spec(state, owner) do
    config = state.config
    provider = state.provider
    provider_id = provider.descriptor().id

    %{
      owner: owner,
      credentials: {config.credentials, provider_id},
      system_prompt: "",
      first_message: nil,
      context: context(state),
      tools: Tools.specs(config, state.target),
      audio_in: :pcm_16000,
      audio_out: :pcm_16000,
      llm: config.llm,
      target: state.target,
      fake: state.provider_opts
    }
  end

  defp transcript_tail(%{store: :none}), do: ""

  defp transcript_tail(%{store: %{path: path}, id: id}) do
    with {:ok, records, _meta} <- TranscriptStore.read(Path.dirname(path), id) do
      records
      |> Enum.filter(&(&1["type"] in ["user_turn", "assistant_turn"]))
      |> Enum.map_join("\n", &"#{&1["type"]}: #{&1["text"]}")
    else
      _ -> ""
    end
  end

  defp context(%{reconnects: 0, context: context}), do: context
  defp context(state), do: transcript_tail(state)

  defp provider_code(:provider_quota), do: :provider_quota
  defp provider_code(code) when code in [:provider_auth, :provider_unavailable, :privacy_preflight_failed], do: code
  defp provider_code(_), do: :provider_error
end
