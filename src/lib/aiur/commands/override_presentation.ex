defmodule Aiur.Commands.OverridePresentation do
  @moduledoc false

  alias Aiur.{DecisionSanitizer, JSONSafe}

  @spec rows(map()) :: [map()]
  def rows(decision) do
    decision = JSONSafe.normalize(decision)
    Enum.map(decision["overrides"] || [], &row(&1, decision))
  end

  @spec pending(map()) :: map() | nil
  def pending(decision), do: decision |> rows() |> Enum.reverse() |> Enum.find(& &1.pending?)

  defp row(record, decision) do
    %{
      label: label(record),
      pending?: record["state"] not in ["implemented", "superseded"],
      at: record["superseded_at"] || record["implemented_at"] || record["delivered_at"] || record["queued_at"],
      actor: actor(record, decision),
      links: links(record, decision)
    }
  end

  defp label(%{"state" => "superseded"}), do: "Superseded"
  defp label(%{"state" => "implemented", "evidence" => %{"pr_number" => number}}), do: "Implemented in PR ##{number}"
  defp label(%{"state" => "implemented"}), do: "Implemented · PR unknown"
  defp label(%{"state" => "failed"}), do: "Override failed"
  defp label(%{"corrective_ticket" => %{"identifier" => id}} = record), do: "Corrective ticket ##{id} · #{record["state"]}"

  defp label(%{"state" => "delivered", "evidence" => %{"kind" => "push", "worker_reported" => true, "pr_number" => number}}),
    do: "Implemented in PR ##{number} (awaiting merge)"

  defp label(%{"state" => "delivered"}), do: "Delivered"
  defp label(%{"state" => "queued", "route" => "capacity_wait"}), do: "Queued — waiting for a slot"
  defp label(%{"state" => "queued", "route" => "resume_pending", "ticket" => %{"identifier" => id}}), do: "Queued — resuming ##{id}"
  defp label(%{"state" => "queued", "route" => "corrective_ticket"}), do: "Queued — creating corrective ticket"
  defp label(%{"state" => "queued", "route" => "replacement"}), do: "Queued — recovering worker"
  defp label(%{"state" => "queued"}), do: "Queued"
  defp label(_unknown), do: "Override status unknown"

  defp actor(record, decision) do
    revision = Enum.find(decision["revisions"] || [], &(&1["action_id"] == record["action_id"])) || %{}
    actor = get_in(revision, ["answer", "actor"]) || %{}
    actor["label"] || actor["id"] || actor["kind"] || "Unknown actor"
  end

  defp links(record, decision) do
    ticket = record["ticket"] || decision["ticket"] || %{}
    corrective = record["corrective_ticket"] || %{}
    number = get_in(record, ["evidence", "pr_number"]) || record["pr_number"]
    pr_ticket = if record["state"] == "implemented" and corrective != %{}, do: corrective, else: ticket

    [
      %{label: "Original Command", href: "/commands/" <> URI.encode(decision["decision_id"], &URI.char_unreserved?/1)},
      %{label: "Ticket ##{ticket["identifier"]}", href: DecisionSanitizer.ticket(ticket).url},
      %{label: "PR ##{number}", href: pr_url(pr_ticket["url"], number)},
      %{label: "Original PR ##{record["pr_number"]}", href: if(pr_ticket != ticket, do: pr_url(ticket["url"], record["pr_number"]))},
      %{label: "Corrective ticket ##{corrective["identifier"]}", href: DecisionSanitizer.ticket(corrective).url}
    ]
    |> Enum.reject(&is_nil(&1.href))
  end

  defp pr_url(url, number) when is_binary(url) and is_integer(number) do
    case URI.parse(url) do
      %URI{scheme: "https", host: "github.com", path: path} ->
        case String.split(path || "", "/", trim: true) do
          [owner, repo, "issues", _id] -> "https://github.com/#{owner}/#{repo}/pull/#{number}"
          _other -> nil
        end

      _other ->
        nil
    end
  end

  defp pr_url(_url, _number), do: nil
end
