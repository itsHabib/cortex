defmodule CortexWeb.FeedComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias CortexWeb.FeedComponents

  @now ~U[2024-01-01 12:00:00Z]

  describe "activity_feed/1" do
    test "renders activity entries" do
      activities = [
        %{type: :member_joined, name: "alpha", detail: "Researcher", timestamp: @now},
        %{type: :member_suspect, name: "beta", detail: nil, timestamp: @now}
      ]

      html = render_component(&FeedComponents.activity_feed/1, activities: activities)
      assert html =~ "alpha"
      assert html =~ "beta"
      assert html =~ "Researcher"
    end

    test "respects max limit" do
      activities =
        for i <- 1..10 do
          %{type: :team_activity, name: "team-#{i}", detail: nil, timestamp: @now}
        end

      html = render_component(&FeedComponents.activity_feed/1, activities: activities, max: 3)
      assert html =~ "team-1"
      assert html =~ "team-2"
      assert html =~ "team-3"
      refute html =~ "team-4"
    end

    test "renders empty state" do
      html = render_component(&FeedComponents.activity_feed/1, activities: [])
      assert html =~ "Waiting for events"
    end

    test "includes log role for accessibility" do
      activities = [%{type: :member_joined, name: "a", detail: nil, timestamp: @now}]
      html = render_component(&FeedComponents.activity_feed/1, activities: activities)
      assert html =~ "role=\"log\""
    end
  end

  describe "activity_entry/1" do
    test "renders entry with icon and name" do
      entry = %{type: :member_joined, name: "alpha", detail: nil, timestamp: @now}
      html = render_component(&FeedComponents.activity_entry/1, entry: entry)
      assert html =~ "alpha"
      assert html =~ "text-green-400"
    end

    test "renders entry with detail" do
      entry = %{type: :team_activity, name: "team-a", detail: "processing", timestamp: @now}
      html = render_component(&FeedComponents.activity_entry/1, entry: entry)
      assert html =~ "team-a"
      assert html =~ "processing"
    end

    test "renders timestamp" do
      entry = %{type: :member_joined, name: "a", detail: nil, timestamp: @now}
      html = render_component(&FeedComponents.activity_entry/1, entry: entry)
      assert html =~ "12:00:00"
    end

    test "handles nil timestamp" do
      entry = %{type: :member_joined, name: "a", detail: nil, timestamp: nil}
      html = render_component(&FeedComponents.activity_entry/1, entry: entry)
      assert html =~ "a"
    end

    test "renders correct icon class for dead" do
      entry = %{type: :member_dead, name: "a", detail: nil, timestamp: @now}
      html = render_component(&FeedComponents.activity_entry/1, entry: entry)
      assert html =~ "text-red-400"
    end

    test "renders correct icon class for suspect" do
      entry = %{type: :member_suspect, name: "a", detail: nil, timestamp: @now}
      html = render_component(&FeedComponents.activity_entry/1, entry: entry)
      assert html =~ "text-yellow-400"
    end
  end
end
