defmodule Aiur.Config.Schema.Codex do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Aiur.Config.Schema.StringOrMap

  @valid_approval_policies ~w(untrusted on-failure on-request granular never)

  @doc false
  @spec validate_approval_policy(term()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_approval_policy(value) when is_binary(value) do
    case String.trim(value) do
      trimmed when trimmed in @valid_approval_policies -> {:ok, trimmed}
      _ -> {:error, invalid_approval_policy(value)}
    end
  end

  def validate_approval_policy(value), do: {:error, invalid_approval_policy(value)}

  @doc false
  @spec valid_policies() :: [String.t()]
  def valid_policies, do: @valid_approval_policies

  defp invalid_approval_policy(value) do
    "Invalid codex.approval_policy #{inspect(value)} — must be one of: " <>
      Enum.join(@valid_approval_policies, ", ")
  end

  @primary_key false
  embedded_schema do
    field(:command, :string, default: "codex app-server")

    # codex app-server expects an enum string (untrusted | on-failure |
    # on-request | granular | never); a map crashes the turn. `untrusted`
    # preserves the prior fail-closed default (only `never` auto-approves).
    field(:approval_policy, StringOrMap, default: "untrusted")

    field(:thread_sandbox, :string, default: "workspace-write")
    field(:turn_sandbox_policy, :map)
    field(:read_timeout_ms, :integer, default: 5_000)
    # Codex-specific thrash guard (moved out of the shared agent section).
    field(:thrash_max_per_window, :integer, default: 6)
    field(:thrash_window_seconds, :integer, default: 60)
    # IANA zone that Codex's "try again at 6:26 PM" usage-limit text is read in
    # (#2737). nil reads it in the daemon host's local zone. Set it to the
    # worker's zone when the app-server runs on a remote worker_host.
    field(:reset_time_zone, :string)
    # A usage-limit text reset that already passed resumes no sooner than this
    # many seconds after the refusal (#2737).
    field(:reset_min_delay_seconds, :integer, default: 300)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(
      attrs,
      [
        :command,
        :approval_policy,
        :thread_sandbox,
        :turn_sandbox_policy,
        :read_timeout_ms,
        :thrash_max_per_window,
        :thrash_window_seconds,
        :reset_time_zone,
        :reset_min_delay_seconds
      ],
      empty_values: []
    )
    |> validate_required([:command])
    |> validate_length(:command, min: 1)
    |> validate_number(:read_timeout_ms, greater_than: 0)
    |> validate_number(:thrash_max_per_window, greater_than: 0)
    |> validate_number(:thrash_window_seconds, greater_than: 0)
    |> validate_number(:reset_min_delay_seconds, greater_than: 0)
    |> validate_change(:reset_time_zone, &validate_time_zone/2)
  end

  defp validate_time_zone(field, zone) do
    case DateTime.now(zone, Tz.TimeZoneDatabase) do
      {:ok, _now} -> []
      {:error, _reason} -> [{field, "must be an IANA time zone, for example America/Los_Angeles"}]
    end
  end
end
