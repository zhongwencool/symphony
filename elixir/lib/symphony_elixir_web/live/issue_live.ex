defmodule SymphonyElixirWeb.IssueLive do
  @moduledoc """
  Live issue detail page for Symphony observability.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

  @runtime_tick_ms 1_000

  @impl true
  def mount(%{"issue_identifier" => issue_identifier}, _session, socket) do
    socket =
      socket
      |> assign(:issue_identifier, issue_identifier)
      |> assign(:payload, load_payload(issue_identifier))
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload(socket.assigns.issue_identifier))
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid issue-hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title issue-title">
              <%= @issue_identifier %>
            </h1>
            <p class="hero-copy">
              Issue runtime detail, current phase, and full recent agent timeline.
            </p>
            <div class="hero-actions">
              <a class="subtle-link" href="/">← Dashboard</a>
              <a class="subtle-link" href={"/api/v1/#{@issue_identifier}"}>JSON API</a>
            </div>
          </div>

          <%= if !@payload[:error] do %>
            <div class="status-stack issue-status-stack">
              <span class={state_badge_class(issue_state(@payload))}>
                <%= issue_state(@payload) %>
              </span>
              <%= if progress = issue_progress(@payload) do %>
                <span class={progress_badge_class(progress)}>
                  <%= progress_phase_label(progress.phase) %>
                </span>
              <% end %>
            </div>
          <% end %>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">Issue unavailable</h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Status</p>
            <p class="metric-value issue-metric-text"><%= issue_state(@payload) %></p>
            <p class="metric-detail">Current orchestrator view for this issue.</p>
          </article>

          <article :if={progress = issue_progress(@payload)} class="metric-card">
            <p class="metric-label">Phase</p>
            <p class="metric-value issue-metric-text"><%= progress_phase_label(progress.phase) %></p>
            <p class="metric-detail"><%= progress.label || "n/a" %></p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Turns</p>
            <p class="metric-value numeric"><%= issue_turn_count(@payload) %></p>
            <p class="metric-detail">Completed app-server turns in this active run.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Tokens</p>
            <p class="metric-value numeric"><%= format_int(issue_total_tokens(@payload)) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(issue_input_tokens(@payload)) %> / Out <%= format_int(issue_output_tokens(@payload)) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Attempts</p>
            <p class="metric-value numeric"><%= @payload.attempts.current_retry_attempt %></p>
            <p class="metric-detail">Current retry attempt recorded by the orchestrator.</p>
          </article>
        </section>

        <section class="issue-detail-grid">
          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Current activity</h2>
                <p class="section-copy">Derived runtime progress for this issue.</p>
              </div>
            </div>

            <%= if progress = issue_progress(@payload) do %>
              <div class="detail-stack issue-summary-stack">
                <div class="progress-header">
                  <span class={progress_badge_class(progress)}>
                    <%= progress_phase_label(progress.phase) %>
                  </span>
                </div>
                <span class="event-text"><%= progress.label || "n/a" %></span>
                <span class="muted event-meta"><%= progress_meta(progress, @now) %></span>
              </div>
            <% else %>
              <p class="empty-state">No active runtime progress is available for this issue.</p>
            <% end %>

            <div class="issue-meta-grid">
              <div>
                <p class="metric-label">Workspace</p>
                <p class="issue-meta-copy mono"><%= @payload.workspace.path %></p>
              </div>
              <div>
                <p class="metric-label">Session</p>
                <p class="issue-meta-copy mono"><%= issue_session_id(@payload) || "n/a" %></p>
              </div>
              <div :if={retry = @payload.retry}>
                <p class="metric-label">Retry due</p>
                <p class="issue-meta-copy mono"><%= retry.due_at || "n/a" %></p>
              </div>
              <div :if={retry = @payload.retry}>
                <p class="metric-label">Last error</p>
                <p class="issue-meta-copy"><%= retry.error || "n/a" %></p>
              </div>
            </div>
          </section>

          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Timeline</h2>
                <p class="section-copy">Most recent agent events for this issue.</p>
              </div>
            </div>

            <%= if @payload.timeline == [] do %>
              <p class="empty-state">No recent agent timeline is available.</p>
            <% else %>
              <ol class="issue-timeline-list">
                <li :for={event <- @payload.timeline} class="issue-timeline-item">
                  <div class="issue-timeline-topline">
                    <span class={timeline_phase_class(event.phase)}>
                      <%= progress_phase_label(event.phase) %>
                    </span>
                    <span class="timeline-time muted mono numeric">
                      <%= relative_time_label(event.at, @now) %>
                    </span>
                  </div>
                  <p class="issue-timeline-copy"><%= event.message || event.event || "n/a" %></p>
                  <p class="muted event-meta">
                    <%= event.event || "n/a" %>
                    <%= if waiting_on = timeline_waiting_on_copy(event.waiting_on) do %>
                      · <%= waiting_on %>
                    <% end %>
                    <%= if event.at do %>
                      · <span class="mono numeric"><%= event.at %></span>
                    <% end %>
                  </p>

                  <details :if={event[:raw_payload]} class="issue-raw-details">
                    <summary>Raw payload</summary>
                    <pre class="issue-raw-panel"><%= pretty_raw_payload(event.raw_payload) %></pre>
                  </details>
                </li>
              </ol>
            <% end %>
          </section>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_payload(issue_identifier) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} -> payload
      {:error, :issue_not_found} -> %{error: %{code: "issue_not_found", message: "Issue not found"}}
    end
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp issue_state(payload), do: Map.get(payload, :status, "unknown")

  defp issue_progress(payload), do: get_in(payload, [:running, :progress])

  defp issue_turn_count(payload), do: get_in(payload, [:running, :turn_count]) || 0

  defp issue_total_tokens(payload), do: get_in(payload, [:running, :tokens, :total_tokens]) || 0

  defp issue_input_tokens(payload), do: get_in(payload, [:running, :tokens, :input_tokens]) || 0

  defp issue_output_tokens(payload), do: get_in(payload, [:running, :tokens, :output_tokens]) || 0

  defp issue_session_id(payload), do: get_in(payload, [:running, :session_id])

  defp pretty_raw_payload(value) when is_binary(value), do: value
  defp pretty_raw_payload(value), do: inspect(value, pretty: true, limit: :infinity)

  defp format_int(value) do
    if is_integer(value) do
      value
      |> Integer.to_string()
      |> String.reverse()
      |> String.replace(~r/.{3}(?=.)/, "\0,")
      |> String.reverse()
    else
      "n/a"
    end
  end

  defp relative_time_label(timestamp, %DateTime{} = now) do
    cond do
      is_nil(timestamp) ->
        "n/a"

      is_binary(timestamp) ->
        case DateTime.from_iso8601(timestamp) do
          {:ok, parsed, _offset} -> format_relative_seconds(DateTime.diff(now, parsed, :second))
          _ -> timestamp
        end

      true ->
        "n/a"
    end
  end

  defp format_relative_seconds(seconds) when is_integer(seconds) do
    cond do
      seconds <= 0 -> "just now"
      seconds < 60 -> "#{seconds}s ago"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      true -> "#{div(seconds, 3_600)}h ago"
    end
  end

  defp state_badge_class(state) do
    if String.contains?(to_string(state) |> String.downcase(), ["retry", "queued", "pending"]) do
      "state-badge state-badge-warning"
    else
      "state-badge state-badge-active"
    end
  end

  defp progress_badge_class(progress) do
    cond do
      progress.stalled == true ->
        "state-badge state-badge-danger"

      progress.waiting_on in ["approval", "input"] ->
        "state-badge state-badge-warning"

      true ->
        "state-badge state-badge-active"
    end
  end

  defp timeline_phase_class(phase) do
    cond do
      phase == "stalled" -> "timeline-phase timeline-phase-danger"
      phase in ["waiting_approval", "waiting_input", "retrying"] -> "timeline-phase timeline-phase-warning"
      true -> "timeline-phase timeline-phase-active"
    end
  end

  defp progress_phase_label(phase) do
    labels = %{
      "starting" => "Starting",
      "planning" => "Planning",
      "executing" => "Executing",
      "validating" => "Validating",
      "waiting_approval" => "Waiting approval",
      "waiting_input" => "Waiting input",
      "retrying" => "Retrying",
      "stalled" => "Stalled"
    }

    normalized = phase && to_string(phase)
    Map.get(labels, normalized, format_generic_label(normalized))
  end

  defp progress_meta(progress, now) do
    [
      progress.updated_at && "Last active #{relative_time_label(progress.updated_at, now)}",
      waiting_on_copy(progress.waiting_on),
      progress.stalled && "restart timeout exceeded"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp waiting_on_copy(waiting_on) do
    %{
      "approval" => "waiting on approval",
      "input" => "waiting on input"
    }
    |> Map.get(waiting_on)
  end

  defp timeline_waiting_on_copy(waiting_on) do
    %{
      "approval" => "waiting on approval",
      "input" => "waiting on input",
      "retry_window" => "retry window scheduled"
    }
    |> Map.get(waiting_on, default_timeline_waiting_on(waiting_on))
  end

  defp default_timeline_waiting_on(waiting_on) do
    if waiting_on in [nil, "none"] do
      nil
    else
      "waiting on #{String.replace(to_string(waiting_on), "_", " ")}"
    end
  end

  defp format_generic_label(value), do: (value || "unknown") |> String.replace("_", " ") |> String.capitalize()

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end
end
