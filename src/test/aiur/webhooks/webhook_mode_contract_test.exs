defmodule Aiur.WebhookModeContractTest do
  @moduledoc """
  Keeps the consumer contract from decaying.

  Two things have to stay true for the shared suite to mean anything. The two
  generated runs must really be in different modes — otherwise the whole suite
  is `f(x) == f(x)`. And it must stay *impossible* to add a consumer test that
  covers only one mode, because the failure this epic actually risks is a slow
  one: webhook mode becomes the tested path, polling rots unnoticed, and the
  first repo without a webhook hits a bug no CI run could have seen.
  """

  use ExUnit.Case, async: true

  alias Aiur.WebhookModeContract
  alias Aiur.Webhooks
  alias Aiur.Webhooks.EventSource

  @consumer_dir Path.expand("../../../test/aiur/webhooks", __DIR__)
  @consumer_glob "consumer_*_test.exs"

  describe "the harness puts the two runs in genuinely different modes" do
    test "the polling context has no webhook and never gains one" do
      ctx = WebhookModeContract.start_mode!(:polling)
      assert ctx.source == EventSource.Polling

      {:ok, _event} = WebhookModeContract.deliver(ctx, "ticket.1.pr.opened", %{})

      assert Webhooks.transport(ctx.repo, server: ctx.server) == :polling
      assert Webhooks.polling_reason(ctx.repo, server: ctx.server) == :never_configured
    end

    test "the webhook context starts unproven and is proven by its delivery" do
      ctx = WebhookModeContract.start_mode!(:webhook)
      assert ctx.source == EventSource.Webhook
      assert Webhooks.transport(ctx.repo, server: ctx.server) == :polling

      {:ok, _event} = WebhookModeContract.deliver(ctx, "ticket.1.pr.opened", %{})

      assert Webhooks.transport(ctx.repo, server: ctx.server) == :webhook
    end

    test "the two contexts are isolated from each other" do
      polling = WebhookModeContract.start_mode!(:polling)
      webhook = WebhookModeContract.start_mode!(:webhook)

      {:ok, _event} = WebhookModeContract.deliver(webhook, "ticket.1.pr.opened", %{})

      assert Webhooks.transport(webhook.repo, server: webhook.server) == :webhook
      assert Webhooks.transport(webhook.repo, server: polling.server) == :polling
      refute webhook.repo == polling.repo
    end
  end

  describe "every consumer test really runs against both modes" do
    test "there is at least one consumer test file" do
      assert consumer_files() != [], "the consumer contract has no suite left to enforce"
    end

    test "each consumer file goes through the shared harness" do
      for path <- consumer_files() do
        source = File.read!(path)

        assert source =~ "use Aiur.WebhookModeContract",
               "#{Path.basename(path)} must use Aiur.WebhookModeContract so its tests run against both modes"
      end
    end

    test "no consumer file declares a single-mode test with a bare test/2" do
      for path <- consumer_files() do
        offenders =
          path
          |> File.read!()
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _index} -> Regex.match?(~r/^\s*test\s+"/, line) end)

        assert offenders == [],
               "#{Path.basename(path)} declares mode-blind tests with bare `test \"...\"` at lines " <>
                 "#{inspect(Enum.map(offenders, fn {_line, index} -> index end))}; use `mode_test` so both modes are covered"
      end
    end

    test "no consumer test branches on the mode it is running in" do
      for path <- consumer_files() do
        source = File.read!(path)

        refute source =~ ~r/\.mode\b/,
               "#{Path.basename(path)} inspects the delivery mode; consumers must be unable to tell which transport they are on"
      end
    end

    test "every consumer file is named so the test runner collects it" do
      for path <- consumer_files() do
        assert String.ends_with?(path, "_test.exs"), "#{path} would never be collected by the runner"
      end
    end

    test "one mode_test compiles to exactly one real test per mode" do
      names =
        __MODULE__.Sample.__info__(:functions)
        |> Enum.map(fn {name, _arity} -> Atom.to_string(name) end)
        |> Enum.filter(&String.starts_with?(&1, "test "))
        |> Enum.sort()

      assert names == ["test one body [polling mode]", "test one body [webhook mode]"]
    end
  end

  # Proves the macro itself, so the guarantee does not depend on which files a
  # scoped `mix test` invocation happened to load alongside this one.
  defmodule Sample do
    use ExUnit.Case, async: true
    use Aiur.WebhookModeContract

    mode_test "one body", ctx do
      {:ok, event} = deliver(ctx, "ticket.1.pr.opened", %{})
      assert event.topic == "ticket.1.pr.opened"
    end
  end

  defp consumer_files, do: @consumer_dir |> Path.join(@consumer_glob) |> Path.wildcard()
end
