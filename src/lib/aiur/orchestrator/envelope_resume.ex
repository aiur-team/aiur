defmodule Aiur.Orchestrator.EnvelopeResume do
  @moduledoc false
  require Logger

  alias Aiur.{Config, Events.Publisher}
  alias Aiur.Orchestrator.{EnvelopeStore, State}

  @spec boot(map()) :: map()
  def boot(agent) do
    base = %{last_decrease_ms: nil, cpu_snapshot: nil, bootstrap_complete?: false}
    record = if agent.target_load_average, do: EnvelopeStore.load(agent.load_resume_max_age_seconds, System.schedulers_online())
    seed(base, record)
  end

  defp seed(base, nil), do: base

  defp seed(base, record) do
    payload = %{resume_level: record.resume_level, age_seconds: DateTime.diff(DateTime.utc_now(), record.recorded_at)}

    case Publisher.publish("system.fleet.capacity.resume_seeded", payload, source: "orchestrator") do
      {:error, reason} -> Logger.warning("Envelope resume event failed: #{inspect(reason)}")
      _ -> :ok
    end

    Map.merge(base, record)
  end

  @spec validate(map(), number() | nil, pos_integer()) :: map()
  def validate(envelope, target, schedulers) do
    max_age = Config.load_resume_max_age_seconds()
    stamp = envelope[:recorded_at]
    age = if match?(%DateTime{}, stamp), do: DateTime.diff(DateTime.utc_now(), stamp)

    invalid? =
      is_nil(target) or max_age == 0 or
        (is_integer(age) and (age < 0 or age > max_age)) or
        (is_integer(envelope[:record_schedulers]) and envelope.record_schedulers != schedulers)

    if invalid?, do: Map.drop(envelope, [:safe_level, :resume_level, :recorded_at, :record_schedulers, :safe_candidate, :safe_streak, :record_dirty?, :persisted_at_ms]), else: envelope
  end

  @spec level(map(), number() | nil) :: pos_integer() | nil
  def level(_envelope, nil), do: nil
  def level(envelope, _target), do: if(Config.load_resume_max_age_seconds() > 0, do: Map.get(envelope, :resume_level))

  @spec observe(map(), non_neg_integer(), pos_integer(), integer() | nil, number() | :unavailable, number() | nil, non_neg_integer()) :: map()
  def observe(envelope, _occupied, _effective, _previous, :unavailable, _target, _overload), do: envelope
  def observe(envelope, _occupied, _effective, _previous, _load, nil, _overload), do: envelope

  def observe(envelope, occupied, effective, previous, _load, _target, overload) do
    cond do
      overload >= 3 and is_integer(previous) and effective < previous ->
        lower(envelope, effective) |> Map.put(:sustained_decrease?, true) |> reset()

      overload >= 3 or occupied == 0 ->
        reset(envelope)

      true ->
        demonstrate(envelope, occupied)
    end
  end

  defp lower(envelope, effective) do
    case envelope[:safe_level] || envelope[:resume_level] do
      level when is_integer(level) -> record(envelope, min(level, effective))
      _ -> envelope
    end
  end

  defp demonstrate(envelope, occupied) do
    candidate = Map.get(envelope, :safe_candidate, occupied)
    streak = if occupied < candidate, do: 1, else: Map.get(envelope, :safe_streak, 0) + 1
    envelope = Map.merge(envelope, %{safe_candidate: min(candidate, occupied), safe_streak: streak})

    if streak >= 5 do
      confirm(envelope) |> reset()
    else
      envelope
    end
  end

  defp confirm(envelope) do
    if envelope.safe_candidate >= Map.get(envelope, :safe_level, 1) do
      record(envelope, envelope.safe_candidate)
    else
      envelope
    end
  end

  defp record(envelope, level), do: Map.merge(envelope, %{safe_level: level, resume_level: level, record_dirty?: true})
  defp reset(envelope), do: Map.drop(envelope, [:safe_candidate, :safe_streak])

  @spec persist(State.t(), boolean(), pos_integer(), integer()) :: State.t()
  def persist(state, fresh?, schedulers, now_ms) do
    envelope = state.load_envelope_state
    due? = is_nil(envelope[:persisted_at_ms]) or now_ms - envelope.persisted_at_ms >= 60_000

    if fresh? and envelope[:record_dirty?] == true and due? and Config.load_resume_max_age_seconds() > 0 do
      save(state, schedulers, now_ms)
    else
      state
    end
  end

  defp save(state, schedulers, now_ms) do
    now = DateTime.utc_now()

    case EnvelopeStore.save(state.load_envelope_state.safe_level, schedulers, now) do
      :ok ->
        envelope = Map.merge(state.load_envelope_state, %{persisted_at_ms: now_ms, recorded_at: now, record_schedulers: schedulers, record_dirty?: false})
        %{state | load_envelope_state: envelope}

      {:error, reason} ->
        Logger.warning("Dispatch envelope persistence unavailable: #{inspect(reason)}")
        state
    end
  end

  @spec status(map(), pos_integer(), pos_integer()) :: map()
  def status(envelope, effective, cap) do
    envelope = validate(envelope, Config.target_load_average(), System.schedulers_online())
    resume = envelope[:resume_level]
    stamp = envelope[:recorded_at]

    if Config.load_resume_max_age_seconds() > 0 and is_integer(resume) and effective < min(resume, cap) and match?(%DateTime{}, stamp) do
      %{resume_level: min(resume, cap), resume_recorded_ago_seconds: max(DateTime.diff(DateTime.utc_now(), stamp), 0)}
    else
      %{resume_level: nil, resume_recorded_ago_seconds: nil}
    end
  end

  @spec label(map()) :: String.t()
  def label(%{resume_level: level, resume_recorded_ago_seconds: age}) when is_integer(level) and is_integer(age),
    do: "resuming toward #{level} (safe level from #{div(age, 60)}m ago)"

  def label(_capacity), do: "AIMD envelope"
end
