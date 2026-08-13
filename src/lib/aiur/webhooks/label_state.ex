defmodule Aiur.Webhooks.LabelState do
  @moduledoc """
  Derives issue/PR label state from a webhook payload as *state*, never as a
  delta.

  Delivery order is not event order. A `labeled` and an `unlabeled` delivery
  for the same issue can arrive in either order, so applying `payload["label"]`
  as an add/remove instruction converges to whichever delivery happened to land
  last. GitHub avoids that for us: the `issue` (or `pull_request`) object in
  every payload carries the **complete label list as of that action**, so
  applying that list wholesale converges on GitHub's own state as long as the
  newest payload wins.

  `derive/1` extracts that full list plus the payload's position on the
  timeline. `converge/2` compares an incoming position against the last one
  applied and answers:

  * `{:apply, state}` — the payload is newer; apply its full label list.
  * `{:skip, :stale}` — a newer payload was already applied.
  * `{:refresh, :ambiguous_timestamp}` — same position as the last applied
    payload. GitHub timestamps have one-second resolution, so a
    labeled/unlabeled pair inside one second is genuinely unorderable from the
    payloads alone. A plain redelivery of an already-applied event never
    reaches here — it is caught by the delivery id or by
    `Aiur.Webhooks.EventKey` — so an equal position means two *different*
    label events in the same second, and the honest answer is to re-read the
    issue from the API instead of guessing which is newer.
  """

  @type t :: %{issue_number: pos_integer(), labels: [String.t()], position: integer()}

  @doc """
  Extracts the full post-action label state from an `issues` or `pull_request`
  payload. Returns `:error` when the payload carries no usable label state.
  """
  @spec derive(term()) :: {:ok, t()} | :error
  def derive(payload) when is_map(payload) do
    with subject when is_map(subject) <- subject(payload),
         number when is_integer(number) and number > 0 <- Map.get(subject, "number"),
         position when is_integer(position) <- position(subject),
         labels when is_list(labels) <- label_names(subject) do
      {:ok, %{issue_number: number, labels: labels, position: position}}
    else
      _ -> :error
    end
  end

  def derive(_payload), do: :error

  @doc """
  Decides whether `incoming` supersedes the already-applied state at `known`,
  the last applied position (or `nil` when nothing has been applied yet).
  """
  @spec converge(integer() | nil, t()) :: {:apply, t()} | {:skip, :stale} | {:refresh, :ambiguous_timestamp}
  def converge(nil, %{} = incoming), do: {:apply, incoming}

  def converge(known, %{position: position} = incoming) when is_integer(known) do
    cond do
      position > known -> {:apply, incoming}
      position < known -> {:skip, :stale}
      true -> {:refresh, :ambiguous_timestamp}
    end
  end

  defp subject(payload) do
    case Map.get(payload, "issue") do
      subject when is_map(subject) -> subject
      _ -> Map.get(payload, "pull_request")
    end
  end

  defp label_names(subject) do
    case Map.get(subject, "labels") do
      labels when is_list(labels) ->
        labels
        |> Enum.map(fn
          %{"name" => name} when is_binary(name) -> name
          name when is_binary(name) -> name
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()

      _ ->
        nil
    end
  end

  defp position(subject) do
    with updated_at when is_binary(updated_at) <- Map.get(subject, "updated_at"),
         {:ok, datetime, _offset} <- DateTime.from_iso8601(updated_at) do
      DateTime.to_unix(datetime, :millisecond)
    else
      _ -> nil
    end
  end
end
