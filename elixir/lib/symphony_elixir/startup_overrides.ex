defmodule SymphonyElixir.StartupOverrides do
  @moduledoc """
  Applies release-friendly startup overrides from environment variables.
  """

  alias SymphonyElixir.{LogFile, Workflow}

  @workflow_file_env "SYMPHONY_WORKFLOW_FILE"
  @logs_root_env "SYMPHONY_LOGS_ROOT"
  @port_env "SYMPHONY_PORT"

  @type env_map :: %{optional(String.t()) => String.t()}

  @spec apply() :: :ok | {:error, String.t()}
  def apply do
    apply(System.get_env())
  end

  @spec apply(env_map()) :: :ok | {:error, String.t()}
  def apply(env) when is_map(env) do
    with {:ok, overrides} <- resolve_overrides(env) do
      Enum.each(overrides, &apply_override/1)
      :ok
    end
  end

  defp resolve_overrides(env) when is_map(env) do
    with {:ok, workflow_file_path} <- workflow_file_override(env),
         {:ok, log_file} <- log_file_override(env),
         {:ok, server_port_override} <- server_port_override(env) do
      {:ok,
       [
         workflow_file_path: workflow_file_path,
         log_file: log_file,
         server_port_override: server_port_override
       ]
       |> Enum.reject(fn {_key, value} -> is_nil(value) end)}
    end
  end

  defp workflow_file_override(env) when is_map(env) do
    if existing_override?(:workflow_file_path) do
      {:ok, nil}
    else
      case env_value(env, @workflow_file_env) do
        nil -> {:ok, nil}
        path -> {:ok, Path.expand(path)}
      end
    end
  end

  defp log_file_override(env) when is_map(env) do
    if existing_override?(:log_file) do
      {:ok, nil}
    else
      case env_value(env, @logs_root_env) do
        nil -> {:ok, nil}
        path -> {:ok, path |> Path.expand() |> LogFile.default_log_file()}
      end
    end
  end

  defp server_port_override(env) when is_map(env) do
    if existing_override?(:server_port_override) do
      {:ok, nil}
    else
      case env_value(env, @port_env) do
        nil -> {:ok, nil}
        value -> parse_server_port_override(value)
      end
    end
  end

  defp parse_server_port_override(value) when is_binary(value) do
    case Integer.parse(value) do
      {port, ""} when port >= 0 -> {:ok, port}
      _ -> {:error, "Invalid #{@port_env}: expected a non-negative integer, got #{inspect(value)}"}
    end
  end

  defp existing_override?(key) when is_atom(key) do
    not is_nil(Application.get_env(:symphony_elixir, key))
  end

  defp env_value(env, key) when is_map(env) and is_binary(key) do
    case Map.get(env, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp apply_override({:workflow_file_path, path}) when is_binary(path) do
    :ok = Workflow.set_workflow_file_path(path)
  end

  defp apply_override({:log_file, path}) when is_binary(path) do
    Application.put_env(:symphony_elixir, :log_file, path)
  end

  defp apply_override({:server_port_override, port}) when is_integer(port) and port >= 0 do
    Application.put_env(:symphony_elixir, :server_port_override, port)
  end
end
