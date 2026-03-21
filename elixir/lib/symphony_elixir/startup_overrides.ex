defmodule SymphonyElixir.StartupOverrides do
  @moduledoc """
  Applies release-friendly startup overrides from environment variables.
  """

  alias SymphonyElixir.{LogFile, Workflow}

  @workflow_file_env "SYMPHONY_WORKFLOW_FILE"
  @logs_root_env "SYMPHONY_LOGS_ROOT"
  @port_env "SYMPHONY_PORT"
  @gh_token_env "GH_TOKEN"
  @github_token_env "GITHUB_TOKEN"
  @service_gh_token_env "SYMPHONY_GH_TOKEN"
  @service_github_token_env "SYMPHONY_GITHUB_TOKEN"
  @service_gh_token_file_env "SYMPHONY_GH_TOKEN_FILE"
  @service_github_token_file_env "SYMPHONY_GITHUB_TOKEN_FILE"

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
         {:ok, server_port_override} <- server_port_override(env),
         {:ok, github_token} <- github_token_override(env) do
      {:ok,
       [
         workflow_file_path: workflow_file_path,
         log_file: log_file,
         server_port_override: server_port_override,
         github_token: github_token
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

  defp github_token_override(env) when is_map(env) do
    if existing_github_token?(env) do
      {:ok, nil}
    else
      with {:ok, candidates} <- github_token_candidates(env) do
        resolve_github_token_candidate(Enum.uniq(candidates))
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

  defp existing_github_token?(env) when is_map(env) do
    current_env = System.get_env()

    is_binary(env_value(env, @gh_token_env)) or
      is_binary(env_value(env, @github_token_env)) or
      is_binary(env_value(current_env, @gh_token_env)) or
      is_binary(env_value(current_env, @github_token_env))
  end

  defp github_token_candidates(env) when is_map(env) do
    inline_candidates =
      [
        env_value(env, @service_gh_token_env),
        env_value(env, @service_github_token_env)
      ]
      |> Enum.reject(&is_nil/1)

    with {:ok, file_candidates} <- github_token_file_candidates(env) do
      {:ok, inline_candidates ++ file_candidates}
    end
  end

  defp github_token_file_candidates(env) when is_map(env) do
    [@service_gh_token_file_env, @service_github_token_file_env]
    |> Enum.reduce_while({:ok, []}, fn key, {:ok, acc} ->
      collect_github_token_file_candidate(env, key, acc)
    end)
    |> finalize_github_token_file_candidates()
  end

  defp resolve_github_token_candidate([]), do: {:ok, nil}
  defp resolve_github_token_candidate([token]), do: {:ok, token}

  defp resolve_github_token_candidate(conflicting) when is_list(conflicting) do
    {:error, "Conflicting Symphony GitHub token overrides: expected a single value, got #{inspect(conflicting)}"}
  end

  defp collect_github_token_file_candidate(env, key, acc)
       when is_map(env) and is_binary(key) and is_list(acc) do
    with path when not is_nil(path) <- env_value(env, key),
         {:ok, token} <- read_token_file(path, key) do
      {:cont, {:ok, [token | acc]}}
    else
      nil -> {:cont, {:ok, acc}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp finalize_github_token_file_candidates({:ok, values}) when is_list(values) do
    {:ok, Enum.reverse(values)}
  end

  defp finalize_github_token_file_candidates({:error, _reason} = error), do: error

  defp read_token_file(path, env_name) when is_binary(path) and is_binary(env_name) do
    expanded_path = Path.expand(path)

    case File.read(expanded_path) do
      {:ok, token} ->
        case String.trim(token) do
          "" ->
            {:error, "Invalid #{env_name}: token file #{expanded_path} is empty"}

          trimmed ->
            {:ok, trimmed}
        end

      {:error, reason} ->
        {:error, "Invalid #{env_name}: failed to read #{expanded_path}: #{inspect(reason)}"}
    end
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

  defp apply_override({:github_token, token}) when is_binary(token) do
    System.put_env(@gh_token_env, token)
    System.put_env(@github_token_env, token)
  end
end
