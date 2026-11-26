defmodule Aiur.TestHTTPGuard do
  @moduledoc false

  @spec run(Req.Request.t()) :: {Req.Request.t(), Req.Response.t() | Exception.t()}
  def run(request) do
    if request.url.host in ["localhost", "127.0.0.1", "::1"] do
      Req.Finch.run(request)
    else
      {request,
       %RuntimeError{
         message: "test HTTP request blocked for #{request.url.host}; inject a fake :plug/:adapter or explicitly opt in with adapter: Req.Finch"
       }}
    end
  end
end
