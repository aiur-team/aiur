defmodule AiurWeb.Build.Usage do
  @moduledoc "Protected, per-connection quota facts for the build home usage strip."
  alias Aiur.{Accounts, CodingAgent, ModelAvailability}
  alias Aiur.Accounts.UsageReadings
  alias Aiur.ElevenLabs.Quota, as: ElevenLabsQuota
  alias Aiur.GitHub.Quota, as: GitHubQuota
  alias AiurWeb.Build.{Read, UsageAPIs, UsageFacts}
  alias AiurWeb.OperatorControlCenter.{ModelProviders, Money, ProviderMeterSource, ProviderMetersPresenter}
  alias AiurWeb.ProviderMeterWindows

  @order [:claude, :codex, :kimi, :deepseek]
  @logos [:claude, :codex, :kimi, :deepseek]

  @spec read({:ok, term()} | :locked, keyword()) :: map()
  def read(financial, opts \\ [])
  def read(:locked, _opts), do: block(:locked, nil, nil)

  def read({:ok, context} = financial, opts) do
    block(financial, load(context, opts), Keyword.get(opts, :now, DateTime.utc_now()))
  rescue
    _ -> block(financial, :error, nil)
  catch
    _, _ -> block(financial, :error, nil)
  end

  @spec subscribe({:ok, term()} | :locked) :: term()
  def subscribe(:locked), do: :ok
  def subscribe({:ok, context}), do: ProviderMeterSource.subscribe(context)

  @spec load(term(), keyword()) :: map()
  def load(context, opts \\ []) do
    families = Enum.filter(CodingAgent.provider_families(), &keyed?/1)
    source = Keyword.get(opts, :meter_source, ProviderMeterSource)
    meters = isolated(fn -> meter_read(source, context, opts) end, %{})
    accounts = isolated(Keyword.get(opts, :accounts_fun, &account_readings/0), %{})
    durable = isolated(fn -> Map.new(families, &{&1, durable(&1, Keyword.get(opts, :durable_path, ModelAvailability.path()))}) end, %{})
    github = isolated(fn -> {:ok, GitHubQuota.snapshot!(Keyword.get(opts, :github_server, GitHubQuota))} end, {:error, :unavailable})
    elevenlabs = isolated(fn -> ElevenLabsQuota.snapshot(Keyword.get(opts, :elevenlabs_server, ElevenLabsQuota)) end, %{state: :unconfigured})
    %{families: families, meters: meters, accounts: accounts, durable: durable, github: github, elevenlabs: elevenlabs}
  end

  defp meter_read(source, context, opts) do
    case opts[:reload] do
      nil -> source.load(context, opts)
      message -> source.reload(context, message, opts)
    end
  end

  defp account_readings do
    names =
      case Accounts.configured_names() do
        [] -> ["default"]
        names -> names
      end

    UsageReadings.snapshot("claude", names)
  end

  defp isolated(fun, fallback) do
    fun.()
  rescue
    _ -> fallback
  catch
    _, _ -> fallback
  end

  @doc false
  @spec keyed?(atom()) :: boolean()
  def keyed?(provider) do
    case get_in(CodingAgent.backends(), [Atom.to_string(provider), :openai_compat]) do
      %{} = compat -> ModelProviders.keyed?(compat)
      _ -> true
    end
  end

  @doc false
  @spec durable(atom(), Path.t()) :: map() | nil
  defdelegate durable(provider, path \\ ModelAvailability.path()), to: UsageFacts
  @doc false
  @spec elevenlabs_failure(term()) :: String.t()
  defdelegate elevenlabs_failure(failure), to: UsageFacts
  @doc false
  @spec compact_number(integer()) :: String.t()
  defdelegate compact_number(number), to: UsageFacts

  @doc false
  @spec order_families([atom()]) :: [atom()]
  def order_families(families), do: Enum.filter(@order, &(&1 in families)) ++ (families -- @order)

  @spec block({:ok, term()} | :locked, map() | :error | nil, DateTime.t() | nil) :: map()
  def block(:locked, _inputs, _now), do: Read.locked_usage()
  def block({:ok, _}, :error, _now), do: %{state: "unavailable", observed_at: nil, reason: "usage_source_failed"}

  def block({:ok, _}, inputs, now) do
    cards = ProviderMetersPresenter.present(%{state: :authorized}, inputs.meters, %{}).cards
    providers = for family <- order_families(inputs.families), card = Enum.find(cards, &(&1.provider == family)), card != nil, do: provider(card, inputs, ms(now))
    apis = UsageAPIs.rows(inputs.github, inputs.elevenlabs, ms(now))
    %{state: "authorized", observed_at: latest(Enum.map(providers ++ apis, & &1.observed_at)), apis: apis, providers: providers}
  end

  @doc false
  @spec row(String.t()) :: map()
  def row(name),
    do: %{name: name, logo: nil, mono: nil, hue: nil, tag: nil, accounts: nil, session: nil, weekly: nil, credits: nil, none: false, lines: nil, icon: nil, stale: false, observed_at: nil, note: nil}

  defp provider(card, inputs, now) do
    logo = if card.provider in @logos, do: Atom.to_string(card.provider)

    base =
      Map.merge(row(card.provider_label), %{
        logo: logo,
        mono: if(logo == nil, do: card.provider_label |> String.first() |> String.upcase()),
        observed_at: ms(card.observed_at),
        stale: card.state == :stale
      })

    case card.state do
      state when state in [:healthy, :partial, :stale] -> provider_windows(base, card, inputs.accounts, now)
      :unknown -> unknown(base, Map.get(inputs.durable, card.provider))
      :loading -> %{base | none: true, note: "Awaiting first observation"}
      :signed_out -> %{base | none: true, note: "Not signed in"}
      _ -> %{base | none: true, note: card.health.failure_label || "Unavailable"}
    end
  end

  defp unknown(base, %{percent: percent, observed_at: at}), do: %{base | none: true, note: "Last known #{percent}% (previous boot)", observed_at: ms(at), stale: true}
  defp unknown(base, _), do: %{base | none: true, note: "Awaiting first observation"}

  defp provider_windows(base, %{provider: :claude}, accounts, now) when map_size(accounts) >= 2 do
    names = Enum.sort(Map.keys(accounts))
    session = account_window(accounts, names, "five_hour", "5h")
    weekly = account_window(accounts, names, "seven_day", "7d")

    %{
      base
      | accounts: names,
        session: session,
        weekly: weekly,
        observed_at: latest(Enum.map(Map.values(accounts), &ms(&1.observed_at))),
        stale: base.stale or ended?(session, now) or ended?(weekly, now)
    }
  end

  defp provider_windows(base, card, _accounts, now) do
    rates = card.windows |> Enum.filter(&(&1.kind == :rate_limit and &1.limit_id != "local-concurrency")) |> Map.new(&{&1.limit_id, &1})
    slots = rates |> ProviderMeterWindows.semantic(card.provider) |> Map.new(fn {slot, {id, value}} -> {slot, window(id, value)} end)
    credit = Enum.find(card.windows, &(&1.kind == :credit and card.provider != :codex))

    cond do
      map_size(slots) > 0 ->
        session = slots["session"]
        weekly = slots["weekly"]
        %{base | session: session, weekly: weekly, stale: base.stale or ended?(session, now) or ended?(weekly, now)}

      credit != nil ->
        %{base | credits: credits(credit)}

      true ->
        %{base | none: true, note: "Limits not reported by provider"}
    end
  end

  defp window(id, value), do: %{acc: [pct(value.meter)], reset_at: ms(value.resets_at), win: duration(value.duration_minutes, id)}
  defp pct(%{kind: :exact, now: value}), do: value
  defp pct(_), do: nil

  defp credits(value) do
    amount = get_in(value, [:credits, :amount])
    left = if is_number(amount), do: "$" <> Money.format_amount(to_string(amount)), else: "unknown"
    %{pct: pct(value.meter), left: left, tip: [["Prepaid credits", left <> " left"]]}
  end

  defp account_window(accounts, names, key, label) do
    values = Enum.map(names, fn name -> Enum.find(get_in(accounts[name], [:reading, :windows]) || [], &(&1.window == key)) || %{} end)
    %{acc: Enum.map(values, &percent(Map.get(&1, :used_percent))), reset_at: earliest(Enum.map(values, &ms(Map.get(&1, :resets_at)))), win: label}
  end

  defp duration(minutes, _id) when is_integer(minutes) and minutes > 0 do
    cond do
      rem(minutes, 1440) == 0 -> "#{div(minutes, 1440)}d"
      rem(minutes, 60) == 0 -> "#{div(minutes, 60)}h"
      true -> "#{minutes}m"
    end
  end

  defp duration(_minutes, id) do
    cond do
      String.contains?(id, "five_hour") -> "5h"
      String.contains?(id, "seven_day") -> "7d"
      true -> nil
    end
  end

  @doc false
  @spec ms(term()) :: integer() | nil
  def ms(%DateTime{} = at), do: DateTime.to_unix(at, :millisecond)

  def ms(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _} -> ms(dt)
      _ -> nil
    end
  end

  def ms(_), do: nil
  @doc false
  @spec percent(term()) :: integer() | nil
  def percent(value) when is_number(value), do: value |> round() |> max(0) |> min(100)
  def percent(_), do: nil
  defp ended?(%{reset_at: at}, now) when is_integer(at), do: at < now
  defp ended?(_, _), do: false
  defp earliest(values), do: values |> Enum.reject(&is_nil/1) |> Enum.min(fn -> nil end)
  defp latest(values), do: values |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end)
end
