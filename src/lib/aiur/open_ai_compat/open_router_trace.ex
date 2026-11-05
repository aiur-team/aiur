defmodule Aiur.OpenAICompat.OpenRouterTrace do
  @moduledoc false

  alias Aiur.Config.{InstanceKey, Overrides}
  alias Aiur.{Issue, TrackerIdentity}

  @spec start_turn(map(), map(), Issue.t()) :: map()
  def start_turn(state, session, issue) do
    turn = Map.get(state, :turn_seq, 0) + 1
    context = identity(state.config, session, issue, turn)
    state |> Map.put(:turn_seq, turn) |> Map.update!(:config, &Map.put(&1, :trace_identity, context))
  end

  @spec request_config(map(), non_neg_integer()) :: map()
  def request_config(state, round), do: Map.put(state.config, :trace_round, round + 1)

  @spec attach(map(), map()) :: map()
  def attach(request, %{backend: backend, quirks: %{openrouter_trace: true}, trace_identity: context} = config)
      when backend in ["openrouter", :openrouter] and is_map(context) do
    trace = Map.put(context["trace"], "generation_name", "round #{config.trace_round}")
    Map.update!(request, :json, &Map.merge(&1, Map.put(context, "trace", trace)))
  end

  def attach(request, _config), do: request

  defp identity(%{backend: backend, quirks: %{openrouter_trace: true}} = config, session, issue, turn)
       when backend in ["openrouter", :openrouter] do
    environment = environment()

    %{
      "session_id" => String.slice(ticket_key(issue), 0, 256),
      "user" => String.slice("#{environment}/#{config[:account_name] || "default"}", 0, 128),
      "trace" => trace(config, session, issue, turn, environment)
    }
  end

  defp identity(_config, _session, _issue, _turn), do: nil

  defp trace(config, session, issue, turn, environment) do
    %{
      "trace_id" => "#{session.thread_id}:#{turn}",
      "trace_name" => "##{issue.identifier} turn #{turn}",
      "environment" => environment,
      "release" => Overrides.build_version(),
      "issue_identifier" => issue.identifier,
      "backend" => to_string(config.backend),
      "model" => config.model,
      "complexity" => complexity(issue),
      "dispatch_id" => session.thread_id,
      "thread_id" => session.thread_id
    }
  end

  defp ticket_key(issue) do
    identity = Issue.tracker_identity(issue)

    if TrackerIdentity.joinable?(identity) do
      "github:#{String.downcase(identity.owner)}/#{String.downcase(identity.repository)}##{identity.identifier}"
    else
      "unscoped:#{issue.identifier}"
    end
  end

  defp environment do
    case InstanceKey.current() do
      {:ok, key} -> key
      {:error, _} -> "default"
    end
  end

  defp complexity(issue) do
    Enum.find_value(List.wrap(Map.get(issue, :labels)), fn
      "complexity:" <> value when value in ["1", "2", "3", "4", "5"] -> value
      _ -> nil
    end)
  end
end
