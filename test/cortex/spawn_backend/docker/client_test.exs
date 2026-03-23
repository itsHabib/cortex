defmodule Cortex.SpawnBackend.Docker.ClientTest do
  use ExUnit.Case, async: true

  alias Cortex.SpawnBackend.Docker.Client

  describe "strip_docker_stream_headers/1" do
    test "strips stdout frame headers" do
      # stdout type=1, payload "hello\n" (6 bytes)
      payload = "hello\n"
      frame = <<1, 0, 0, 0, 0::size(24), byte_size(payload), payload::binary>>

      assert [^payload] = Client.strip_docker_stream_headers(frame)
    end

    test "strips multiple frames" do
      payload1 = "first\n"
      payload2 = "second\n"

      frame1 = <<1, 0, 0, 0, 0::size(24), byte_size(payload1), payload1::binary>>
      frame2 = <<2, 0, 0, 0, 0::size(24), byte_size(payload2), payload2::binary>>

      result = Client.strip_docker_stream_headers(frame1 <> frame2)
      assert result == [payload1, payload2]
    end

    test "returns empty list for empty data" do
      assert [] = Client.strip_docker_stream_headers(<<>>)
    end

    test "returns raw data when not in multiplexed format" do
      raw = "plain text data"
      assert [^raw] = Client.strip_docker_stream_headers(raw)
    end

    test "handles large payloads" do
      payload = String.duplicate("x", 1000)

      frame =
        <<1, 0, 0, 0, byte_size(payload)::unsigned-big-integer-size(32), payload::binary>>

      assert [^payload] = Client.strip_docker_stream_headers(frame)
    end
  end
end
