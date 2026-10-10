defmodule Aiur.Identity do
  @moduledoc """
  Read-only machine and instance identity for component consumers.
  The launcher owns `AIUR_INSTANCE_KEY`; missing identity is never fabricated.
  """

  alias Aiur.Identity.Machine

  @spec machine() :: {:ok, %{machine_id: String.t(), label: String.t()}} | {:degraded, atom()}
  def machine do
    case Machine.current() do
      {:ok, identity} -> {:ok, %{machine_id: identity.machine_id, label: identity.machine_label}}
      {:degraded, _reason, _detail} -> {:degraded, :identity_unreadable}
      :not_loaded -> {:degraded, :not_loaded}
    end
  end

  @spec instance_key() :: {:ok, String.t()} | {:error, :instance_key_missing | :instance_key_invalid}
  def instance_key do
    case System.get_env("AIUR_INSTANCE_KEY") do
      key when key in [nil, ""] -> {:error, :instance_key_missing}
      key -> if Regex.match?(~r/\A[A-Za-z0-9_-]{1,64}\z/, key), do: {:ok, key}, else: {:error, :instance_key_invalid}
    end
  end

  @spec instance_id() :: String.t() | nil
  def instance_id do
    with {:ok, machine} <- machine(), {:ok, key} <- instance_key() do
      machine.machine_id <> "/" <> key
    else
      _ -> nil
    end
  end

  @spec instance_section() :: %{instance_id: String.t() | nil, aiur_version: String.t(), run_shape: map()}
  def instance_section do
    http_listener = not Application.get_env(:aiur, :no_dashboard, false)

    %{
      instance_id: instance_id(),
      aiur_version: to_string(Application.spec(:aiur, :vsn) || "unknown"),
      run_shape: %{
        http_listener: http_listener,
        dashboard_pages: http_listener and Application.get_env(:aiur, :dashboard_pages, true) != false,
        dashboard: http_listener,
        headless: Application.get_env(:aiur, :headless, false),
        interactive_cli: Application.get_env(:aiur, :interactive_cli, false),
        executor_mode: Application.get_env(:aiur, :executor_mode, false)
      }
    }
  end

  @spec identity_capability() :: %{state: atom(), reason: atom() | nil}
  def identity_capability do
    case machine() do
      {:ok, _machine} -> key_capability(instance_key())
      {:degraded, :not_loaded} -> %{state: :unknown, reason: :unknown}
      {:degraded, reason} -> %{state: :degraded, reason: reason}
    end
  end

  defp key_capability({:ok, _key}), do: %{state: :available, reason: nil}
  defp key_capability({:error, reason}), do: %{state: :degraded, reason: reason}
end
