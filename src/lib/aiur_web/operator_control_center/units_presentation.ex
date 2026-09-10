defmodule AiurWeb.OperatorControlCenter.UnitsPresentation do
  @moduledoc false

  alias Aiur.CodingAgent
  alias Aiur.CodingAgent.Models
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
      provider: agent_label(row),
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

  @doc """
  Renders an age in seconds as a short operator label.

  Stale surfaces must carry their age in one shape wherever they appear, so the
  fleet banner and the Units catalog banner never disagree about how old the
  same snapshot is.
  """
  @spec age_label(term()) :: String.t()
  def age_label(age_seconds) when is_integer(age_seconds) and age_seconds >= 0 do
    cond do
      age_seconds < 60 -> "#{age_seconds}s"
      age_seconds < 3_600 -> "#{div(age_seconds, 60)}m #{rem(age_seconds, 60)}s"
      true -> "#{div(age_seconds, 3_600)}h #{div(rem(age_seconds, 3_600), 60)}m"
    end
  end

  def age_label(_age_seconds), do: "unknown age"

  @spec latest_text(map()) :: String.t()
  def latest_text(%{reasons: %{resume: %{outcome: :declined} = outcome}}),
    do: "Resume declined — #{resume_condition(outcome)}; #{resume_detail(outcome)}"

  def latest_text(%{reasons: %{resume: %{outcome: :dropped} = outcome}}),
    do: "Resume dropped — #{resume_condition(outcome)}; #{resume_detail(outcome)}"

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

  # The Unit pill label for a row: the provider family label when it resolves,
  # otherwise the resolved/requested model, otherwise the configured backend.
  # Never a bare "Agent" — a dispatched ticket should always resolve to a model
  # or its configured backend rather than an empty fallback label.
  @spec agent_label(map() | atom() | nil) :: String.t() | nil
  def agent_label(%{} = row) do
    agent_label(agent_family(row)) || model_label(row) || backend_label(row)
  end

  def agent_label(family) do
    case CodingAgent.provider_descriptor(family) do
      %{label: label} -> label
      _ -> nil
    end
  end

  @spec model_label(map()) :: String.t() | nil
  def model_label(%{resolved_model: model}) when is_binary(model) and model != "", do: model
  def model_label(%{requested_model: model}) when is_binary(model) and model != "", do: model

  def model_label(%{backend: backend}) when is_binary(backend) and backend != "" do
    case CodingAgent.resolve_model(backend, nil) do
      model when is_binary(model) and model != "" -> model
      _no_default -> nil
    end
  end

  def model_label(_row), do: nil

  @doc """
  The model + version chip for a row: `%{label: "OPUS 5.1", id: "claude-opus-5-1"}`.

  The id is what the session actually ran on — the model the running agent
  reported, else the model its route asked for, else the backend's own
  default. Only the label is short enough for a chip, so the raw id rides
  along for the `title` attribute; a row whose model no source can name
  returns `nil` and renders no chip at all rather than an empty one.
  """
  @spec model_version(map()) :: %{label: String.t(), id: String.t()} | nil
  def model_version(row) when is_map(row) do
    with id when is_binary(id) <- model_label(row),
         label when is_binary(label) <- Models.label(id) do
      %{label: label, id: id}
    else
      _unknown -> nil
    end
  end

  def model_version(_row), do: nil

  defp backend_label(%{backend: backend}) when is_binary(backend) and backend != "" do
    backend |> String.replace("_", " ") |> String.capitalize()
  end

  defp backend_label(%{backend: backend}) when is_atom(backend) and not is_nil(backend) do
    backend |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp backend_label(_row), do: nil

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

  defp resume_condition(%{pause_reason: :max_agent_duration}), do: "maximum agent duration reached"

  defp resume_condition(%{pause_reason: reason}) when is_atom(reason),
    do: humanize_atom(reason)

  defp resume_condition(_outcome), do: "pause condition unknown"

  defp resume_detail(%{detail: %{message: message}}) when is_binary(message), do: message
  defp resume_detail(%{detail: %{class: class}}) when is_atom(class), do: humanize_atom(class)
  defp resume_detail(%{detail: %{reason: reason}}) when is_atom(reason), do: humanize_atom(reason)
  defp resume_detail(_outcome), do: "no diagnostic reported"

  defp humanize_atom(value), do: value |> Atom.to_string() |> String.replace("_", " ")

  defp format_duration(seconds) do
    hours = div(seconds, 3_600)
    minutes = div(rem(seconds, 3_600), 60)
    if hours > 0, do: "#{hours}h #{minutes}m", else: "#{minutes}m"
  end

  defp verb(:pause), do: "Pause"
  defp verb(:resume), do: "Resume"
  defp verb(_action), do: "Control"
end
