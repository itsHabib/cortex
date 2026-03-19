defmodule CortexWeb.RunDetail.GraphTab do
  @moduledoc """
  Graph tab for RunDetailLive — DAG mode only.

  Renders the dependency graph (tier visualization with edges)
  for workflow/DAG runs. Stateless function component.
  """
  use Phoenix.Component

  import CortexWeb.DAGComponents

  @doc """
  Renders the DAG graph tab content.
  """
  attr(:run, :map, required: true)
  attr(:team_runs, :list, required: true)
  attr(:tiers, :list, required: true)
  attr(:edges, :list, required: true)

  def graph_tab(assigns) do
    ~H"""
    <div>
      <%= if @tiers != [] do %>
        <div class="bg-gray-900 rounded-lg border border-gray-800 p-4">
          <h2 class="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">Dependency Graph</h2>
          <.dag_graph tiers={@tiers} teams={@team_runs} edges={@edges} run_id={@run.id} />
        </div>
      <% else %>
        <div class="bg-gray-900 rounded-lg border border-gray-800 p-6">
          <p class="text-gray-500 text-sm">No dependency graph available for this run.</p>
        </div>
      <% end %>
    </div>
    """
  end
end
