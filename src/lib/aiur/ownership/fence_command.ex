defmodule Aiur.Ownership.FenceCommand do
  @moduledoc """
  Socket command behind the guards' ownership fence. Moved and unknown are ordinary
  output lines, so a guard can tell them from a socket error (which would be exit 1).
  """

  alias Aiur.Ownership.Fence

  @actions ~w(push pr-create pr-ready pr-merge api-pr-write)

  @spec execute([String.t()], keyword()) :: {:ok, String.t()} | {:error, :invalid_request}
  def execute(args, opts \\ [])

  def execute(["fence", "--workspace", workspace, "--action", action], opts) when action in @actions do
    case Fence.check(Path.basename(workspace), opts) do
      {:ok, %{epoch: epoch}} -> {:ok, "ok epoch=#{epoch}\n"}
      {:moved, %{owner: owner, epoch: epoch, state: state}} -> {:ok, "moved owner=#{token(owner)} epoch=#{epoch} state=#{token(state)}\n"}
      {:unknown, why} -> {:ok, "unknown #{token(why)}\n"}
    end
  end

  def execute(_args, _opts), do: {:error, :invalid_request}

  defp token(value) do
    value |> then(&if(is_binary(&1), do: &1, else: inspect(&1))) |> String.replace(~r/[^\w.=\-]+/, "_") |> String.trim("_")
  end
end
