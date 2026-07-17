defmodule AiurWeb.OperatorControlCenter.UnitsRow.URL do
  @moduledoc false

  alias Aiur.TrackerIdentity

  @spec normalize(term(), TrackerIdentity.t()) :: String.t() | nil
  def normalize(url, %TrackerIdentity{} = identity) when is_binary(url) do
    with %URI{scheme: scheme, host: host, port: port, userinfo: nil, query: query, path: path} = uri <- URI.parse(url),
         true <- scheme in ["http", "https"],
         true <- default_port?(scheme, port),
         true <- is_binary(host) and String.downcase(host) == "github.com" and query in [nil, ""],
         [owner, repository, "issues", identifier] <- String.split(path || "", "/", trim: true),
         true <- same?(owner, identity.owner),
         true <- same?(repository, identity.repository),
         true <- identifier == identity.identifier do
      uri |> Map.put(:fragment, nil) |> URI.to_string()
    else
      _value -> nil
    end
  end

  def normalize(_url, _identity), do: nil

  defp default_port?("http", 80), do: true
  defp default_port?("https", 443), do: true
  defp default_port?(_scheme, _port), do: false

  defp same?(left, right) when is_binary(left) and is_binary(right), do: String.downcase(left) == String.downcase(right)
  defp same?(_left, _right), do: false
end
