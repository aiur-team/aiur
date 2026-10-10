defmodule Aiur.ControlCli.DispatchAccount do
  @moduledoc """
  The account suffix that `aiur status` and `aiur agents` print for a running
  row: which backend account the session runs on and, for a headroom dispatch
  (#3960), the score of the choice and of every alternative.
  """

  @doc """
  ` [account claude/everdred; headroom: claude/everdred=64%; alternatives codex=5%]`
  for a row with an account or a selection reason, and `""` otherwise.
  """
  @spec suffix(map()) :: String.t()
  def suffix(row) when is_map(row) do
    parts = Enum.reject([account(row), present(row[:account_selection_reason])], &is_nil/1)
    if parts == [], do: "", else: " [" <> Enum.join(parts, "; ") <> "]"
  end

  def suffix(_row), do: ""

  defp account(%{account: account} = row) when is_binary(account) and account != "" do
    if is_binary(row[:backend]), do: "account #{row[:backend]}/#{account}", else: "account #{account}"
  end

  defp account(_row), do: nil

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil
end
