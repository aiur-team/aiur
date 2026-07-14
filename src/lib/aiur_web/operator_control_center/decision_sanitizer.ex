defmodule AiurWeb.OperatorControlCenter.DecisionSanitizer do
  @moduledoc false

  alias Aiur.SecretRedactor

  @identity_max 256
  @canonical_agent_id ~r/\A(?:(?:agent|example-agent)-[A-Za-z0-9][A-Za-z0-9._-]*|codex|claude(?:-repl)?|legacy_attention)\z/
  @jwt ~r/\AeyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\z/

  @spec ticket(map()) :: map()
  def ticket(ticket) when is_map(ticket) do
    %{
      identifier: Map.get(ticket, :identifier),
      title: Map.get(ticket, :title),
      url: safe_ticket_url(Map.get(ticket, :url))
    }
  end

  @spec source(map()) :: %{agent_id: String.t() | nil}
  def source(source) when is_map(source), do: %{agent_id: safe_agent_id(Map.get(source, :agent_id))}

  @spec actor(map() | term()) :: %{kind: term()} | nil
  def actor(actor) when is_map(actor), do: %{kind: Map.get(actor, :kind)}
  def actor(_actor), do: nil

  @spec dispatch_attempt(map() | term()) :: map()
  def dispatch_attempt(attempt) when is_map(attempt) do
    Map.take(attempt, [
      :action_id,
      :attempt_id,
      :queue_item_id,
      :status,
      :attempted_at,
      :queued_at,
      :delivered_at,
      :restored_at,
      :consumed_at,
      :failed_at,
      :failure_reason_class
    ])
  end

  def dispatch_attempt(_attempt), do: %{}

  @spec lifecycle_fact(map() | nil) :: map() | nil
  def lifecycle_fact(nil), do: nil

  def lifecycle_fact(fact) when is_map(fact) do
    fact
    |> Map.take([:action_id, :occurred_at])
    |> Map.put(:actor, actor(Map.get(fact, :actor)))
  end

  @spec follow_ups(map()) :: map()
  def follow_ups(follow_ups) when is_map(follow_ups) do
    Map.new(follow_ups, fn {action_id, follow_up} ->
      safe =
        follow_up
        |> Map.take([:action_id, :slug, :question, :required_at, :handled_at])
        |> Map.put(:handled_by, actor(Map.get(follow_up, :handled_by)))

      {action_id, safe}
    end)
  end

  @spec artifacts(list() | term()) :: [map()]
  def artifacts(artifacts) when is_list(artifacts) do
    Enum.flat_map(artifacts, fn
      %{kind: :path, value: value} when is_binary(value) -> [%{kind: :path, value: value}]
      %{kind: :url, value: value} when is_binary(value) -> safe_url_artifact(value)
      _artifact -> []
    end)
  end

  def artifacts(_artifacts), do: []

  @spec provenance(map() | term()) :: map() | nil
  def provenance(provenance) when is_map(provenance) do
    Map.take(provenance, [
      :schema_version,
      :agent_family,
      :backend,
      :requested_model,
      :resolved_model,
      :attempt_id,
      :source,
      :captured_at
    ])
  end

  def provenance(_provenance), do: nil

  defp safe_ticket_url(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host, userinfo: userinfo, query: query, fragment: fragment}
      when scheme in ["http", "https"] and is_binary(host) and userinfo in [nil, ""] and
             query in [nil, ""] and fragment in [nil, ""] ->
        value

      _uri ->
        nil
    end
  end

  defp safe_ticket_url(_value), do: nil

  defp safe_agent_id(value) when is_binary(value) do
    if byte_size(value) <= @identity_max and
         SecretRedactor.redact(value) == value and
         not Regex.match?(@jwt, value) and
         Regex.match?(@canonical_agent_id, value) do
      value
    end
  end

  defp safe_agent_id(_value), do: nil

  defp safe_url_artifact(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, userinfo: userinfo, query: query, fragment: fragment}
      when is_binary(host) and userinfo in [nil, ""] and query in [nil, ""] and fragment in [nil, ""] ->
        [%{kind: :url, value: value}]

      _uri ->
        []
    end
  end
end
