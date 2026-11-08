defmodule Aiur.Intent.Change do
  @moduledoc """
  One shared-intent change (schema S4). Pure: construction, validation and JSON round-trip.

  Errors are static atoms; no entity key, path or value is ever interpolated into one.
  """

  @slots ~w(human executor default)
  @kinds ~w(project feature ticket gateway fleet)
  @fields %{
    "ticket" => ~w(order_key),
    "gateway" => ~w(pause),
    "fleet" => ~w(pause),
    "project" => ~w(priority order_key focus),
    "feature" => ~w(priority order_key focus)
  }
  @max_value_bytes 8192
  @max_counter 2_147_483_647
  @repo_key ~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/

  @keys ~w(change_id hlc_wall_ms hlc_counter origin_gateway slot author_id entity_kind entity_key field value_json supersedes force reason seq received_at)a

  defstruct change_id: nil,
            hlc_wall_ms: nil,
            hlc_counter: nil,
            origin_gateway: nil,
            slot: nil,
            author_id: nil,
            entity_kind: nil,
            entity_key: nil,
            field: nil,
            value_json: nil,
            supersedes: nil,
            force: false,
            reason: nil,
            seq: nil,
            received_at: nil

  @type t :: %__MODULE__{}

  @spec new_id() :: String.t()
  def new_id do
    <<a::32, b::16, _::4, c::12, _::2, d::14, e::48>> = :crypto.strong_rand_bytes(16)
    hex = Base.encode16(<<a::32, b::16, 4::4, c::12, 2::2, d::14, e::48>>, case: :lower)
    <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> = hex
    Enum.join([p1, p2, p3, p4, p5], "-")
  end

  @doc "Dumps a hyphenated UUID string to the 16-byte form Postgrex binds for `uuid`."
  @spec uuid_to_binary(String.t() | nil) :: binary() | nil
  def uuid_to_binary(nil), do: nil
  def uuid_to_binary(id), do: id |> String.replace("-", "") |> Base.decode16!(case: :mixed)

  @spec uuid_from_binary(binary() | nil) :: String.t() | nil
  def uuid_from_binary(nil), do: nil

  def uuid_from_binary(<<a::binary-4, b::binary-2, c::binary-2, d::binary-2, e::binary-6>>) do
    [a, b, c, d, e] |> Enum.map_join("-", &Base.encode16(&1, case: :lower))
  end

  @doc "Builds a change from author attributes; `change_id` is filled, the HLC is stamped later."
  @spec new(map() | keyword()) :: t()
  def new(attrs) do
    struct(__MODULE__, attrs |> Map.new() |> Map.take(@keys) |> Map.put_new_lazy(:change_id, &new_id/0))
  end

  @spec validate(t()) :: :ok | {:error, atom()}
  def validate(%__MODULE__{} = c) do
    [
      {c.slot in @slots, :invalid_slot},
      {c.entity_kind in @kinds, :invalid_entity_kind},
      {c.field in Map.get(@fields, c.entity_kind, []), :invalid_field},
      {not (c.field == "pause" and c.slot == "default"), :daemon_pause_rejected},
      {force_ok?(c), :force_requires_reason_and_supersedes},
      {not c.force or c.slot == "executor", :force_requires_executor_slot},
      {key_ok?(c), :invalid_entity_key},
      {value_ok?(c.value_json), :value_too_large},
      {hlc_ok?(c), :invalid_hlc}
    ]
    |> Enum.find_value(:ok, fn {ok?, error} -> if ok?, do: nil, else: {:error, error} end)
  end

  defp force_ok?(%{force: true, reason: r, supersedes: s}),
    do: is_binary(r) and String.trim(r) != "" and byte_size(r) <= 500 and not is_nil(s)

  defp force_ok?(%{force: false}), do: true
  defp force_ok?(_), do: false

  defp key_ok?(%{entity_key: k}) when not is_binary(k), do: false

  defp key_ok?(%{entity_key: k, entity_kind: kind}) do
    not (String.starts_with?(k, ["/", "~"]) or String.contains?(k, "..")) and
      (kind != "project" or Regex.match?(@repo_key, k))
  end

  defp value_ok?(v), do: match?({:ok, j} when byte_size(j) <= @max_value_bytes, Jason.encode(v))

  defp hlc_ok?(%{hlc_wall_ms: w, hlc_counter: n}),
    do: is_integer(w) and w >= 0 and is_integer(n) and n in 0..@max_counter

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = c), do: c |> Map.from_struct() |> Map.new(fn {k, v} -> {Atom.to_string(k), enc(v)} end)

  defp enc(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp enc(v), do: v

  @spec from_json(map()) :: {:ok, t()} | {:error, :invalid_change}
  def from_json(%{} = map) do
    attrs = for k <- @keys, Map.has_key?(map, Atom.to_string(k)), into: %{}, do: {k, Map.fetch!(map, Atom.to_string(k))}
    attrs = Map.update(attrs, :received_at, nil, &dec_time/1)
    change = struct(__MODULE__, attrs)
    if is_binary(change.change_id) and validate(change) == :ok, do: {:ok, change}, else: {:error, :invalid_change}
  end

  def from_json(_), do: {:error, :invalid_change}

  defp dec_time(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp dec_time(other), do: other
end
