defmodule Aiur.GlobalConfigStartupTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  alias Aiur.GlobalConfigStartup

  setup do
    home = Path.join(System.tmp_dir!(), "global-startup-#{System.unique_integer([:positive])}")
    path = Path.join(home, ".aiur/config")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "tracker:\n  kind: github\n  base_branch: main\n  github:\n    label_prefix: agent\n")
    on_exit(fn -> File.rm_rf!(home) end)
    parent = self()

    request = fn req ->
      send(parent, {:request, req.method, req.url, req[:body]})

      case req.method do
        :get -> {:ok, %{status: 200, body: []}}
        :post -> {:ok, %{status: 201, body: %{}}}
      end
    end

    {:ok, path: path, home: home, opts: [home: home, origin_fun: fn -> "team/consumer" end, token_fun: fn -> "temporary-test-token" end, request_fun: request]}
  end

  test "global fallback announces target and creates workflow labels without model labels", c do
    output = capture_io(:stderr, fn -> assert :ok = GlobalConfigStartup.prepare(c.path, c.opts) end)
    assert output =~ "Using global config"
    assert output =~ "team/consumer"
    assert_received {:request, :get, "https://api.github.com/repos/team/consumer/labels?per_page=100&page=1", nil}
    requests = collect_posts([])
    names = Enum.map(requests, & &1["name"])
    assert "agent:todo" in names
    assert "agent:paused" in names
    assert "agent:error" in names
    assert "complexity:5" in names
    refute Enum.any?(names, &String.starts_with?(&1, "model:"))
    refute File.exists?(Path.join(c.home, "consumer/.aiur/config"))
  end

  test "existing labels require no writes", c do
    labels =
      Aiur.GitHub.Labels.state_labels("agent") ++
        Aiur.GitHub.Labels.marker_labels("agent") ++ Aiur.GitHub.Labels.complexity_labels()

    parent = self()

    request = fn req ->
      assert req.method == :get
      send(parent, :labels_read)
      {:ok, %{status: 200, body: Enum.map(labels, &%{"name" => &1})}}
    end

    capture_io(:stderr, fn -> assert :ok = GlobalConfigStartup.prepare(c.path, Keyword.put(c.opts, :request_fun, request)) end)
    assert_received :labels_read
  end

  test "missing credential prevents bootstrap with actionable error", c do
    opts = Keyword.put(c.opts, :token_fun, fn -> nil end)

    capture_io(:stderr, fn ->
      assert {:error, message} = GlobalConfigStartup.prepare(c.path, opts)
      assert message =~ "~/.aiur/.env"
    end)

    refute_received {:request, _, _, _}
  end

  test "different explicit global repo fails before any label request", c do
    File.write!(c.path, "tracker:\n  kind: github\n  github:\n    repo: other/repo\n")

    capture_io(:stderr, fn ->
      assert {:error, message} = GlobalConfigStartup.prepare(c.path, c.opts)
      assert message =~ "other/repo"
      assert message =~ "team/consumer"
    end)

    refute_received {:request, _, _, _}
  end

  test "label creation denial returns failure before startup", c do
    request = fn req ->
      case req.method do
        :get -> {:ok, %{status: 200, body: []}}
        :post -> {:ok, %{status: 403, body: %{}}}
      end
    end

    capture_io(:stderr, fn ->
      assert {:error, message} = GlobalConfigStartup.prepare(c.path, Keyword.put(c.opts, :request_fun, request))
      assert message =~ "403"
      assert message =~ "Issues"
    end)
  end

  test "missing origin fails before any label request", c do
    capture_io(:stderr, fn ->
      assert {:error, message} = GlobalConfigStartup.prepare(c.path, Keyword.put(c.opts, :origin_fun, fn -> nil end))
      assert message =~ "origin"
    end)

    refute_received {:request, _, _, _}
  end

  test "blank and padded label prefixes match dispatcher normalization", c do
    for {configured, expected} <- [{" ", "agent:todo"}, {" custom ", "custom:todo"}] do
      File.write!(c.path, "tracker:\n  kind: github\n  github:\n    label_prefix: '#{configured}'\n")
      capture_io(:stderr, fn -> assert :ok = GlobalConfigStartup.prepare(c.path, c.opts) end)
      names = Enum.map(collect_posts([]), & &1["name"])
      assert expected in names
    end
  end

  test "non-GitHub and local origin URLs fail before any label requests", c do
    for remote <- ["https://gitlab.com/team/consumer.git", "/tmp/team/consumer.git"] do
      opts = c.opts |> Keyword.delete(:origin_fun) |> Keyword.put(:origin_url_fun, fn -> remote end)

      capture_io(:stderr, fn ->
        assert {:error, message} = GlobalConfigStartup.prepare(c.path, opts)
        assert message =~ "origin"
      end)

      refute_received {:request, _, _, _}
    end
  end

  test "HTTPS and SSH GitHub origins bootstrap the exact repo", c do
    for remote <- ["https://github.com/team/consumer.git", "git@github.com:team/consumer.git", "ssh://git@github.com/team/consumer.git"] do
      opts = c.opts |> Keyword.delete(:origin_fun) |> Keyword.put(:origin_url_fun, fn -> remote end)
      capture_io(:stderr, fn -> assert :ok = GlobalConfigStartup.prepare(c.path, opts) end)
      assert_received {:request, :get, "https://api.github.com/repos/team/consumer/labels?per_page=100&page=1", nil}
      assert "agent:todo" in Enum.map(collect_posts([]), & &1["name"])
    end
  end

  # Future guards for preexisting local-config and non-GitHub behavior.
  test "future guard: repository-local config does not bootstrap", c do
    assert :ok = GlobalConfigStartup.prepare(Path.join(c.home, "repo/.aiur/config"), c.opts)
    refute_received {:request, _, _, _}
  end

  test "future guard: global non-GitHub config does not bootstrap", c do
    File.write!(c.path, "tracker:\n  kind: memory\n")
    capture_io(:stderr, fn -> assert :ok = GlobalConfigStartup.prepare(c.path, c.opts) end)
    refute_received {:request, _, _, _}
  end

  defp collect_posts(acc) do
    receive do
      {:request, :post, "https://api.github.com/repos/team/consumer/labels", body} -> collect_posts([body | acc])
    after
      0 -> acc
    end
  end
end
