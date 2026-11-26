defmodule Aiur.Experiments.Preregistration do
  @moduledoc false
  alias Aiur.Experiments.ContractSchema

  @spec prepare(term(), map() | nil, String.t() | nil, DateTime.t()) :: {:ok, map()} | {:error, term()}
  def prepare(attrs, existing, first_read, now) when is_map(attrs) do
    at = DateTime.to_iso8601(now)
    record = attrs |> Map.delete("reason") |> Map.put("registered_at", at) |> Map.put("post_hoc", post_hoc?(first_read, now)) |> Map.put("amendments", [])
    with :ok <- ContractSchema.validate(record, "preregistration"), do: amend(existing, record, attrs["reason"], at)
  end

  def prepare(_attrs, _existing, _first_read, _now), do: {:error, [%{path: "preregistration", message: "expected object"}]}

  defp amend(nil, record, _reason, _at), do: {:ok, record}

  defp amend(existing, record, reason, at) when is_binary(reason) do
    if String.trim(reason) == "" do
      reason_required()
    else
      amendment = %{"at" => at, "reason" => reason, "post_hoc" => record["post_hoc"], "record" => record}
      {:ok, Map.update!(existing, "amendments", &(&1 ++ [amendment]))}
    end
  end

  defp amend(_existing, _record, _reason, _at), do: reason_required()
  defp reason_required, do: {:error, [%{path: "reason", message: "an amendment requires a reason"}]}
  defp post_hoc?(nil, _now), do: false

  defp post_hoc?(first_read, now) do
    {:ok, read_at, _offset} = DateTime.from_iso8601(first_read)
    DateTime.compare(now, read_at) != :lt
  end
end
