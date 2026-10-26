defmodule VoiceConverse.Session.Start do
  @moduledoc false

  alias VoiceConverse.{Config, ContextBuilder, Drafts, Events, SessionLimits, TranscriptStore}
  alias VoiceConverse.Session.Runtime

  def state(config, target, id, opts) do
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)

    with {:ok, descriptor} <- describe_target(config, target),
         :ok <- Config.check_session_start(config),
         :ok <- target_alive?(config, target),
         {:ok, provider, provider_opts} <- provider(config, opts),
         :ok <- preflight(provider, Runtime.preflight_spec(config, target, provider, provider_opts)),
         :ok <- SessionLimits.under_daily_cap?(config),
         {:ok, store} <- open_transcript(config, descriptor, id, provider, opts),
         started_at <- clock.(),
         {:ok, context} <- build_context(config, target, store, started_at) do
      {:ok,
       %{
         id: id,
         config: config,
         target: target,
         draft_target: descriptor,
         drafts: Drafts.new(),
         provider: provider,
         provider_opts: provider_opts,
         context: context.text,
         provider_ref: nil,
         provider_ids: MapSet.new(),
         store: store,
         state: :connecting,
         subscribers: %{},
         reconnects: 0,
         clock: clock,
         schedule_after: Keyword.get(opts, :schedule_after, &Process.send_after(self(), &2, &1)),
         event_broadcast: Keyword.get(opts, :event_broadcast, &broadcast/3),
         transport_token: nil,
         idle_token: nil,
         transport_timer: nil,
         idle_timer: nil,
         max_timer: nil,
         opening: nil,
         start_status: :opening,
         start_waiters: [],
         finishing?: false,
         finished?: false,
         end_tool_call_id: nil,
         deferred_events: [],
         audio_queue: :queue.new(),
         audio_task?: false,
         started_at: started_at
       }}
    else
      {:error, %{field: field}} -> {:error, field}
      {:error, code} when is_atom(code) -> {:error, code}
      _ -> {:error, :unknown}
    end
  end

  defp target_alive?(%Config{briefing_source: source}, target) do
    case source.alive?(target) do
      false -> {:error, :target_gone}
      _ -> :ok
    end
  rescue
    _error -> {:error, :target_gone}
  end

  defp describe_target(%Config{briefing_source: source}, target) do
    {:ok, source.describe_target(target)}
  rescue
    _error -> {:error, :unknown}
  end

  defp provider(config, opts) do
    case Keyword.get(opts, :provider, config.provider) do
      {module, provider_opts} when is_atom(module) and is_list(provider_opts) -> {:ok, module, provider_opts}
      module when is_atom(module) -> {:ok, module, []}
      _ -> {:error, :unconfigured}
    end
  end

  defp preflight(provider, spec) do
    if function_exported?(provider, :preflight, 1) do
      case provider.preflight(spec) do
        :ok -> :ok
        {:error, %Events.Error{}} -> {:error, :privacy_preflight_failed}
        _ -> {:error, :privacy_preflight_failed}
      end
    else
      :ok
    end
  end

  defp open_transcript(config, descriptor, id, provider, opts) do
    provider_id = provider.descriptor().id

    TranscriptStore.start(config, id, %{
      target: descriptor,
      role_id: Keyword.get(opts, :role_id),
      provider: to_string(provider_id),
      model: config.llm
    })
  rescue
    _error -> {:error, :unknown}
  end

  defp build_context(config, target, store, now) do
    context = ContextBuilder.build(config, target, now: now)

    case Enum.reduce_while(context.blocks, :ok, fn block, :ok ->
           record = Map.merge(block, %{type: "context"})
           if TranscriptStore.append(store, record) == :ok, do: {:cont, :ok}, else: {:halt, :error}
         end) do
      :ok ->
        {:ok, context}

      :error ->
        _ = TranscriptStore.close(store)
        {:error, :unknown}
    end
  end

  defp broadcast(subscribers, id, event),
    do: Enum.each(Map.keys(subscribers), &send(&1, {:voice_conversation, id, event}))
end
