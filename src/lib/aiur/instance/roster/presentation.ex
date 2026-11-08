defmodule Aiur.Instance.Roster.Presentation do
  @moduledoc false

  @spec leader_label(boolean() | nil) :: String.t()
  def leader_label(true), do: "yes"
  def leader_label(false), do: "no"
  def leader_label(_), do: "unknown"

  @spec executor(boolean() | nil) :: String.t()
  def executor(true), do: "present"
  def executor(false), do: "absent"
  def executor(_), do: "unknown"

  @spec projects([map()] | nil) :: String.t()
  def projects(rows) when is_list(rows), do: Enum.map_join(rows, ",", &"#{&1["repo"]}:#{&1["running"]}")
  def projects(_), do: "unknown"

  @spec count(integer() | term()) :: String.t()
  def count(value) when is_integer(value), do: Integer.to_string(value)
  def count(_), do: "unknown"

  @spec age(non_neg_integer()) :: String.t()
  def age(ms) when is_integer(ms) and ms < 60_000, do: "#{div(ms, 1_000)} seconds"
  def age(ms) when is_integer(ms), do: "#{div(ms, 60_000)} minutes"
end
