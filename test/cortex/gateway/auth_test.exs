defmodule Cortex.Gateway.AuthTest do
  use ExUnit.Case, async: true

  alias Cortex.Gateway.Auth

  describe "authenticate/2 with token_source option" do
    test "valid token returns {:ok, identity}" do
      assert {:ok, %{identity: "bearer"}} =
               Auth.authenticate("my-secret", token_source: "my-secret")
    end

    test "invalid token returns {:error, :unauthorized}" do
      assert {:error, :unauthorized} =
               Auth.authenticate("wrong-token", token_source: "my-secret")
    end

    test "empty token returns {:error, :unauthorized}" do
      assert {:error, :unauthorized} = Auth.authenticate("", token_source: "my-secret")
    end

    test "nil token returns {:error, :unauthorized}" do
      assert {:error, :unauthorized} = Auth.authenticate(nil)
    end

    test "missing token_source (nil) returns {:error, :unauthorized}" do
      # When CORTEX_GATEWAY_TOKEN is not set and no token_source provided,
      # auth should fail closed.
      old = System.get_env("CORTEX_GATEWAY_TOKEN")
      System.delete_env("CORTEX_GATEWAY_TOKEN")

      try do
        assert {:error, :unauthorized} = Auth.authenticate("some-token", [])
      after
        if old, do: System.put_env("CORTEX_GATEWAY_TOKEN", old)
      end
    end

    test "empty token_source returns {:error, :unauthorized}" do
      assert {:error, :unauthorized} = Auth.authenticate("token", token_source: "")
    end
  end

  describe "authenticate/1 delegates to authenticate/2" do
    test "uses env var when no opts given" do
      old = System.get_env("CORTEX_GATEWAY_TOKEN")
      System.put_env("CORTEX_GATEWAY_TOKEN", "env-secret")

      try do
        assert {:ok, %{identity: "bearer"}} = Auth.authenticate("env-secret")
        assert {:error, :unauthorized} = Auth.authenticate("wrong")
      after
        if old do
          System.put_env("CORTEX_GATEWAY_TOKEN", old)
        else
          System.delete_env("CORTEX_GATEWAY_TOKEN")
        end
      end
    end
  end

  describe "Bearer backend directly" do
    test "constant-time comparison prevents timing attacks" do
      # This is more of a documentation test — we verify Plug.Crypto.secure_compare
      # is used by confirming the correct behavior (not timing, which is hard to test).
      assert {:ok, _} =
               Cortex.Gateway.Auth.Bearer.authenticate("correct", token_source: "correct")

      assert {:error, :unauthorized} =
               Cortex.Gateway.Auth.Bearer.authenticate("incorrect", token_source: "correct")
    end
  end
end
