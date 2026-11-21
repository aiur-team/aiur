defmodule Aiur.ControlCLI.DispatchAccount do
  @moduledoc """
  The account suffix that `aiur status` and `aiur agents` print for a row:
  which backend account the session runs on, the score of a headroom choice
  (#3960), and the capacity policy's reason (#7892): why a running ticket got
  its source, or `waiting: no authorized source: …` for a queued ticket.
  """

  @doc """
  ` [account claude/everdred; headroom: claude/everdred=64%; claude/everdred (preferred; 64% left, 40s old)]`
  for a row with an account, a selection reason or a capacity reason, and `""` otherwise.
  """
  @spec suffix(map()) :: String.t()
  def suffix(row) when is_map(row) do
    parts = Enum.reject([account(row), present(row[:account_selection_reason]), present(row[:capacity_reason])], &is_nil/1)
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
