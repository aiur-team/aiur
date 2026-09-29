defmodule Aiur.TestTicketScope do
  @moduledoc """
  Limits issue discovery for the development `aiurdev --test` harness.

  The launcher validates the pinned ticket file before exporting the internal
  scope. An absent scope leaves ordinary runs unchanged; a malformed one must
  fail closed before startup cleanup can touch a workspace.
  """

  @env "AIUR_DEV_TEST_TICKET_IDS"

  @spec validate!() :: :ok
  def validate! do
    _ids = allowed_ids!()
    :ok
  end

  @spec filter_result(term()) :: term()
  def filter_result({:ok, issues}) when is_list(issues), do: {:ok, filter_issues(issues)}
  def filter_result({:ok, issues, cache}) when is_list(issues), do: {:ok, filter_issues(issues), cache}
  def filter_result(other), do: other

  @spec filter_issues(list()) :: list()
  def filter_issues(issues) when is_list(issues) do
    case allowed_ids!() do
      :all -> issues
      allowed -> Enum.filter(issues, &MapSet.member?(allowed, identifier(&1)))
    end
  end

  @spec allowed_identifier?(String.t() | nil) :: boolean()
  def allowed_identifier?(identifier) when is_binary(identifier) do
    case allowed_ids!() do
      :all -> true
      allowed -> MapSet.member?(allowed, identifier)
    end
  end

  def allowed_identifier?(_identifier), do: allowed_ids!() == :all

  defp identifier(%{identifier: identifier}) when is_binary(identifier), do: identifier
  defp identifier(%{identifier: identifier}) when is_integer(identifier), do: Integer.to_string(identifier)
  defp identifier(_issue), do: nil

  defp allowed_ids! do
    case System.get_env(@env) do
      nil ->
        :all

      ids when is_binary(ids) ->
        if Regex.match?(~r/\A[1-9][0-9]*(?:,[1-9][0-9]*)*\z/, ids) do
          ids |> String.split(",") |> MapSet.new()
        else
          raise ArgumentError, "invalid #{@env}; expected comma-separated positive ticket IDs"
        end
    end
  end
end
