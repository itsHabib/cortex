defmodule CortexWeb.TokenComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias CortexWeb.TokenComponents

  describe "token_display/1" do
    test "renders token pair" do
      html = render_component(&TokenComponents.token_display/1, input: 1500, output: 45)
      assert html =~ "1.5K in"
      assert html =~ "45 out"
    end

    test "renders placeholder for nil values" do
      html = render_component(&TokenComponents.token_display/1, input: nil, output: nil)
      assert html =~ "--"
    end

    test "renders zero tokens" do
      html = render_component(&TokenComponents.token_display/1, input: 0, output: 0)
      assert html =~ "0 in"
      assert html =~ "0 out"
    end

    test "renders large values with K suffix" do
      html = render_component(&TokenComponents.token_display/1, input: 16_584, output: 2300)
      assert html =~ "16.6K in"
      assert html =~ "2.3K out"
    end
  end

  describe "token_detail/1" do
    test "renders clickable token detail" do
      html =
        render_component(&TokenComponents.token_detail/1,
          id: "test",
          input: 1000,
          output: 500,
          cache_read: 200,
          cache_creation: 100
        )

      assert html =~ "Click for token breakdown"
      assert html =~ "test-detail"
    end

    test "shows all breakdown fields" do
      html =
        render_component(&TokenComponents.token_detail/1,
          id: "t1",
          input: 500,
          output: 100,
          cache_read: 200,
          cache_creation: 50
        )

      assert html =~ "Input"
      assert html =~ "Cache Read"
      assert html =~ "Cache Create"
      assert html =~ "Output"
    end

    test "handles nil cache values" do
      html =
        render_component(&TokenComponents.token_detail/1,
          id: "t2",
          input: 500,
          output: 100,
          cache_read: nil,
          cache_creation: nil
        )

      assert html =~ "500 in"
    end

    test "includes aria attributes" do
      html =
        render_component(&TokenComponents.token_detail/1,
          id: "t3",
          input: 100,
          output: 50
        )

      assert html =~ "aria-expanded"
      assert html =~ "aria-controls"
    end
  end

  describe "cost_display/1" do
    test "renders cost in USD" do
      html = render_component(&TokenComponents.cost_display/1, usd: 0.05)
      assert html =~ "$0.0500"
    end

    test "renders placeholder for nil" do
      html = render_component(&TokenComponents.cost_display/1, usd: nil)
      assert html =~ "--"
    end

    test "renders small costs" do
      html = render_component(&TokenComponents.cost_display/1, usd: 0.0001)
      assert html =~ "$0.0001"
    end
  end

  describe "duration_display/1" do
    test "renders milliseconds" do
      html = render_component(&TokenComponents.duration_display/1, ms: 500)
      assert html =~ "500ms"
    end

    test "renders seconds" do
      html = render_component(&TokenComponents.duration_display/1, ms: 5_500)
      assert html =~ "5.5s"
    end

    test "renders minutes and seconds" do
      html = render_component(&TokenComponents.duration_display/1, ms: 125_000)
      assert html =~ "2m 5s"
    end

    test "renders hours and minutes" do
      html = render_component(&TokenComponents.duration_display/1, ms: 7_260_000)
      assert html =~ "2h 1m"
    end

    test "renders placeholder for nil" do
      html = render_component(&TokenComponents.duration_display/1, ms: nil)
      assert html =~ "--"
    end
  end

  describe "format_token_count/1" do
    test "formats zero" do
      assert TokenComponents.format_token_count(0) == "0"
    end

    test "formats small numbers" do
      assert TokenComponents.format_token_count(500) == "500"
      assert TokenComponents.format_token_count(999) == "999"
    end

    test "formats thousands with K suffix" do
      assert TokenComponents.format_token_count(1_000) == "1K"
      assert TokenComponents.format_token_count(1_500) == "1.5K"
      assert TokenComponents.format_token_count(16_584) == "16.6K"
    end

    test "formats millions with M suffix" do
      assert TokenComponents.format_token_count(1_000_000) == "1M"
      assert TokenComponents.format_token_count(2_500_000) == "2.5M"
    end

    test "formats nil as zero" do
      assert TokenComponents.format_token_count(nil) == "0"
    end
  end

  describe "format_number/1" do
    test "formats small numbers as-is" do
      assert TokenComponents.format_number(42) == "42"
      assert TokenComponents.format_number(999) == "999"
    end

    test "formats thousands with K" do
      assert TokenComponents.format_number(1_500) == "1.5K"
    end

    test "formats millions with M" do
      assert TokenComponents.format_number(2_500_000) == "2.5M"
    end
  end
end
