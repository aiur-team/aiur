defmodule AiurPushRelay.Envelope do
  @moduledoc "Validates the opaque relay envelope; unknown fields never reach the provider."
  @fields ~w(v handle push_class ttl_s collapse_token sealed kid idempotency_key fallback)

  def validate(params, pin) when is_map(params) do
    cond do
      is_binary(params["sealed"]) and byte_size(params["sealed"]) > 3400 -> {:error, :too_large}
      not is_map(pin) or not schema?(params) -> {:error, :schema}
      params["fallback"] != pin -> {:error, :fallback_mismatch}
      true -> {:ok, params |> Map.take(@fields) |> Map.put("fallback", pin)}
    end
  end

  def validate(_, _), do: {:error, :schema}

  defp schema?(p) do
    p["v"] == 1 and p["push_class"] in ["alert_high", "alert_normal"] and
      is_integer(p["ttl_s"]) and p["ttl_s"] in 0..2_419_200 and
      text?(p["handle"], 64) and text?(p["sealed"], 3400) and
      text?(p["kid"], 200) and text?(p["idempotency_key"], 200) and
      (is_nil(p["collapse_token"]) or text?(p["collapse_token"], 64))
  end

  defp text?(value, max), do: is_binary(value) and byte_size(value) in 1..max
end
