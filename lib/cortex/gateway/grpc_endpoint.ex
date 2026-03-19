defmodule Cortex.Gateway.GrpcEndpoint do
  @moduledoc """
  GRPC endpoint for the Cortex agent gateway.

  Registers `Cortex.Gateway.GrpcServer` as the handler for the
  `AgentGateway.Connect` bidirectional stream RPC. Started as a child
  of `Gateway.Supervisor` on a configurable port (default 4001).

  ## Configuration

      config :cortex, Cortex.Gateway.GrpcEndpoint,
        port: 4001,
        start_server: true

  Set `start_server: false` to disable the gRPC server (e.g., in test).
  """

  use GRPC.Endpoint

  intercept(GRPC.Server.Interceptors.Logger, level: :debug)
  run(Cortex.Gateway.GrpcServer)
end
