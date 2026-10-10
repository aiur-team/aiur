defmodule AiurWeb.BuildOrder.TicketContextPresenter.Capabilities do
  @moduledoc false

  alias Aiur.Bounded
  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrder.TicketContextPresenter.{Capability, Fields}

  @max_capabilities 5

  @doc false
  @spec normalize_capabilities([map()], TrackerIdentity.t() | nil) :: [Capability.t()]
  def normalize_capabilities(capabilities, identity) when is_list(capabilities) do
    {normalized, _seen} =
      Enum.reduce(capabilities, {[], MapSet.new()}, fn capability, {result, seen} ->
        add_capability(normalize_capability(capability, identity), result, seen)
      end)

    Enum.reverse(normalized)
  end

  def normalize_capabilities(_capabilities, _identity), do: []

  defp add_capability(nil, result, seen), do: {result, seen}

  defp add_capability(%Capability{} = capability, result, seen) do
    key = {capability.kind, capability.label}

    if MapSet.member?(seen, key) or length(result) == @max_capabilities do
      {result, seen}
    else
      {[capability | result], MapSet.put(seen, key)}
    end
  end

  def normalize_capability(capability, identity) when is_map(capability) do
    kind = Fields.map_value(capability, :kind, [:github, :chat, :commands, :document], nil)
    variant = Fields.map_value(capability, :variant, [:issue, :pull_request], nil)

    case {kind, capability_label(kind, variant)} do
      {nil, _label} -> nil
      {_kind, nil} -> nil
      {kind, label} -> capability_from_availability(kind, variant, label, capability, identity)
    end
  end

  def normalize_capability(_capability, _identity), do: nil

  defp capability_from_availability(kind, variant, label, capability, identity) do
    available? = Fields.map_value(capability, :available?) == true
    number = Fields.positive_integer(Fields.map_value(capability, :number))

    case available_href(
           kind,
           Fields.map_value(capability, :variant),
           Fields.map_value(capability, :href),
           identity,
           capability
         ) do
      {:ok, href, external?} when available? ->
        %Capability{
          kind: kind,
          variant: variant,
          number: number,
          label: label,
          href: href,
          available?: true,
          external?: external?
        }

      _ ->
        %Capability{
          kind: kind,
          variant: variant,
          number: number,
          label: label,
          available?: false,
          external?: false,
          reason: unavailable_reason(label, Fields.map_value(capability, :reason))
        }
    end
  end

  defp capability_label(:github, :issue), do: "Issue"
  defp capability_label(:github, :pull_request), do: "Pull request"
  defp capability_label(:github, nil), do: "GitHub"
  defp capability_label(:chat, _variant), do: "Chat"
  defp capability_label(:commands, _variant), do: "Commands"
  defp capability_label(:document, _variant), do: "Planning doc"
  defp capability_label(_kind, _variant), do: nil

  defp available_href(:github, :issue, href, identity, _capability) do
    with {:ok, href} <- Bounded.github_issue_url_for(href, identity), do: {:ok, href, true}
  end

  defp available_href(:github, :pull_request, href, identity, capability) do
    with {:ok, href} <-
           Bounded.github_pull_request_url_for(href, identity, Fields.map_value(capability, :number)) do
      {:ok, href, true}
    end
  end

  defp available_href(:chat, _variant, href, identity, _capability) do
    with {:ok, href} <- Bounded.chat_route_for(href, identity), do: {:ok, href, false}
  end

  defp available_href(:commands, _variant, href, _identity, _capability) do
    with {:ok, href} <- Bounded.commands_route(href), do: {:ok, href, false}
  end

  defp available_href(:document, _variant, href, identity, _capability) do
    case Bounded.planning_document_route_for(href, identity) do
      {:ok, route} -> {:ok, route, false}
      :error -> external_document_href(href)
    end
  end

  defp available_href(_kind, _variant, _href, _identity, _capability), do: :error

  defp external_document_href(href) do
    case document_href(href) do
      {:ok, href} -> {:ok, href, true}
      :error -> :error
    end
  end

  defp document_href(value) when is_binary(value) and byte_size(value) in 1..512 do
    case URI.parse(value) do
      %URI{scheme: "https", host: host} = uri when host in ["github.com", "www.github.com"] ->
        {:ok, URI.to_string(uri)}

      _uri ->
        :error
    end
  end

  defp document_href(_value), do: :error

  defp unavailable_reason("Pull request", :not_opened), do: "Pull request has not been opened."
  defp unavailable_reason("Chat", :not_opened), do: "Chat has not started for this ticket."
  defp unavailable_reason("Pull request", "Pull request has not been opened."), do: "Pull request has not been opened."
  defp unavailable_reason("Chat", "Chat has not started for this ticket."), do: "Chat has not started for this ticket."
  defp unavailable_reason(label, :missing), do: destination_reason(label, "missing")
  defp unavailable_reason(label, :stale), do: destination_reason(label, "stale")
  defp unavailable_reason(label, :unauthorized), do: destination_reason(label, "unauthorized")
  defp unavailable_reason(label, :inactive), do: destination_reason(label, "inactive")
  defp unavailable_reason(label, :unreadable), do: destination_reason(label, "unreadable")
  defp unavailable_reason(label, :identity_mismatch), do: destination_reason(label, "unavailable for this ticket")

  defp unavailable_reason(label, reason) when is_binary(reason) do
    if reason in controlled_destination_reasons(label), do: reason, else: destination_reason(label, "unavailable")
  end

  defp unavailable_reason(label, _reason), do: destination_reason(label, "unavailable")

  defp controlled_destination_reasons(label) do
    Enum.map(
      ["missing", "stale", "unauthorized", "inactive", "unreadable", "unavailable for this ticket", "unavailable"],
      &destination_reason(label, &1)
    )
  end

  defp destination_reason("Commands", reason), do: "Commands are #{reason}."
  defp destination_reason(label, reason), do: "#{label} is #{reason}."
end
