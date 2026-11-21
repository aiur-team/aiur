defmodule LocalHost.Router do
  @moduledoc "Same-origin conversation pages, client assets and authenticated voice socket on loopback."
  @behaviour Plug
  import Plug.Conn
  @impl true
  def init(opts), do: opts
  @impl true
  def call(conn, _opts) do
    if conn.host == "127.0.0.1" and conn.port == Application.fetch_env!(:local_host, :port) do
      route(conn)
    else
      send_resp(conn, 403, "Invalid host")
    end
  end

  defp route(%{method: "GET", request_path: "/"} = conn) do
    {:ok, token, _expires} =
      VoiceConverse.TokenIssuer.Hmac.issue("converse", instance: LocalHost.Voice)

    page = :local_host |> :code.priv_dir() |> Path.join("index.html") |> File.read!()

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_content_type("text/html")
    |> send_resp(200, String.replace(page, "__TOKEN__", token))
  end

  defp route(%{method: "GET", request_path: "/client.js"} = conn) do
    path = Path.join(:code.priv_dir(:voice_converse), "static/voice_converse_client.js")
    conn |> put_resp_content_type("text/javascript") |> send_file(200, path)
  end

  defp route(%{method: "GET", request_path: "/talk"} = conn), do: talk_page(conn)
  defp route(%{method: "GET", request_path: "/talk.html"} = conn), do: talk_page(conn)

  defp route(%{method: "GET", request_path: "/talk.css"} = conn) do
    path = Path.join(:code.priv_dir(:voice_converse), "static/talk.css")
    conn |> put_resp_content_type("text/css") |> send_file(200, path)
  end

  defp route(%{method: "GET", request_path: "/voice_converse_client.js"} = conn) do
    path = Path.join(:code.priv_dir(:voice_converse), "static/voice_converse_client.js")
    conn |> put_resp_content_type("text/javascript") |> send_file(200, path)
  end

  defp route(%{method: "GET", request_path: "/voice"} = conn) do
    opts = [instance: LocalHost.Voice, token_issuer: VoiceConverse.TokenIssuer.Hmac]
    VoiceConverse.Transport.WebSock.Plug.call(conn, opts)
  end

  defp route(conn), do: send_resp(conn, 404, "Not found")

  defp talk_page(conn) do
    {:ok, token, _expires} =
      VoiceConverse.TokenIssuer.Hmac.issue("converse", instance: LocalHost.Voice)

    path = Path.join(:code.priv_dir(:voice_converse), "static/talk.html")

    page =
      File.read!(path)
      |> String.replace("__TOKEN__", token)
      |> String.replace("__TARGET__", "local")

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_content_type("text/html")
    |> send_resp(200, page)
  end
end
