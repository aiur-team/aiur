defmodule Aiur.Instance do
  @moduledoc """
  Ticket ownership filter for multi-instance runs (`instance.ignore`).

  A ticket is *foreign* when another daemon owns it: its number is listed in
  `instance.ignore.tickets`, it carries a label in `instance.ignore.labels`, or
  it carries a `<prefix>:*` label for a prefix in `instance.ignore.label_prefixes`.
  Per-ticket observers and the Executor wake projection skip foreign tickets.
  Dispatch is scoped separately by `tracker.github.label_prefix` and never
  consults this module. Rules are read from the live config on every call, so
  they hot-reload.
  """

  require Logger

  alias Aiur.Config.Schema.Instance.Ignore

  @counter_key {__MODULE__, :ignored}

  @doc """
  True when `ticket` is owned by another instance. `labels` may be omitted when
  the caller does not have them; label rules then fall back to the open-ticket
  snapshot.
  """
  @spec foreign?(term(), [String.t() | map()] | nil) :: boolean()
  def foreign?(ticket, labels \\ nil), do: foreign?(ticket, labels, rules())

  @doc false
  @spec foreign?(term(), [String.t() | map()] | nil, Ignore.t()) :: boolean()
  def foreign?(ticket, labels, %Ignore{} = rules) do
    number = number(ticket)

    cond do
      empty?(rules) -> false
      number != nil and number in rules.tickets -> true
      rules.labels == [] and rules.label_prefixes == [] -> false
      true -> labels |> labels_for(number) |> Enum.any?(&label_matches?(&1, rules))
    end
  end

  @doc "True when any issue a PR closes is foreign (`closing` is a list of issue numbers or refs)."
  @spec foreign_pr?([term()] | nil) :: boolean()
  def foreign_pr?(closing) when is_list(closing) do
    rules = rules()
    not empty?(rules) and Enum.any?(closing, &foreign?(&1, nil, rules))
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
    Logger.info("instance.ignored consumer=#{consumer} ticket=#{inspect(number(ticket) || ticket)}")
    true
  end

  @doc "Foreign check that records the skip when it applies."
  @spec skip?(term(), [String.t() | map()] | nil, atom() | String.t()) :: boolean()
  def skip?(ticket, labels, consumer), do: foreign?(ticket, labels) and ignored(ticket, consumer)

  @doc "Ignored-event count since boot."
  @spec ignored_count() :: non_neg_integer()
  def ignored_count, do: :counters.get(counter(), 1)

  @doc "The active ignore rules (empty lists when the config is unreadable)."
  @spec rules() :: Ignore.t()
  def rules do
    case Aiur.Config.settings() do
      {:ok, %{instance: %{ignore: %Ignore{} = ignore}}} -> ignore
      _ -> %Ignore{}
    end
  rescue
    _ -> %Ignore{}
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
    rules = Enum.map_join([:tickets, :labels, :label_prefixes], " ", &"#{&1}=[#{Enum.join(status[&1], ",")}]")
    "INSTANCE IGNORE #{rules} ignored_since_boot=#{status.ignored_since_boot}"
  end

  defp empty?(%Ignore{tickets: [], labels: [], label_prefixes: []}), do: true
  defp empty?(_rules), do: false

  defp label_matches?(label, rules) do
    label = label |> label_name() |> String.downcase()

    Enum.any?(rules.labels, &(String.downcase(&1) == label)) or
      Enum.any?(rules.label_prefixes, &String.starts_with?(label, String.downcase(String.trim_trailing(&1, ":")) <> ":"))
  end

  defp label_name(%{"name" => name}), do: to_string(name)
  defp label_name(%{name: name}), do: to_string(name)
  defp label_name(label), do: to_string(label)

  defp labels_for(labels, _number) when is_list(labels), do: labels
  defp labels_for(_labels, nil), do: []

  # ponytail: labels come from the open-ticket snapshot (registered at boot, since config sits below github) when a
  # caller has only an id; a closed or unlisted ticket matches by id only.
  defp labels_for(_labels, number) do
    case Application.get_env(:aiur, :instance_ticket_labels_fun) do
      lookup when is_function(lookup, 1) -> lookup.(number)
      _ -> []
    end
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
