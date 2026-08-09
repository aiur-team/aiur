defmodule AiurWeb.OperatorControlCenter.UnitsPresentation do
  @moduledoc false

  alias Aiur.CodingAgent
  alias AiurWeb.OperatorControlCenter.UnitsControlPolicy

  @spec present(map()) :: %{unit: map(), command: map()}
  def present(row) when is_map(row), do: %{unit: unit(row), command: command(row)}
  def present(_row), do: %{unit: unit(%{}), command: command(%{})}

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

  defp verb(:pause), do: "Pause"
  defp verb(:resume), do: "Resume"
  defp verb(_action), do: "Control"
end
