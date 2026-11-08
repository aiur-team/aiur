defmodule Aiur.HttpServerPublicUrlTest do
  # Regression for #7753: an https server.public_url crashed endpoint warmup.
  use Aiur.TestSupport

  import ExUnit.CaptureLog

  alias Aiur.Config.Schema
  alias Aiur.HttpServer
  alias AiurWeb.DashboardAuthController

  setup do
    previous_override = Process.get(:workflow_file_path_override)
    previous_endpoint = Application.get_env(:aiur, AiurWeb.Endpoint)
    previous_pages = Application.get_env(:aiur, :dashboard_pages)
    config_dir = Aiur.TestSupport.tmp_root!("http-server-public-url")
    File.mkdir_p!(config_dir)

    on_exit(fn ->
      if previous_override, do: Process.put(:workflow_file_path_override, previous_override), else: Process.delete(:workflow_file_path_override)
      if previous_endpoint, do: Application.put_env(:aiur, AiurWeb.Endpoint, previous_endpoint), else: Application.delete_env(:aiur, AiurWeb.Endpoint)
      if previous_pages == nil, do: Application.delete_env(:aiur, :dashboard_pages), else: Application.put_env(:aiur, :dashboard_pages, previous_pages)
      Aiur.TestCleanup.rm_rf!(config_dir)
    end)

    %{config_dir: config_dir}
  end

  for {public_url, origin} <- [
        {"https://example.ts.net:4001", "https://example.ts.net:4001"},
        {"http://example.ts.net:4001", "http://example.ts.net:4001"},
        {"https://example.com", "https://example.com"},
        {"https://example.ts.net:4001/", "https://example.ts.net:4001"}
      ] do
    test "endpoint starts and Google callback is derived for #{public_url}", %{config_dir: dir} do
      use_public_url(dir, unquote(public_url))

      capture_log(fn ->
        assert {:ok, pid} = HttpServer.start_link(host: "127.0.0.1", port: 0, dashboard_writable: false)

        try do
          assert AiurWeb.Endpoint.url() == unquote(origin)
        after
          Supervisor.stop(pid)
        end
      end)

      assert DashboardAuthController.google_redirect_uri() == unquote(origin) <> "/auth/google/callback"
    end
  end

  test "config load rejects an unusable public_url with a clear error" do
    for bad <- ["example.ts.net:4001", "ftp://example.com", "https://", "not a url"] do
      assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"server" => %{"public_url" => bad}})
      assert message =~ "public_url"
      assert message =~ "http:// or https:// URL"
    end
  end

  defp use_public_url(dir, url) do
    path = Path.join(dir, "config")
    :ok = Aiur.TestSupport.write_workflow_file!(path)
    original = File.read!(path)

    config =
      if String.contains?(original, "\nserver:\n"),
        do: String.replace(original, "\nserver:\n", "\nserver:\n  public_url: #{url}\n", global: false),
        else: original <> "\nserver:\n  public_url: #{url}\n"

    File.write!(path, config)
    Process.put(:workflow_file_path_override, path)
  end
end
