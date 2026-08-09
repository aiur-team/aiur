defmodule AiurWeb.OperatorControlCenter.UnitsPresentation do
  @moduledoc false

  alias Aiur.CodingAgent
  alias AiurWeb.OperatorControlCenter.UnitsControlPolicy

  @spec present(map(), DateTime.t() | nil) :: %{unit: map(), latest: map(), command: map()}
  def present(row, now \\ nil)
  def present(row, now) when is_map(row), do: %{unit: unit(row), latest: latest(row, now), command: command(row)}
  def present(_row, now), do: %{unit: unit(%{}), latest: latest(%{}, now), command: command(%{})}

  @spec unit(map()) :: map()
  def unit(row) when is_map(row) do
    family = agent_family(row)
    {priority, priority_class} = priority(row)

    %{
      provider: agent_label(family),
      family: family,
      complexity: Map.get(row, :complexity),
      model: model_label(row),
      priority: priority,
      priority_class: priority_class
    }
  end

  def unit(_row), do: unit(%{})

  @spec latest(map(), DateTime.t() | nil) :: map()
  def latest(row, now) when is_map(row) do
    %{
      text: latest_text(row),
      progress: progress_label(row),
      runtime: runtime_label(row, now)
    }
  end

  def latest(_row, now), do: latest(%{}, now)

  @spec latest_text(map()) :: String.t()
  def latest_text(%{latest_evidence: %{status: :known, source: %{name: name}}}) when is_binary(name) and name != "", do: name
  def latest_text(_row), do: "No recent activity"

  @spec runtime_label(map(), DateTime.t() | nil) :: String.t()
  def runtime_label(%{runtime: %{runtime_seconds: seconds}}, _now) when is_integer(seconds) and seconds >= 0,
    do: format_duration(seconds)

  def runtime_label(%{timestamps: %{started_at: started_at}}, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, datetime, _offset} -> format_duration(max(DateTime.diff(now, datetime, :second), 0))
      _error -> "Unavailable"
    end
  end

  def runtime_label(_row, _now), do: "Unavailable"

  @spec command(map()) :: map()
  def command(row) when is_map(row) do
    affordance = UnitsControlPolicy.affordance(row, nil)

    %{
      control: control(affordance),
      chat: availability(conversation_available?(row)),
      remote_control: availability(remote_control_available?(row))
    }
  end

  def command(_row), do: command(%{})

  @spec agent_family(map()) :: atom() | nil
  def agent_family(row) when is_map(row) do
    cond do
      family = provider_or_nil(Map.get(row, :agent_family)) -> family
      backend = provider_or_nil(Map.get(row, :backend)) -> backend
      true -> nil
    end
  end

  def agent_family(_row), do: nil

  @spec agent_label(atom() | nil) :: String.t()
  def agent_label(family) do
    case CodingAgent.provider_descriptor(family) do
      %{label: label} -> label
      _ -> "Agent"
    end
  end

  @spec model_label(map()) :: String.t() | nil
  def model_label(%{resolved_model: model}) when is_binary(model) and model != "", do: model
  def model_label(%{requested_model: model}) when is_binary(model) and model != "", do: model
  def model_label(_row), do: nil

  @spec priority(map()) :: {String.t(), String.t()}
  def priority(%{effort: :deep}), do: {"HIGH", "is-high"}
  def priority(%{complexity: complexity}) when is_integer(complexity) and complexity >= 4, do: {"HIGH", "is-high"}
  def priority(%{complexity: 3}), do: {"MED", "is-med"}
  def priority(%{effort: :standard}), do: {"MED", "is-med"}
  def priority(_row), do: {"LOW", "is-low"}

  defp control(%{state: :enabled, action: action}), do: %{state: :enabled, action: action, reason: nil, label: "#{verb(action)} available"}
  defp control(%{state: :pending, pending_action: action}), do: %{state: :pending, action: action, reason: nil, label: "#{verb(action)} pending"}

  defp control(%{state: :disabled, reason: reason}),
    do: %{state: :disabled, action: nil, reason: reason, label: UnitsControlPolicy.disabled_reason(reason)}

  defp control(_affordance), do: %{state: :disabled, action: nil, reason: :unavailable, label: UnitsControlPolicy.disabled_reason(:unavailable)}

  defp availability(true), do: :available
  defp availability(false), do: :unavailable

  defp conversation_available?(%{live_conversation: %{generation_handle: handle}}) when is_binary(handle) and handle != "", do: true
  defp conversation_available?(_row), do: false

  defp remote_control_available?(%{live_conversation: %{remote_control_url: url}}) when is_binary(url) and url != "", do: true
  defp remote_control_available?(%{remote_control_url: url}) when is_binary(url) and url != "", do: true
  defp remote_control_available?(_row), do: false

  defp provider_or_nil(value) when is_atom(value) do
    case CodingAgent.provider_descriptor(value) do
      %{provider: provider} -> provider
      _ -> nil
    end
  end

  defp provider_or_nil(value) when is_binary(value) do
    case CodingAgent.provider_descriptor(value) do
      %{provider: provider} -> provider
      _ -> value |> CodingAgent.family_for() |> provider_or_nil()
    end
  end

  defp provider_or_nil(_value), do: nil

  defp progress_label(%{progress: %{status: :known, percent: percent}}) when is_integer(percent) and percent in 0..100,
    do: "#{percent}%"

  defp progress_label(_row), do: "—"

  defp format_duration(seconds) do
    hours = div(seconds, 3_600)
    minutes = div(rem(seconds, 3_600), 60)
    if hours > 0, do: "#{hours}h #{minutes}m", else: "#{minutes}m"
  end

  defp verb(:pause), do: "Pause"
  defp verb(:resume), do: "Resume"
  defp verb(_action), do: "Control"
end
