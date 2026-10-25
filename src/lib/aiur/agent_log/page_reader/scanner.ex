defmodule Aiur.AgentLog.PageReader.Scanner do
  @moduledoc false
  @chunk 65_536
  @line_cap 4 * 1_048_576

  @spec new(term(), atom(), non_neg_integer(), non_neg_integer(), function()) :: map()
  def new(fd, direction, position, finish, pread) do
    %{fd: fd, direction: direction, pos: position, finish: finish, pread: pread, buffer: "", dropped?: false, bytes: 0, start: position}
  end

  @spec next(map()) :: {:ok, binary() | :oversized, non_neg_integer(), map()} | {:eof, map()} | {:error, term()}
  def next(%{direction: :backward} = scan), do: backward(scan)
  def next(scan), do: forward(scan)

  @spec remaining?(map()) :: boolean()
  def remaining?(%{direction: :backward} = scan), do: scan.pos > 0 or scan.buffer != ""
  def remaining?(scan), do: scan.pos - byte_size(scan.buffer) < scan.finish

  defp backward(scan) do
    case :binary.matches(scan.buffer, "\n") |> List.last() do
      {index, 1} ->
        offset = scan.pos + index + 1
        line = binary_part(scan.buffer, index + 1, byte_size(scan.buffer) - index - 1)
        rest = binary_part(scan.buffer, 0, index)
        {:ok, content(scan, line), offset, %{scan | buffer: rest, dropped?: false, start: offset}}

      nil ->
        backward_boundary(scan)
    end
  end

  defp backward_boundary(%{pos: 0, buffer: "", dropped?: false} = scan), do: {:eof, scan}

  defp backward_boundary(%{pos: 0} = scan) do
    {:ok, content(scan, scan.buffer), 0, %{scan | buffer: "", dropped?: false, start: 0}}
  end

  defp backward_boundary(scan) do
    length = min(scan.pos, @chunk)
    position = scan.pos - length

    case scan.pread.(scan.fd, position, length) do
      {:ok, bytes} -> backward(hold(%{scan | pos: position, bytes: scan.bytes + byte_size(bytes)}, bytes, :backward))
      :eof -> {:error, :reset}
      error -> error
    end
  end

  defp forward(scan) do
    case :binary.match(scan.buffer, "\n") do
      {index, 1} ->
        offset = scan.start
        line = binary_part(scan.buffer, 0, index)
        rest = binary_part(scan.buffer, index + 1, byte_size(scan.buffer) - index - 1)
        {:ok, content(scan, line), offset, %{scan | buffer: rest, dropped?: false, start: scan.pos - byte_size(rest)}}

      :nomatch ->
        forward_boundary(scan)
    end
  end

  defp forward_boundary(%{pos: position, finish: finish} = scan) when position >= finish, do: {:eof, %{scan | buffer: ""}}

  defp forward_boundary(scan) do
    length = min(scan.finish - scan.pos, @chunk)

    case scan.pread.(scan.fd, scan.pos, length) do
      {:ok, bytes} -> forward(hold(%{scan | pos: scan.pos + byte_size(bytes), bytes: scan.bytes + byte_size(bytes)}, bytes, :forward))
      :eof -> {:error, :reset}
      error -> error
    end
  end

  defp hold(scan, bytes, direction) do
    buffer = if direction == :backward, do: bytes <> scan.buffer, else: scan.buffer <> bytes

    if byte_size(buffer) > @line_cap and :binary.match(buffer, "\n") == :nomatch do
      %{scan | buffer: "", dropped?: true}
    else
      %{scan | buffer: buffer}
    end
  end

  defp content(%{dropped?: true}, _line), do: :oversized
  defp content(_scan, line) when byte_size(line) > @line_cap, do: :oversized
  defp content(_scan, line), do: line
end
