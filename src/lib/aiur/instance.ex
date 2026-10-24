defmodule Aiur.Instance do
  @moduledoc """
  Ticket ownership filter for multi-instance runs (`instance.ignore`).

  A ticket is *foreign* when another live daemon owns it (or shared ownership
  cannot be read), or its number is listed in
  `instance.ignore.tickets`, it carries a label in `instance.ignore.labels`, or
  it carries a `<prefix>:*` label for a prefix in `instance.ignore.label_prefixes`.
  Per-ticket observers and the Executor wake projection skip foreign tickets.
  Dispatch takes a shared lease after its tracker-label eligibility check.
  Ignore rules are read from the live config on every call, so they hot-reload.
  """

  require Logger

  alias Aiur.Config.Schema.Instance.Ignore
  alias Aiur.Instance.Identity
  alias Aiur.Instance.LeaseStore

  @counter_key {__MODULE__, :ignored}

  @doc """
  True when `ticket` is owned by another instance. `labels` may be omitted when
  the caller does not have them; label rules then fall back to the open-ticket
  snapshot. If config or the label snapshot is unavailable, filtering fails
  closed while ownership rules or shared coordination are active.
  """
  @spec foreign?(term(), [String.t() | map()] | nil) :: boolean()
  def foreign?(ticket, labels \\ nil) do
    case rules_result() do
      {:ok, rules} -> foreign?(ticket, labels, rules)
      {:error, _reason} -> true
    end
  end

  @doc false
  @spec foreign?(term(), [String.t() | map()] | nil, Ignore.t()) :: boolean()
  def foreign?(ticket, labels, %Ignore{} = rules) do
    foreign_by_shared_lease?(ticket) or foreign_by_rules?(ticket, labels, rules)
  end

  defp foreign_by_rules?(ticket, labels, rules) do
    number = number(ticket)

    cond do
      empty?(rules) ->
        false

      number != nil and number in rules.tickets ->
        true

      rules.labels == [] and rules.label_prefixes == [] ->
        false

      true ->
        case labels_for(labels, number) do
          labels when is_list(labels) -> Enum.any?(labels, &label_matches?(&1, rules))
          :unknown -> true
        end
    end
  end

  @doc "True when any issue a PR closes is foreign (`closing` is a list of issue numbers or refs)."
  @spec foreign_pr?([term()] | nil) :: boolean()
  def foreign_pr?(closing) when is_list(closing) do
    case rules_result() do
      {:ok, rules} ->
        (not empty?(rules) and Enum.any?(closing, &foreign?(&1, nil, rules))) or
          Enum.any?(closing, &foreign_by_shared_lease?/1)

      {:error, _reason} ->
        closing != []
    end
  end

  def foreign_pr?(_closing), do: false

  @doc """
  Records one skipped action for a foreign ticket: logs `instance.ignored` and
  bumps the since-boot counter `aiur status` renders. Returns `true` so callers
  can write `Instance.foreign?(...) and Instance.ignored(...)`.
  """
  @spec ignored(term(), atom() | String.t()) :: true
  def ignored(ticket, consumer) do
    :counters.add(counter(), 1, 1)
    Logger.info("instance.ignored consumer=#{consumer} ticket=#{inspect(ticket)}")
    true
  end

  @doc "Foreign check that records the skip when it applies."
  @spec skip?(term(), [String.t() | map()] | nil, atom() | String.t()) :: boolean()
  def skip?(ticket, labels, consumer), do: foreign?(ticket, labels) and ignored(ticket, consumer)

  @doc "Ignored-event count since boot."
  @spec ignored_count() :: non_neg_integer()
  def ignored_count, do: :counters.get(counter(), 1)

  @doc "The active ignore rules, or empty lists for a status projection when config is unreadable."
  @spec rules() :: Ignore.t()
  def rules do
    case rules_result() do
      {:ok, rules} -> rules
      {:error, _reason} -> %Ignore{}
    end
  end

  @doc false
  @spec rules_result() :: {:ok, Ignore.t()} | {:error, term()}
  def rules_result do
    case Aiur.Config.settings() do
      {:ok, %{instance: %{ignore: %Ignore{} = ignore}}} -> {:ok, ignore}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :instance_rules_unavailable}
    end
  rescue
    error -> {:error, error}
  end

  @doc "Status projection: active rules plus the since-boot ignored count."
  @spec status() :: map()
  def status do
    rules = rules()

    %{
      tickets: rules.tickets,
      labels: rules.labels,
      label_prefixes: rules.label_prefixes,
      ignored_since_boot: ignored_count()
    }
  end

  @doc "One `aiur status` line naming the active ignore rules and the since-boot ignored count."
  @spec status_line(map()) :: String.t()
  def status_line(status \\ status()) do
    rules =
      Enum.map_join(
        [:tickets, :labels, :label_prefixes],
        " ",
        &"#{&1}=[#{Enum.join(status[&1], ",")}]"
      )

    "INSTANCE IGNORE #{rules} ignored_since_boot=#{status.ignored_since_boot}"
  end

  defp empty?(%Ignore{tickets: [], labels: [], label_prefixes: []}), do: true
  defp empty?(_rules), do: false

  defp foreign_by_shared_lease?(ticket) do
    foreign_by_shared_lease?(ticket, &LeaseStore.holder/1)
  end

  @doc false
  @spec foreign_by_shared_lease?(term(), (term() -> term())) :: boolean()
  def foreign_by_shared_lease?(ticket, holder_fun) when is_function(holder_fun, 1) do
    case holder_fun.(ticket) do
      {:held, holder_id} -> holder_id != Identity.current()
      value when value in [:unheld, :disabled] -> false
      _unknown_or_error -> true
    end
  rescue
    _ -> true
  end

  defp label_matches?(label, rules) do
    label = label |> label_name() |> String.downcase()

    Enum.any?(rules.labels, &(String.downcase(&1) == label)) or
      Enum.any?(
        rules.label_prefixes,
        &String.starts_with?(label, String.downcase(String.trim_trailing(&1, ":")) <> ":")
      )
  end

  defp label_name(%{"name" => name}), do: to_string(name)
  defp label_name(%{name: name}), do: to_string(name)
  defp label_name(label), do: to_string(label)

  defp labels_for(labels, _number) when is_list(labels), do: labels
  defp labels_for(_labels, nil), do: :unknown

  # Labels come from the open-ticket snapshot (registered at boot, since config
  # sits below github); missing tickets and unavailable snapshots are unknown.
  defp labels_for(_labels, number) do
    case Application.get_env(:aiur, :instance_ticket_labels_fun) do
      lookup when is_function(lookup, 1) ->
        case lookup.(number) do
          labels when is_list(labels) -> labels
          _ -> :unknown
        end

      _ ->
        :unknown
    end
  rescue
    _ -> :unknown
  end

  @doc false
  @spec number(term()) :: integer() | nil
  def number(ticket) when is_integer(ticket), do: ticket
  def number(%{number: number}), do: number(number)
  def number(%{"number" => number}), do: number(number)
  def number(%{identifier: identifier}), do: number(identifier)

  def number(ticket) when is_binary(ticket) do
    case Regex.run(~r/(\d+)\s*$/, ticket) do
      [_, digits] -> String.to_integer(digits)
      _ -> nil
    end
  end

  def number(_ticket), do: nil

  defp counter do
    case :persistent_term.get(@counter_key, nil) do
      nil ->
        ref = :counters.new(1, [:write_concurrency])
        :persistent_term.put(@counter_key, ref)
        ref

      ref ->
        ref
    end
  end
end
