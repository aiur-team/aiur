defmodule AiurWeb.BuildOrderPresenter.Capabilities do
  @moduledoc "Identity-qualified, destination-specific capability normalization."

  alias Aiur.{Bounded, TrackerIdentity}
  alias AiurWeb.BuildOrderViewModel.Capability

  @capability_keys [:issue, :pull_request, :commands, :chat, :document]
  @safe_capability_reasons [
    :identity_mismatch,
    :inactive,
    :invalid_destination,
    :missing,
    :not_available,
    :not_configured,
    :not_opened,
    :stale,
    :unauthorized,
    :unavailable,
    :unreadable,
    :unsupported
  ]

  @doc false
  @spec normalize_capabilities(term()) :: %{atom() => Capability.t()}
  def normalize_capabilities(capabilities) when is_map(capabilities) do
    Map.new(@capability_keys, fn key -> {key, normalize_capability(key, Map.get(capabilities, key))} end)
  end

  def normalize_capabilities(_capabilities), do: normalize_capabilities(%{})

  defp normalize_capability(key, capability) when key in @capability_keys and is_map(capability) do
    destination = Map.get(capability, :destination) || Map.get(capability, :url) || Map.get(capability, :path)
    identity = safe_capability_identity(Map.get(capability, :identity))
    number = safe_capability_number(Map.get(capability, :number))
    label = safe_label(Map.get(capability, :label))
    active? = optional_boolean(Map.get(capability, :active?))
    readable? = optional_boolean(Map.get(capability, :readable?))

    case {Map.get(capability, :available?) == true, is_struct(identity, TrackerIdentity), safe_destination(key, destination, identity, number)} do
      {true, false, _destination} ->
        unavailable_capability(:invalid_destination, identity, number, label, active?, readable?)

      {true, true, nil} ->
        unavailable_capability(:invalid_destination, identity, number, label, active?, readable?)

      {true, true, safe} ->
        %Capability{
          identity: identity,
          destination: safe,
          number: number,
          label: label,
          reason: nil,
          available?: true,
          active?: active?,
          readable?: readable?
        }

      {false, _identity?, _destination} ->
        unavailable_capability(safe_reason(Map.get(capability, :reason)), identity, number, label, active?, readable?)
    end
  end

  defp normalize_capability(_key, _capability), do: unavailable_capability(:unavailable)

  defp unavailable_capability(reason, identity \\ nil, number \\ nil, label \\ nil, active? \\ nil, readable? \\ nil) do
    %Capability{
      identity: identity,
      destination: nil,
      number: number,
      label: label,
      reason: reason,
      available?: false,
      active?: active?,
      readable?: readable?
    }
  end

  defp safe_destination(:issue, value, identity, _number), do: safe_destination_result(Bounded.github_issue_url_for(value, identity))
  defp safe_destination(:pull_request, value, identity, number), do: safe_destination_result(Bounded.github_pull_request_url_for(value, identity, number))
  defp safe_destination(:chat, value, identity, _number), do: safe_destination_result(Bounded.chat_route_for(value, identity))
  defp safe_destination(:commands, value, _identity, _number), do: safe_destination_result(Bounded.commands_route(value))
  # Planning-doc link (pre-ticket): any bounded https://github.com URL, including
  # a doc blob path that `github_url/1` (issue/PR-shaped) would reject.
  defp safe_destination(:document, value, identity, _number) do
    case Bounded.planning_document_route_for(value, identity) do
      {:ok, route} -> route
      :error -> safe_document_destination(value)
    end
  end

  defp safe_destination_result({:ok, safe}), do: safe
  defp safe_destination_result(:error), do: nil

  defp safe_document_destination(value) when is_binary(value) and byte_size(value) in 1..512 do
    case URI.parse(value) do
      %URI{scheme: "https", host: host} = uri when host in ["github.com", "www.github.com"] ->
        URI.to_string(uri)

      _uri ->
        nil
    end
  end

  defp safe_document_destination(_value), do: nil

  defp safe_label(value) when is_binary(value) and byte_size(value) in 1..80 and value != "" do
    if String.valid?(value) and not String.match?(value, ~r/[\x00-\x1F\x7F]/), do: value
  end

  defp safe_label(_value), do: nil

  defp safe_capability_identity(%TrackerIdentity{} = identity) do
    if TrackerIdentity.joinable?(identity), do: identity
  end

  defp safe_capability_identity(_identity), do: nil
  defp safe_capability_number(value) when is_integer(value) and value > 0, do: value
  defp safe_capability_number(_value), do: nil
  defp optional_boolean(value) when is_boolean(value), do: value
  defp optional_boolean(_value), do: nil
  defp safe_reason(value) when value in @safe_capability_reasons, do: value
  defp safe_reason(_value), do: :unavailable
end
