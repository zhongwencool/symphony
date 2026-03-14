defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard}

  @active_now_window_seconds 15
  @state_recent_events_limit 5

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.map(snapshot.running, &running_entry_payload/1)

        %{
          generated_at: generated_at,
          counts: counts_payload(running, snapshot.retrying),
          running: running,
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry),
      status: issue_status(running, retry),
      workspace: %{
        path: Path.join(Config.workspace_root(), issue_identifier)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      logs: %{
        codex_session_logs: []
      },
      recent_events: recent_events_payload(running),
      timeline: issue_timeline_payload(running, retry),
      last_error: retry && retry.error,
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, retry),
    do: (running && running.issue_id) || (retry && retry.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(_running, nil), do: "running"
  defp issue_status(nil, _retry), do: "retrying"
  defp issue_status(_running, _retry), do: "running"

  defp counts_payload(running, retrying) do
    %{
      running: length(running),
      retrying: length(retrying),
      waiting: Enum.count(running, &waiting_progress?/1),
      stalled: Enum.count(running, &stalled_progress?/1),
      active_now: Enum.count(running, &active_now?/1)
    }
  end

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      progress: progress_payload(entry),
      recent_events: recent_events_payload(entry, @state_recent_events_limit),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error
    }
  end

  defp running_issue_payload(running) do
    %{
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      progress: progress_payload(running),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: retry_due_at(retry),
      error: retry.error
    }
  end

  defp progress_payload(entry) when is_map(entry) do
    %{
      phase: progress_phase(entry),
      label: progress_label(entry),
      updated_at: iso8601(Map.get(entry, :progress_updated_at) || Map.get(entry, :last_codex_timestamp) || Map.get(entry, :started_at)),
      waiting_on: progress_waiting_on(entry),
      stalled: Map.get(entry, :progress_stalled, false) == true
    }
  end

  defp recent_events_payload(nil, _limit), do: []

  defp recent_events_payload(running, limit) when is_integer(limit) and limit > 0 do
    running
    |> recent_event_entries()
    |> Enum.take(limit)
    |> Enum.map(&recent_event_payload/1)
  end

  defp recent_events_payload(running), do: recent_events_payload(running, 20)

  defp issue_timeline_payload(nil, retry), do: maybe_prepend_retry_event([], retry)

  defp issue_timeline_payload(running, retry) do
    running
    |> recent_event_entries()
    |> Enum.map(&recent_event_payload/1)
    |> maybe_prepend_retry_event(retry)
  end

  defp maybe_prepend_retry_event(events, nil), do: events

  defp maybe_prepend_retry_event(events, retry) do
    [retry_timeline_event(retry) | events]
    |> Enum.reject(&is_nil/1)
  end

  defp retry_timeline_event(%{due_in_ms: due_in_ms, attempt: attempt, error: error}) do
    %{
      at: due_at_iso8601(due_in_ms),
      event: "retry_scheduled",
      phase: "retrying",
      waiting_on: "retry_window",
      message: retry_timeline_message(attempt, error)
    }
  end

  defp retry_timeline_event(%{due_at: due_at, attempt: attempt, error: error}) do
    %{
      at: due_at,
      event: "retry_scheduled",
      phase: "retrying",
      waiting_on: "retry_window",
      message: retry_timeline_message(attempt, error)
    }
  end

  defp retry_timeline_event(_retry), do: nil

  defp retry_timeline_message(attempt, error) do
    base = "retry attempt #{attempt || 0} scheduled"
    if is_binary(error) and error != "", do: base <> ": " <> error, else: base
  end

  defp recent_event_entries(running) do
    case Map.get(running, :recent_codex_events) do
      events when is_list(events) and events != [] -> events
      _ -> fallback_recent_events(running)
    end
  end

  defp fallback_recent_events(running) do
    [
      %{
        event: Map.get(running, :last_codex_event),
        message: Map.get(running, :last_codex_message),
        timestamp: Map.get(running, :last_codex_timestamp),
        phase: Map.get(running, :progress_phase),
        waiting_on: Map.get(running, :progress_waiting_on)
      }
    ]
    |> Enum.reject(&is_nil(&1.timestamp))
  end

  defp recent_event_payload(event) do
    raw_payload = raw_event_payload(event.message)

    %{
      at: iso8601(event.timestamp),
      event: event_name(event.event),
      phase: atom_name(event.phase),
      waiting_on: atom_name(event.waiting_on),
      message: summarize_message(event.message)
    }
    |> put_if_present(:raw_payload, raw_payload)
  end

  defp raw_event_payload(%{message: %{payload: payload}}) when is_map(payload), do: payload
  defp raw_event_payload(%{message: %{payload: payload}}) when is_binary(payload), do: payload
  defp raw_event_payload(%{payload: payload}) when is_map(payload), do: payload
  defp raw_event_payload(%{payload: payload}) when is_binary(payload), do: payload
  defp raw_event_payload(%{"payload" => payload}) when is_map(payload), do: payload
  defp raw_event_payload(%{"payload" => payload}) when is_binary(payload), do: payload
  defp raw_event_payload(_event_message), do: nil

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp progress_phase(entry) do
    entry
    |> Map.get(:progress_phase)
    |> atom_name()
    |> case do
      nil -> "executing"
      phase -> phase
    end
  end

  defp progress_label(entry) do
    summarize_message(Map.get(entry, :progress_label) || Map.get(entry, :last_codex_message))
  end

  defp progress_waiting_on(entry) do
    entry
    |> Map.get(:progress_waiting_on)
    |> atom_name()
    |> case do
      nil -> "none"
      waiting_on -> waiting_on
    end
  end

  defp waiting_progress?(%{progress: %{waiting_on: waiting_on}}), do: waiting_on != "none"
  defp waiting_progress?(_entry), do: false

  defp stalled_progress?(%{progress: %{stalled: true}}), do: true
  defp stalled_progress?(_entry), do: false

  defp active_now?(%{progress: %{updated_at: updated_at}}) when is_binary(updated_at) do
    case DateTime.from_iso8601(updated_at) do
      {:ok, parsed, _offset} -> DateTime.diff(DateTime.utc_now(), parsed, :second) <= @active_now_window_seconds
      _ -> false
    end
  end

  defp active_now?(_entry), do: false

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp retry_due_at(%{due_in_ms: due_in_ms}) when is_integer(due_in_ms), do: due_at_iso8601(due_in_ms)
  defp retry_due_at(%{due_at: due_at}) when is_binary(due_at), do: due_at
  defp retry_due_at(_retry), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil

  defp atom_name(nil), do: nil
  defp atom_name(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_name(value) when is_binary(value), do: value
  defp atom_name(_value), do: nil

  defp event_name(nil), do: nil
  defp event_name(value) when is_atom(value), do: Atom.to_string(value)
  defp event_name(value) when is_binary(value), do: value
  defp event_name(_value), do: nil
end
