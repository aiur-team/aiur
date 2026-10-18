defmodule Aiur.Accounting.CLI do
  @moduledoc false
  alias Aiur.Accounts.UsageReadings
  alias Aiur.AccountsCLI
  alias Aiur.ProviderMeterProjection
  alias Aiur.ProviderMeters.CLI
  alias Aiur.Webhooks.ModePresenter
  import Aiur.ControlCLI.Protocol, only: [exit_marker: 1, guarded: 2]

  @doc """
  Print registry provider headroom from the daemon-owned meter projection.

  Every value carries the age of the observation, because meters are observed
  from live agent sessions: a number with no age cannot be told apart from a
  current one. A provider never observed prints as unknown, never as zero.

  Per-repo event delivery mode prints alongside the meters, because the two
  answer the same operator question — where is my quota going. A repo in
  polling mode always says *why*: never configured, configured but never
  delivered, or degraded after going silent. Repos with no webhooks anywhere
  print nothing extra, so this section only appears once it has something to
  say.
  """
  @spec usage(GenServer.server(), keyword()) :: :ok
  def usage(server \\ ProviderMeterProjection, opts \\ []) do
    guarded("usage", fn ->
      server
      |> ProviderMeterProjection.snapshot()
      |> Enum.sort_by(fn {provider, _view} -> provider end)
      |> Enum.each(&CLI.print/1)

      opts
      |> Keyword.get_lazy(:delivery_modes, fn -> ModePresenter.rows() end)
      |> print_delivery_modes()

      exit_marker(0)
    end)
  end

  @doc false
  @spec accounts(boolean(), String.t() | nil) :: :ok
  def accounts(json, harness \\ nil) do
    guarded("accounts", fn ->
      AccountsCLI.accounts(json, harness, &UsageReadings.snapshot("claude", &1))
      exit_marker(0)
    end)
  end

  defp print_delivery_modes([]), do: :ok

  defp print_delivery_modes(rows) do
    IO.puts("")

    Enum.each(
      rows,
      &IO.puts("events  #{&1.repo}  #{&1.mode_label}  last delivery #{&1.last_delivery_label}#{polling_reason_suffix(&1)}")
    )
  end

  defp polling_reason_suffix(%{reason_label: nil}), do: ""
  defp polling_reason_suffix(%{reason_label: label}), do: "  (#{label})"
end
