defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @type linear_image_inputs :: %{
          enabled: boolean(),
          max_images: pos_integer(),
          allowed_hosts: [String.t()],
          allow_http: boolean()
        }

  @type workspace_hooks :: %{
          after_create: String.t() | nil,
          before_run: String.t() | nil,
          after_run: String.t() | nil,
          before_remove: String.t() | nil,
          timeout_ms: pos_integer()
        }

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        Schema.parse(config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec linear_endpoint() :: String.t()
  def linear_endpoint, do: settings!().tracker.endpoint

  @spec linear_api_token() :: String.t() | nil
  def linear_api_token, do: settings!().tracker.api_key

  @spec linear_project_slug() :: String.t() | nil
  def linear_project_slug, do: settings!().tracker.project_slug

  @spec linear_assignee() :: String.t() | nil
  def linear_assignee, do: settings!().tracker.assignee

  @spec linear_active_states() :: [String.t()]
  def linear_active_states, do: settings!().tracker.active_states

  @spec linear_terminal_states() :: [String.t()]
  def linear_terminal_states, do: settings!().tracker.terminal_states

  @spec linear_image_inputs() :: linear_image_inputs()
  def linear_image_inputs do
    image_inputs = settings!().tracker.image_inputs

    %{
      enabled: image_inputs.enabled,
      max_images: image_inputs.max_images,
      allowed_hosts: image_inputs.allowed_hosts,
      allow_http: image_inputs.allow_http
    }
  end

  @spec poll_interval_ms() :: pos_integer()
  def poll_interval_ms, do: settings!().polling.interval_ms

  @spec workspace_root() :: Path.t()
  def workspace_root, do: settings!().workspace.root

  @spec workspace_hooks() :: workspace_hooks()
  def workspace_hooks do
    hooks = settings!().hooks

    %{
      after_create: hooks.after_create,
      before_run: hooks.before_run,
      after_run: hooks.after_run,
      before_remove: hooks.before_remove,
      timeout_ms: hooks.timeout_ms
    }
  end

  @spec hook_timeout_ms() :: pos_integer()
  def hook_timeout_ms, do: settings!().hooks.timeout_ms

  @spec max_concurrent_agents() :: pos_integer()
  def max_concurrent_agents, do: settings!().agent.max_concurrent_agents

  @spec agent_max_turns() :: pos_integer()
  def agent_max_turns, do: settings!().agent.max_turns

  @spec agent_max_continuations() :: pos_integer()
  def agent_max_continuations, do: settings!().agent.max_continuations

  @spec max_retry_backoff_ms() :: pos_integer()
  def max_retry_backoff_ms, do: settings!().agent.max_retry_backoff_ms

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec codex_command() :: String.t()
  def codex_command, do: settings!().codex.command

  @spec codex_read_timeout_ms() :: pos_integer()
  def codex_read_timeout_ms, do: settings!().codex.read_timeout_ms

  @spec codex_stall_timeout_ms() :: non_neg_integer()
  def codex_stall_timeout_ms, do: settings!().codex.stall_timeout_ms

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec observability_enabled() :: boolean()
  def observability_enabled, do: settings!().observability.dashboard_enabled

  @spec observability_refresh_ms() :: pos_integer()
  def observability_refresh_ms, do: settings!().observability.refresh_ms

  @spec observability_render_interval_ms() :: pos_integer()
  def observability_render_interval_ms, do: settings!().observability.render_interval_ms

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @spec server_host() :: String.t()
  def server_host, do: settings!().server.host

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_semantics(settings)
    end
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings(),
         {:ok, turn_sandbox_policy} <-
           Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts) do
      {:ok,
       %{
         approval_policy: settings.codex.approval_policy,
         thread_sandbox: settings.codex.thread_sandbox,
         turn_sandbox_policy: turn_sandbox_policy
       }}
    end
  end

  defp validate_semantics(settings) do
    cond do
      is_nil(settings.tracker.kind) ->
        {:error, :missing_tracker_kind}

      settings.tracker.kind not in ["linear", "memory"] ->
        {:error, {:unsupported_tracker_kind, settings.tracker.kind}}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.api_key) ->
        {:error, :missing_linear_api_token}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.project_slug) ->
        {:error, :missing_linear_project_slug}

      true ->
        :ok
    end
  end

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end
end
