defmodule Aiur.ConfigurationReferenceTest do
  use ExUnit.Case, async: true

  alias Aiur.Config.Schema

  @repo_root Path.expand("../../..", __DIR__)
  @doc_path Path.join(@repo_root, "website/docs-app/reference/configuration.md")
  @configuration_reference File.read!(@doc_path)

  @schema_sections [
    {nil, Schema},
    {"tracker", Schema.Tracker},
    {"tracker.github", Schema.Github},
    {"tracker.linear", Schema.Linear},
    {"polling", Schema.Polling},
    {"webhooks", Schema.Webhooks},
    {"workspace", Schema.Workspace},
    {"worker", Schema.Worker},
    {"agent", Schema.Agent},
    {"agent.claude", Schema.Claude},
    {"agent.codex", Schema.Codex},
    {"hooks", Schema.Hooks},
    {"prewarm", Schema.Prewarm},
    {"pr_watch", Schema.PrWatch},
    {"events", Schema.Events},
    {"alerts", Schema.Alerts},
    {"observability", Schema.Observability},
    {"decisions", Schema.Decisions},
    {"server", Schema.Server},
    {"opencode", Schema.Opencode},
    {"build_order", Schema.BuildOrder}
  ]

  # These rows describe defaults resolved outside the schema struct, such as
  # provider-specific lifecycle states, environment fallbacks, and values
  # derived from host capacity. They remain documented, but cannot be compared
  # directly with `struct!(module)`.
  @contextual_defaults ~w(
    tracker.kind
    tracker.base_branch
    tracker.active_states
    tracker.terminal_states
    tracker.github.repo
    tracker.linear.api_key
    tracker.linear.assignee
    workspace.root
    agent.max_concurrent_agents
    agent.rate_limit_primary
    alerts.alerts_file
    server.host
    build_order.ticket_detail_freshness_ms
    build_order.graph_catalog_refresh_ms
    build_order.graph_catalog_labels_refresh_ms
  )

  # The three `build_order` rows above are here for the reason this list exists:
  # their default is `nil` in the struct precisely because it is resolved
  # elsewhere — `Aiur.BuildOrder.Cadence` derives it from
  # `polling.interval_seconds`. Comparing the documented value against
  # `struct!(module)` would only ever assert that the reference says "nil", which
  # is the one thing an operator does not need to read. The derivation itself is
  # checked against the reference in `Aiur.BuildOrder.CadenceTest`, so removing it
  # from here does not remove the machine check.

  @documented_defaults for {prefix, module} <- @schema_sections,
                           field <- module.__schema__(:fields) -- module.__schema__(:embeds),
                           key = Enum.reject([prefix, field], &is_nil/1) |> Enum.join("."),
                           key not in @contextual_defaults,
                           do: {key, module, field}

  describe "documented defaults" do
    for {key, module, field} <- @documented_defaults do
      test "the documented #{key} default is the schema's actual default" do
        documented = documented_default(unquote(key))
        actual = Map.fetch!(struct!(unquote(module)), unquote(field))

        assert documented == actual,
               "configuration reference documents #{unquote(key)} default #{inspect(documented)}, " <>
                 "schema default is #{inspect(actual)}"
      end
    end
  end

  # Moving a key into `@contextual_defaults` removes it from the comparison
  # above — and the comparison's own `flunk` branch went with it, so the row
  # could be deleted from the reference with nothing failing. That is how three
  # `build_order` rows became unchecked. The value cannot be compared with
  # `struct!/1` for these keys, but its presence can, and presence is what the
  # dropped `flunk` used to guarantee.
  describe "contextually defaulted keys" do
    for key <- @contextual_defaults do
      test "the reference still documents #{key}" do
        assert documented_row_count(unquote(key)) == 1,
               "configuration reference has #{documented_row_count(unquote(key))} rows for " <>
                 "#{unquote(key)}; a contextually defaulted key is still a documented key"
      end
    end
  end

  defp documented_row_count(key) do
    ~r/^\| `#{Regex.escape(key)}` \|/m
    |> Regex.scan(@configuration_reference)
    |> length()
  end

  defp documented_default(key) do
    regex = ~r/^\| `#{Regex.escape(key)}` \| [^|]+ \| (?<default>[^|]+) \|/m

    case Regex.scan(regex, @configuration_reference, capture: :all_names) do
      [[value]] -> parse_default(key, String.trim(value))
      [] -> flunk("configuration reference no longer states a default for #{key}")
      matches -> flunk("configuration reference states #{length(matches)} defaults for #{key}")
    end
  end

  defp parse_default(_key, "nil"), do: nil
  defp parse_default(_key, "none"), do: nil
  defp parse_default(_key, "true"), do: true
  defp parse_default(_key, "false"), do: false
  defp parse_default(_key, "`[]`"), do: []
  defp parse_default(_key, "`%{}`"), do: %{}

  defp parse_default(key, value) do
    cond do
      Regex.match?(~r/^-?\d+$/, value) ->
        String.to_integer(value)

      Regex.match?(~r/^-?\d+\.\d+$/, value) ->
        String.to_float(value)

      String.starts_with?(value, "`") and String.ends_with?(value, "`") ->
        value
        |> String.replace_prefix("`", "")
        |> String.replace_suffix("`", "")

      true ->
        flunk("configuration reference no longer states a literal default for #{key}: #{inspect(value)}")
    end
  end
end
