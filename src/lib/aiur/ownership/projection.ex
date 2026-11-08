defmodule Aiur.Ownership.Projection do
  @moduledoc """
  Mirrors the ownership ref (authoritative, KTD-2) onto a `gateway:<slug>` issue label.

  `reconcile/2` is pure. `project/3` and `alert_ambiguous/3` are the effects: the label is
  created with its colour before it is added (adding an unknown label makes GitHub pick the
  colour), and the alert is deduplicated per ticket by the event publisher's one-hour window.
  The projection never removes a label.
  """

  require Logger

  alias Aiur.GitHub.IssueState
  alias Aiur.GitHub.Labels

  @type ref_read :: {:owned, map()} | :unowned | {:unreadable, term()}
  @type decision ::
          {:project, String.t()}
          | :consistent
          | :foreign
          | :unlabelled
          | {:hint_other, String.t()}
          | {:assignment_request, [String.t()]}
          | {:ambiguous, :label_disagrees | :ref_unreadable}

  @doc "GitHub caps label names at 50 characters and `gateway:` takes 8."
  @spec slug(String.t() | nil, String.t()) :: String.t()
  def slug(label, gateway_id) do
    cleaned =
      (label || "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.slice(0, 42)
      |> String.trim("-")

    if cleaned == "", do: gateway_id |> to_string() |> String.downcase() |> String.slice(0, 8), else: cleaned
  end

  @spec gateway_labels([String.t()]) :: [String.t()]
  def gateway_labels(labels) do
    for label <- labels, [_, slug] <- [Regex.run(~r/^gateway:(.+)$/i, to_string(label))], do: String.downcase(slug)
  end

  @doc """
  `view` is `%{labels: [String.t()], self: %{gateway_id:, gateway_label:, daemon_key:}}`.
  """
  @spec reconcile(ref_read(), map()) :: decision()
  def reconcile(ref, %{labels: labels, self: self}) do
    found = labels |> gateway_labels() |> Enum.uniq() |> Enum.sort()
    decide(ref, found, has_state_label?(labels), slug(self.gateway_label, self.gateway_id), self)
  end

  defp decide({:unreadable, _}, _found, _state?, _mine, _self), do: {:ambiguous, :ref_unreadable}

  defp decide({:owned, r}, found, _state?, mine, self) do
    cond do
      r.gateway_id == self.gateway_id and r.daemon_key != self.daemon_key -> :foreign
      r.gateway_id == self.gateway_id -> own(found, mine)
      found in [[], [slug(Map.get(r, :gateway_label), r.gateway_id)]] -> :foreign
      true -> {:ambiguous, :label_disagrees}
    end
  end

  defp decide(:unowned, [], _state?, _mine, _self), do: :unlabelled
  defp decide(:unowned, found, false, _mine, _self), do: {:assignment_request, found}
  defp decide(:unowned, [mine], true, mine, _self), do: :unlabelled
  defp decide(:unowned, [other], true, _mine, _self), do: {:hint_other, other}
  defp decide(:unowned, _many, true, _mine, _self), do: {:ambiguous, :label_disagrees}

  defp own([], mine), do: {:project, mine}
  defp own([mine], mine), do: :consistent
  defp own(_found, _mine), do: {:ambiguous, :label_disagrees}

  defp has_state_label?(labels) do
    suffixes = Labels.state_suffixes()

    Enum.any?(labels, fn l ->
      case String.split(to_string(l), ":") do
        [_, suffix] -> suffix in suffixes
        _ -> false
      end
    end)
  end

  @doc "Ensures the label (once per daemon), then adds it. Failures are logged and retried next poll."
  @spec project(Aiur.Issue.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def project(issue, slug, opts \\ []) do
    ensure = Keyword.get(opts, :ensure_fun, &ensure_label/2)
    add = Keyword.get(opts, :add_fun, &IssueState.add_label/2)
    name = "gateway:" <> slug

    with :ok <- ensure.(issue, slug), :ok <- add.(to_string(issue.identifier), name) do
      :ok
    else
      {:error, reason} = error ->
        Logger.warning("Gateway label #{name} not applied to ##{issue.identifier}: #{inspect(reason)}")
        error
    end
  end

  defp ensure_label(issue, slug) do
    key = {__MODULE__, :ensured, issue.tracker_identity && {issue.tracker_identity.owner, issue.tracker_identity.repository}, slug}

    with false <- :persistent_term.get(key, false),
         {:ok, {owner, repo}} <- Aiur.GitHub.Access.parse_repo(),
         {:ok, token} <- Aiur.GitHub.Access.require_token(),
         :ok <- Labels.ensure_with(owner, repo, token, [Labels.gateway_label(slug)]) do
      :persistent_term.put(key, true)
    else
      true -> :ok
      {:error, _} = error -> error
    end
  end

  @doc "One alert per ticket per hour: the publisher's replay window is the dedupe."
  @spec alert_ambiguous(Aiur.Issue.t(), atom(), keyword()) :: :ok
  def alert_ambiguous(issue, reason, opts \\ []) do
    emit = Keyword.get(opts, :alert_fun, &Aiur.Alerts.emit_system/2)
    labels = issue.labels |> gateway_labels() |> Enum.join(", ")
    repo = (issue.tracker_identity && "#{issue.tracker_identity.owner}/#{issue.tracker_identity.repository}") || "unknown"

    _ =
      emit.("system.ownership.ambiguous",
        message: "Ticket ##{issue.identifier} in #{repo}: ownership #{reason}, gateway labels [#{labels}]. Skipped.",
        issue: to_string(issue.identifier),
        needs_attention: true,
        severity: "warning",
        dedup_key: {:ownership_ambiguous, repo, to_string(issue.identifier)},
        bypass_contamination: true,
        exchange_payload: %{
          "repo" => repo,
          "ticket" => to_string(issue.identifier),
          "reason" => to_string(reason),
          "ref_gateway_id" => Keyword.get(opts, :ref_gateway_id),
          "labels" => gateway_labels(issue.labels)
        }
      )

    :ok
  end
end
