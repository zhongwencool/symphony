defmodule SymphonyElixir.Codex.AppServer do
  @moduledoc """
  Minimal client for the Codex app-server JSON-RPC 2.0 stream over stdio.
  """

  require Logger
  alias SymphonyElixir.{Codex.DynamicTool, Config, IssueImages, PathSafety, SSH}

  @initialize_id 1
  @thread_start_id 2
  @turn_start_id 3
  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000
  @max_timeout_context_lines 5
  @non_interactive_tool_input_answer "This is a non-interactive session. Operator input is unavailable."
  @issue_image_fetch_timeout 20_000
  @max_issue_image_bytes 2_000_000
  @forwarded_env_vars [
    "GIT_AUTHOR_NAME",
    "GIT_AUTHOR_EMAIL",
    "GIT_AUTHOR_DATE",
    "GIT_COMMITTER_NAME",
    "GIT_COMMITTER_EMAIL",
    "GIT_COMMITTER_DATE",
    "GITHUB_TOKEN",
    "SSH_AUTH_SOCK",
    "XDG_CONFIG_HOME",
    "GIT_CONFIG_GLOBAL"
  ]
  @forwarded_env_prefixes ["JJ_"]

  @type session :: %{
          launch_home: Path.t() | nil,
          port: port(),
          metadata: map(),
          approval_policy: String.t() | map(),
          auto_approve_requests: boolean(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map(),
          thread_id: String.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    with {:ok, validated_workspace} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, {port, launch_home}} <- start_port(validated_workspace, worker_host) do
      metadata = port_metadata(port, worker_host)

      with {:ok, session_policies} <- session_policies(validated_workspace, worker_host),
           {:ok, thread_id} <- do_start_session(port, validated_workspace, session_policies) do
        {:ok,
         %{
           launch_home: launch_home,
           port: port,
           metadata: metadata,
           approval_policy: session_policies.approval_policy,
           auto_approve_requests: session_policies.approval_policy == "never",
           thread_sandbox: session_policies.thread_sandbox,
           turn_sandbox_policy: session_policies.turn_sandbox_policy,
           thread_id: thread_id,
           workspace: validated_workspace,
           worker_host: worker_host
         }}
      else
        {:error, reason} ->
          stop_port(port)
          cleanup_codex_launch_home(launch_home)
          {:error, reason}
      end
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          port: port,
          metadata: metadata,
          approval_policy: approval_policy,
          auto_approve_requests: auto_approve_requests,
          turn_sandbox_policy: turn_sandbox_policy,
          thread_id: thread_id,
          workspace: workspace
        },
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    tool_executor =
      Keyword.get(opts, :tool_executor, fn tool, arguments ->
        DynamicTool.execute(tool, arguments)
      end)

    image_fetcher =
      Keyword.get(opts, :image_fetcher, &fetch_issue_image_data_url/1)

    case start_turn(port, thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy, image_fetcher) do
      {:ok, turn_id} ->
        session_id = "#{thread_id}-#{turn_id}"
        Logger.info("Codex session started for #{issue_context(issue)} session_id=#{session_id}")

        emit_message(
          on_message,
          :session_started,
          %{
            session_id: session_id,
            thread_id: thread_id,
            turn_id: turn_id
          },
          metadata
        )

        case await_turn_completion(port, on_message, tool_executor, auto_approve_requests) do
          {:ok, result} ->
            Logger.info("Codex session completed for #{issue_context(issue)} session_id=#{session_id}")

            {:ok,
             %{
               result: result,
               session_id: session_id,
               thread_id: thread_id,
               turn_id: turn_id
             }}

          {:error, reason} ->
            Logger.warning("Codex session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

            emit_message(
              on_message,
              :turn_ended_with_error,
              %{
                session_id: session_id,
                reason: reason
              },
              metadata
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Codex session failed for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason}, metadata)
        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port, launch_home: launch_home}) when is_port(port) do
    stop_port(port)
    cleanup_codex_launch_home(launch_home)
  end

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(workspace_root())
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp start_port(workspace, nil) do
    case System.find_executable("bash") do
      executable when is_binary(executable) ->
        start_local_port(workspace, executable)

      _ ->
        {:error, :bash_not_found}
    end
  end

  defp start_port(workspace, worker_host) when is_binary(worker_host) do
    remote_command = remote_launch_command(workspace)

    case SSH.start_port(worker_host, remote_command, line: @port_line_bytes) do
      {:ok, port} -> {:ok, {port, nil}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_codex_launch_home(home) when is_binary(home) and home != "" do
    launch_home = Path.join(System.tmp_dir!(), "symphony-codex-home-#{unique_launch_home_suffix()}")

    with :ok <- File.mkdir_p(launch_home),
         :ok <- prepare_codex_config_home(home, launch_home),
         :ok <- prepare_codex_agents_home(home, launch_home) do
      {:ok, launch_home}
    else
      {:error, reason} ->
        cleanup_codex_launch_home(launch_home)
        {:error, {:codex_launch_home_prepare_failed, reason}}
    end
  end

  defp start_local_port(workspace, executable)
       when is_binary(workspace) and is_binary(executable) do
    case current_home_dir() do
      home when is_binary(home) and home != "" ->
        with {:ok, launch_home} <- prepare_codex_launch_home(home) do
          port =
            Port.open(
              {:spawn_executable, String.to_charlist(executable)},
              [
                :binary,
                :exit_status,
                :stderr_to_stdout,
                args: [~c"-lc", String.to_charlist(codex_command())],
                cd: String.to_charlist(workspace),
                env: codex_port_env(launch_home, home),
                line: @port_line_bytes
              ]
            )

          {:ok, {port, launch_home}}
        end

      _ ->
        {:error, :home_not_found}
    end
  end

  defp current_home_dir do
    System.get_env("HOME") || System.user_home()
  end

  defp unique_launch_home_suffix do
    random_suffix = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    "#{System.system_time(:microsecond)}-#{random_suffix}"
  end

  defp prepare_codex_agents_home(source_home, launch_home) do
    source_agents = Path.join(source_home, ".agents")
    dest_agents = Path.join(launch_home, ".agents")

    prepare_optional_codex_home_dir(source_agents, dest_agents, fn src, dest, entry ->
      case entry do
        "skills" -> prepare_filtered_skills_dir(src, dest)
        _ -> link_codex_home_path(src, dest)
      end
    end)
  end

  defp prepare_codex_config_home(source_home, launch_home) do
    source_codex = Path.join(source_home, ".codex")
    dest_codex = Path.join(launch_home, ".codex")

    prepare_optional_codex_home_dir(source_codex, dest_codex, fn src, dest, entry ->
      case entry do
        "config.toml" -> sanitize_codex_config(src, dest)
        _ -> link_codex_home_path(src, dest)
      end
    end)
  end

  defp prepare_filtered_skills_dir(source_skills, dest_skills) do
    prepare_optional_codex_home_dir(source_skills, dest_skills, fn src, dest, _entry ->
      mirror_valid_skill(src, dest)
    end)
  end

  defp mirror_valid_skill(source_skill, dest_skill) do
    if File.dir?(source_skill) do
      do_mirror_valid_skill(source_skill, dest_skill)
    else
      :ok
    end
  end

  defp broken_symlink?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> not File.exists?(path)
      _ -> false
    end
  end

  defp sanitize_codex_config(source, dest) do
    with true <- File.exists?(source) or {:error, :missing_source},
         {:ok, content} <- File.read(source),
         :ok <- File.write(dest, strip_launch_home_mcp_servers(content)) do
      :ok
    else
      {:error, :missing_source} -> :ok
      {:error, reason} -> {:error, {:codex_config_prepare_failed, source, reason}}
    end
  end

  defp strip_launch_home_mcp_servers(content) when is_binary(content) do
    {lines, _skip_prefix} =
      content
      |> String.split("\n", trim: false)
      |> Enum.reduce({[], nil}, &strip_launch_home_mcp_server_line/2)

    Enum.reverse(lines)
    |> Enum.join("\n")
  end

  defp prepare_optional_codex_home_dir(source_dir, dest_dir, entry_fun) do
    if File.dir?(source_dir) do
      link_codex_home_entries(source_dir, dest_dir, entry_fun)
    else
      :ok
    end
  end

  defp link_codex_home_entries(source_dir, dest_dir, entry_fun) do
    with :ok <- File.mkdir_p(dest_dir),
         {:ok, entries} <- File.ls(source_dir) do
      Enum.reduce_while(entries, :ok, fn entry, :ok ->
        reduce_codex_home_entry(source_dir, dest_dir, entry, entry_fun)
      end)
    end
  end

  defp reduce_codex_home_entry(source_dir, dest_dir, entry, entry_fun) do
    src = Path.join(source_dir, entry)
    dest = Path.join(dest_dir, entry)

    case entry_fun.(src, dest, entry) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp do_mirror_valid_skill(source_skill, dest_skill) do
    with {:ok, entries} <- File.ls(source_skill),
         :ok <- validate_skill_entries(source_skill, entries),
         :ok <- File.mkdir_p(dest_skill) do
      link_codex_home_entries(source_skill, dest_skill, fn src, dest, _entry ->
        link_codex_home_path(src, dest)
      end)
    else
      {:skip, broken_entries} ->
        Logger.warning("Skipping invalid Codex skill path=#{source_skill} broken_entries=#{inspect(broken_entries)}")
        :ok

      {:error, reason} ->
        {:error, {:skill_prepare_failed, source_skill, reason}}
    end
  end

  defp validate_skill_entries(source_skill, entries) do
    case Enum.filter(entries, &broken_symlink?(Path.join(source_skill, &1))) do
      [] -> :ok
      broken_entries -> {:skip, Enum.sort(broken_entries)}
    end
  end

  defp strip_launch_home_mcp_server_line(line, {acc, skip_prefix}) do
    case codex_config_table_name(line) do
      {:ok, table_name} -> strip_launch_home_mcp_server_table(line, table_name, acc, skip_prefix)
      :error -> strip_launch_home_mcp_server_content(line, acc, skip_prefix)
    end
  end

  defp strip_launch_home_mcp_server_table(line, table_name, acc, skip_prefix) do
    cond do
      launch_home_mcp_server_table?(table_name) ->
        {acc, table_name}

      skipped_launch_home_subtable?(table_name, skip_prefix) ->
        {acc, skip_prefix}

      true ->
        {[line | acc], nil}
    end
  end

  defp strip_launch_home_mcp_server_content(line, acc, skip_prefix) do
    if is_binary(skip_prefix) do
      {acc, skip_prefix}
    else
      {[line | acc], nil}
    end
  end

  defp codex_config_table_name(line) when is_binary(line) do
    case Regex.run(~r/^\s*\[([^\]]+)\]\s*$/, line, capture: :all_but_first) do
      [table_name] -> {:ok, String.trim(table_name)}
      _ -> :error
    end
  end

  defp launch_home_mcp_server_table?("mcp_servers.linear"), do: true
  defp launch_home_mcp_server_table?(_table_name), do: false

  defp skipped_launch_home_subtable?(table_name, skip_prefix)
       when is_binary(table_name) and is_binary(skip_prefix) do
    String.starts_with?(table_name, skip_prefix <> ".")
  end

  defp skipped_launch_home_subtable?(_table_name, _skip_prefix), do: false

  defp link_codex_home_path(source, dest) do
    if File.exists?(source) do
      File.ln_s(source, dest)
    else
      :ok
    end
  end

  defp codex_port_env(launch_home, source_home) do
    %{}
    |> put_port_env("HOME", launch_home)
    |> put_port_env("CODEX_HOME", Path.join(launch_home, ".codex"))
    |> maybe_put_forwarded_env_vars()
    |> maybe_put_forwarded_env_prefixes()
    |> maybe_put_default_port_env("XDG_CONFIG_HOME", xdg_config_home(source_home))
    |> maybe_put_default_port_env("GIT_CONFIG_GLOBAL", git_config_global(source_home))
    |> maybe_put_default_port_env("GH_CONFIG_DIR", gh_config_dir(source_home))
    |> maybe_put_default_port_env("GH_TOKEN", gh_token(source_home))
    |> Enum.map(fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
  end

  defp maybe_put_forwarded_env_vars(env) when is_map(env) do
    Enum.reduce(@forwarded_env_vars, env, fn name, acc ->
      maybe_put_port_env(acc, name, env_value(name))
    end)
  end

  defp maybe_put_forwarded_env_prefixes(env) when is_map(env) do
    System.get_env()
    |> Enum.reduce(env, fn {name, value}, acc ->
      if Enum.any?(@forwarded_env_prefixes, &String.starts_with?(name, &1)) do
        maybe_put_port_env(acc, name, blank_env_value_to_nil(value))
      else
        acc
      end
    end)
  end

  defp xdg_config_home(source_home) when is_binary(source_home) and source_home != "" do
    env_value("XDG_CONFIG_HOME") || Path.join(source_home, ".config")
  end

  defp git_config_global(source_home) when is_binary(source_home) and source_home != "" do
    env_value("GIT_CONFIG_GLOBAL") || Path.join(source_home, ".gitconfig")
  end

  defp gh_config_dir(source_home) when is_binary(source_home) and source_home != "" do
    env_value("GH_CONFIG_DIR") || Path.join(xdg_config_home(source_home), "gh")
  end

  defp gh_token(source_home) when is_binary(source_home) and source_home != "" do
    env_value("GH_TOKEN") || env_value("GITHUB_TOKEN") || gh_auth_token(source_home)
  end

  defp gh_auth_token(source_home) when is_binary(source_home) and source_home != "" do
    case System.find_executable("gh") do
      executable when is_binary(executable) ->
        case System.cmd(executable, ["auth", "token"],
               env: gh_auth_env(source_home),
               stderr_to_stdout: true
             ) do
          {output, 0} -> output |> String.trim() |> blank_env_value_to_nil()
          {_output, _status} -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp gh_auth_env(source_home) when is_binary(source_home) and source_home != "" do
    [{"HOME", source_home}]
    |> maybe_put_cmd_env("GH_CONFIG_DIR", gh_config_dir(source_home))
  end

  defp maybe_put_port_env(env, _key, nil) when is_map(env), do: env

  defp maybe_put_port_env(env, key, value) when is_map(env) and is_binary(key) and is_binary(value) do
    case blank_env_value_to_nil(value) do
      nil -> env
      normalized -> Map.put(env, key, normalized)
    end
  end

  defp maybe_put_default_port_env(env, key, value)
       when is_map(env) and is_binary(key) and is_binary(value) do
    if Map.has_key?(env, key) do
      env
    else
      maybe_put_port_env(env, key, value)
    end
  end

  defp maybe_put_default_port_env(env, _key, _value) when is_map(env), do: env

  defp put_port_env(env, key, value) when is_map(env) and is_binary(key) and is_binary(value) do
    Map.put(env, key, value)
  end

  defp maybe_put_cmd_env(env, _key, nil) when is_list(env), do: env

  defp maybe_put_cmd_env(env, key, value) when is_list(env) and is_binary(key) and is_binary(value) do
    [{key, value} | env]
  end

  defp env_value(name) when is_binary(name) do
    name
    |> System.get_env()
    |> blank_env_value_to_nil()
  end

  defp blank_env_value_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp blank_env_value_to_nil(_value), do: nil

  defp cleanup_codex_launch_home(path) when is_binary(path) and path != "" do
    File.rm_rf(path)
    :ok
  end

  defp cleanup_codex_launch_home(_path), do: :ok

  defp remote_launch_command(workspace) when is_binary(workspace) do
    [
      "cd #{shell_escape(workspace)}",
      "exec #{codex_command()}"
    ]
    |> Enum.join(" && ")
  end

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{codex_app_server_pid: to_string(os_pid)}

        _ ->
          %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp send_initialize(port) do
    payload = %{
      "method" => "initialize",
      "id" => @initialize_id,
      "params" => %{
        "capabilities" => %{
          "experimentalApi" => true
        },
        "clientInfo" => %{
          "name" => "symphony-orchestrator",
          "title" => "Symphony Orchestrator",
          "version" => "0.1.0"
        }
      }
    }

    send_message(port, payload)

    with {:ok, _} <- await_response(port, @initialize_id) do
      send_message(port, %{"method" => "initialized", "params" => %{}})
      :ok
    end
  end

  defp session_policies(workspace, nil) do
    Config.codex_runtime_settings(workspace)
  end

  defp session_policies(workspace, worker_host) when is_binary(worker_host) do
    Config.codex_runtime_settings(workspace, remote: true)
  end

  defp do_start_session(port, workspace, session_policies) do
    case send_initialize(port) do
      :ok -> start_thread(port, workspace, session_policies)
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_thread(port, workspace, %{approval_policy: approval_policy, thread_sandbox: thread_sandbox}) do
    send_message(port, %{
      "method" => "thread/start",
      "id" => @thread_start_id,
      "params" => %{
        "approvalPolicy" => approval_policy,
        "sandbox" => thread_sandbox,
        "cwd" => workspace,
        "dynamicTools" => DynamicTool.tool_specs()
      }
    })

    case await_response(port, @thread_start_id) do
      {:ok, %{"thread" => thread_payload}} ->
        case thread_payload do
          %{"id" => thread_id} -> {:ok, thread_id}
          _ -> {:error, {:invalid_thread_payload, thread_payload}}
        end

      other ->
        other
    end
  end

  defp start_turn(
         port,
         thread_id,
         prompt,
         issue,
         workspace,
         approval_policy,
         turn_sandbox_policy,
         image_fetcher
       ) do
    input = build_turn_input(prompt, issue, image_fetcher)

    send_message(port, %{
      "method" => "turn/start",
      "id" => @turn_start_id,
      "params" => %{
        "threadId" => thread_id,
        "input" => input,
        "cwd" => workspace,
        "title" => "#{issue.identifier}: #{issue.title}",
        "approvalPolicy" => approval_policy,
        "sandboxPolicy" => turn_sandbox_policy
      }
    })

    case await_response(port, @turn_start_id) do
      {:ok, %{"turn" => %{"id" => turn_id}}} -> {:ok, turn_id}
      other -> other
    end
  end

  defp build_turn_input(prompt, issue, image_fetcher)
       when is_binary(prompt) and is_function(image_fetcher, 1) do
    text_input = [%{"type" => "text", "text" => prompt}]
    text_input ++ build_issue_image_inputs(issue, image_fetcher)
  end

  defp build_issue_image_inputs(issue, image_fetcher) when is_map(issue) and is_function(image_fetcher, 1) do
    config = linear_image_inputs()

    if config.enabled do
      issue
      |> Map.get(:description)
      |> IssueImages.extract_urls(
        allowed_hosts: config.allowed_hosts,
        max_images: nil,
        allow_http: config.allow_http
      )
      |> collect_issue_image_inputs(config.max_images, image_fetcher)
    else
      []
    end
  end

  defp build_issue_image_inputs(_issue, _image_fetcher), do: []

  defp collect_issue_image_inputs(image_urls, max_images, image_fetcher)
       when is_list(image_urls) and is_integer(max_images) and max_images > 0 and is_function(image_fetcher, 1) do
    {inputs, _count} =
      Enum.reduce_while(image_urls, {[], 0}, fn image_url, {inputs, count} ->
        case to_issue_image_input(image_url, image_fetcher) do
          %{} = input ->
            accumulate_issue_image_input(input, inputs, count, max_images)

          nil ->
            {:cont, {inputs, count}}
        end
      end)

    Enum.reverse(inputs)
  end

  defp collect_issue_image_inputs(_image_urls, _max_images, _image_fetcher), do: []

  defp accumulate_issue_image_input(input, inputs, count, max_images) when is_map(input) do
    next_count = count + 1
    next_inputs = [input | inputs]
    maybe_finish_issue_image_inputs(next_inputs, next_count, max_images)
  end

  defp maybe_finish_issue_image_inputs(inputs, count, max_images) when count >= max_images,
    do: {:halt, {inputs, count}}

  defp maybe_finish_issue_image_inputs(inputs, count, _max_images), do: {:cont, {inputs, count}}

  defp to_issue_image_input(image_url, image_fetcher) when is_binary(image_url) do
    case image_fetcher.(image_url) do
      {:ok, data_url} when is_binary(data_url) and data_url != "" ->
        %{"type" => "image", "url" => data_url}

      {:error, reason} ->
        Logger.warning("Skipping issue image input from #{image_url_for_log(image_url)}: #{inspect(reason)}")
        nil

      other ->
        Logger.warning("Skipping issue image input from #{image_url_for_log(image_url)}: unexpected result #{inspect(other)}")
        nil
    end
  end

  defp to_issue_image_input(_image_url, _image_fetcher), do: nil

  defp fetch_issue_image_data_url(image_url) when is_binary(image_url) do
    with {:ok, response} <- request_issue_image(image_url, []),
         {:ok, response} <- maybe_retry_issue_image_with_linear_auth(image_url, response),
         :ok <- ensure_issue_image_success_status(response.status),
         {:ok, content_type} <- extract_issue_image_content_type(response.headers),
         {:ok, image_body} <- normalize_issue_image_body(response.body),
         :ok <- validate_issue_image_size(image_body) do
      {:ok, "data:#{content_type};base64," <> Base.encode64(image_body)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp request_issue_image(image_url, headers) when is_binary(image_url) and is_list(headers) do
    Req.get(image_url,
      headers: headers,
      connect_options: [timeout: @issue_image_fetch_timeout],
      receive_timeout: @issue_image_fetch_timeout
    )
  end

  defp maybe_retry_issue_image_with_linear_auth(image_url, %Req.Response{status: 401} = response) do
    case linear_auth_header_for_image_url(image_url) do
      {:ok, header} -> request_issue_image(image_url, [header])
      {:error, _reason} -> {:ok, response}
    end
  end

  defp maybe_retry_issue_image_with_linear_auth(_image_url, %Req.Response{} = response), do: {:ok, response}

  defp linear_auth_header_for_image_url(image_url) when is_binary(image_url) do
    host =
      image_url
      |> URI.parse()
      |> Map.get(:host)
      |> normalize_host()

    with true <- linear_auth_host?(host),
         {:ok, token} <- linear_image_auth_token() do
      {:ok, {"Authorization", token}}
    else
      false -> {:error, :host_not_linear}
      {:error, reason} -> {:error, reason}
    end
  end

  defp linear_auth_host?(host) when is_binary(host) do
    host == "linear.app" or String.ends_with?(host, ".linear.app")
  end

  defp linear_auth_host?(_host), do: false

  defp linear_image_auth_token do
    case linear_api_token() do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, :missing_linear_api_token}
    end
  end

  defp ensure_issue_image_success_status(status) when is_integer(status) and status in 200..299, do: :ok
  defp ensure_issue_image_success_status(status) when is_integer(status), do: {:error, {:image_fetch_http_status, status}}

  defp extract_issue_image_content_type(headers) when is_list(headers) or is_map(headers) do
    content_type =
      Enum.find_value(headers, fn
        {name, value} ->
          if normalize_header_name(name) == "content-type" do
            header_value_to_string(value)
          else
            nil
          end

        _ ->
          nil
      end)

    case normalize_image_content_type(content_type) do
      {:ok, normalized} -> {:ok, normalized}
      :error when is_nil(content_type) -> {:error, :missing_image_content_type}
      :error -> {:error, {:invalid_image_content_type, content_type}}
    end
  end

  defp extract_issue_image_content_type(_headers), do: {:error, :missing_image_content_type}

  defp normalize_header_name(name) do
    name
    |> to_string()
    |> String.downcase()
  end

  defp normalize_image_content_type(value) when is_binary(value) do
    value
    |> String.split(";", parts: 2)
    |> List.first()
    |> String.trim()
    |> String.downcase()
    |> case do
      <<"image/", _::binary>> = content_type -> {:ok, content_type}
      _ -> :error
    end
  end

  defp normalize_image_content_type(_value), do: :error

  defp header_value_to_string([value | _]), do: header_value_to_string(value)
  defp header_value_to_string(value) when is_binary(value), do: value

  defp header_value_to_string(value) when is_list(value) do
    if List.ascii_printable?(value) do
      List.to_string(value)
    else
      nil
    end
  end

  defp header_value_to_string(_value), do: nil

  defp normalize_issue_image_body(body) when is_binary(body) and body != "", do: {:ok, body}
  defp normalize_issue_image_body(body) when is_binary(body), do: {:error, :empty_image_body}
  defp normalize_issue_image_body(body), do: {:error, {:non_binary_image_body, body}}

  defp validate_issue_image_size(image_body) when byte_size(image_body) <= @max_issue_image_bytes, do: :ok

  defp validate_issue_image_size(image_body) do
    {:error, {:image_too_large, byte_size(image_body), @max_issue_image_bytes}}
  end

  defp image_url_for_log(image_url) when is_binary(image_url) do
    case URI.parse(image_url) do
      %URI{scheme: scheme, host: host, path: path} when is_binary(scheme) and is_binary(host) ->
        sanitized_path = path || ""
        "#{scheme}://#{host}#{sanitized_path}"

      %URI{host: host, path: path} when is_binary(host) ->
        sanitized_path = path || ""
        "#{host}#{sanitized_path}"

      _ ->
        image_url
    end
  end

  defp normalize_host(host) when is_binary(host) do
    host
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_host(_host), do: nil

  defp await_turn_completion(port, on_message, tool_executor, auto_approve_requests) do
    receive_loop(port, on_message, codex_turn_timeout_ms(), "", tool_executor, auto_approve_requests)
  end

  defp receive_loop(port, on_message, timeout_ms, pending_line, tool_executor, auto_approve_requests) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_incoming(port, on_message, complete_line, timeout_ms, tool_executor, auto_approve_requests)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(
          port,
          on_message,
          timeout_ms,
          pending_line <> to_string(chunk),
          tool_executor,
          auto_approve_requests
        )

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp handle_incoming(port, on_message, data, timeout_ms, tool_executor, auto_approve_requests) do
    payload_string = to_string(data)

    case Jason.decode(payload_string) do
      {:ok, %{"method" => "turn/completed"} = payload} ->
        emit_turn_event(on_message, :turn_completed, payload, payload_string, port, payload)
        {:ok, :turn_completed}

      {:ok, %{"method" => "turn/failed", "params" => _} = payload} ->
        emit_turn_event(
          on_message,
          :turn_failed,
          payload,
          payload_string,
          port,
          Map.get(payload, "params")
        )

        {:error, {:turn_failed, Map.get(payload, "params")}}

      {:ok, %{"method" => "turn/cancelled", "params" => _} = payload} ->
        emit_turn_event(
          on_message,
          :turn_cancelled,
          payload,
          payload_string,
          port,
          Map.get(payload, "params")
        )

        {:error, {:turn_cancelled, Map.get(payload, "params")}}

      {:ok, %{"method" => method} = payload}
      when is_binary(method) ->
        handle_turn_method(
          port,
          on_message,
          payload,
          payload_string,
          method,
          timeout_ms,
          tool_executor,
          auto_approve_requests
        )

      {:ok, payload} ->
        emit_message(
          on_message,
          :other_message,
          %{
            payload: payload,
            raw: payload_string
          },
          metadata_from_message(port, payload)
        )

        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)

      {:error, _reason} ->
        log_non_json_stream_line(payload_string, "turn stream")

        if protocol_message_candidate?(payload_string) do
          emit_message(
            on_message,
            :malformed,
            %{
              payload: payload_string,
              raw: payload_string
            },
            metadata_from_message(port, %{raw: payload_string})
          )
        end

        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)
    end
  end

  defp emit_turn_event(on_message, event, payload, payload_string, port, payload_details) do
    emit_message(
      on_message,
      event,
      %{
        payload: payload,
        raw: payload_string,
        details: payload_details
      },
      metadata_from_message(port, payload)
    )
  end

  defp handle_turn_method(
         port,
         on_message,
         payload,
         payload_string,
         method,
         timeout_ms,
         tool_executor,
         auto_approve_requests
       ) do
    metadata = metadata_from_message(port, payload)

    case maybe_handle_approval_request(
           port,
           method,
           payload,
           payload_string,
           on_message,
           metadata,
           tool_executor,
           auto_approve_requests
         ) do
      :input_required ->
        emit_message(
          on_message,
          :turn_input_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:turn_input_required, payload}}

      :approved ->
        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)

      :approval_required ->
        emit_message(
          on_message,
          :approval_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:approval_required, payload}}

      :unhandled ->
        if needs_input?(method, payload) do
          emit_message(
            on_message,
            :turn_input_required,
            %{payload: payload, raw: payload_string},
            metadata
          )

          {:error, {:turn_input_required, payload}}
        else
          emit_message(
            on_message,
            :notification,
            %{
              payload: payload,
              raw: payload_string
            },
            metadata
          )

          Logger.debug("Codex notification: #{inspect(method)}")
          receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)
        end
    end
  end

  defp maybe_handle_approval_request(
         port,
         "item/commandExecution/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/call",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         tool_executor,
         _auto_approve_requests
       ) do
    tool_name = tool_call_name(params)
    arguments = tool_call_arguments(params)

    result = tool_executor.(tool_name, arguments)

    send_message(port, %{
      "id" => id,
      "result" => result
    })

    event =
      case result do
        %{"success" => true} -> :tool_call_completed
        _ when is_nil(tool_name) -> :unsupported_tool_call
        _ -> :tool_call_failed
      end

    emit_message(on_message, event, %{payload: payload, raw: payload_string}, metadata)

    :approved
  end

  defp maybe_handle_approval_request(
         port,
         "execCommandApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "applyPatchApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/fileChange/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/requestUserInput",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    maybe_auto_answer_tool_request_user_input(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         _port,
         _method,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         _tool_executor,
         _auto_approve_requests
       ) do
    :unhandled
  end

  defp approve_or_require(
         port,
         id,
         decision,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    send_message(port, %{"id" => id, "result" => %{"decision" => decision}})

    emit_message(
      on_message,
      :approval_auto_approved,
      %{payload: payload, raw: payload_string, decision: decision},
      metadata
    )

    :approved
  end

  defp approve_or_require(
         _port,
         _id,
         _decision,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         false
       ) do
    :approval_required
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    case tool_request_user_input_approval_answers(params) do
      {:ok, answers, decision} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :approval_auto_approved,
          %{payload: payload, raw: payload_string, decision: decision},
          metadata
        )

        :approved

      :error ->
        reply_with_non_interactive_tool_input_answer(
          port,
          id,
          params,
          payload,
          payload_string,
          on_message,
          metadata
        )
    end
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         false
       ) do
    reply_with_non_interactive_tool_input_answer(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata
    )
  end

  defp tool_request_user_input_approval_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_approval_answer(question) do
          {:ok, question_id, answer_label} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [answer_label]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map, "Approve this Session"}
      _ -> :error
    end
  end

  defp tool_request_user_input_approval_answers(_params), do: :error

  defp reply_with_non_interactive_tool_input_answer(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata
       ) do
    case tool_request_user_input_unavailable_answers(params) do
      {:ok, answers} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :tool_input_auto_answered,
          %{payload: payload, raw: payload_string, answer: @non_interactive_tool_input_answer},
          metadata
        )

        :approved

      :error ->
        :input_required
    end
  end

  defp tool_request_user_input_unavailable_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_question_id(question) do
          {:ok, question_id} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [@non_interactive_tool_input_answer]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map}
      _ -> :error
    end
  end

  defp tool_request_user_input_unavailable_answers(_params), do: :error

  defp tool_request_user_input_question_id(%{"id" => question_id}) when is_binary(question_id),
    do: {:ok, question_id}

  defp tool_request_user_input_question_id(_question), do: :error

  defp tool_request_user_input_approval_answer(%{"id" => question_id, "options" => options})
       when is_binary(question_id) and is_list(options) do
    case tool_request_user_input_approval_option_label(options) do
      nil -> :error
      answer_label -> {:ok, question_id, answer_label}
    end
  end

  defp tool_request_user_input_approval_answer(_question), do: :error

  defp tool_request_user_input_approval_option_label(options) do
    options
    |> Enum.map(&tool_request_user_input_option_label/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      labels ->
        Enum.find(labels, &(&1 == "Approve this Session")) ||
          Enum.find(labels, &(&1 == "Approve Once")) ||
          Enum.find(labels, &approval_option_label?/1)
    end
  end

  defp tool_request_user_input_option_label(%{"label" => label}) when is_binary(label), do: label
  defp tool_request_user_input_option_label(_option), do: nil

  defp approval_option_label?(label) when is_binary(label) do
    normalized_label =
      label
      |> String.trim()
      |> String.downcase()

    String.starts_with?(normalized_label, "approve") or String.starts_with?(normalized_label, "allow")
  end

  defp await_response(port, request_id) do
    with_timeout_response(
      port,
      request_id,
      response_stage(request_id),
      codex_read_timeout_ms(),
      "",
      []
    )
  end

  defp with_timeout_response(port, request_id, stage, timeout_ms, pending_line, recent_output) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)

        handle_response(
          port,
          request_id,
          stage,
          complete_line,
          timeout_ms,
          recent_output
        )

      {^port, {:data, {:noeol, chunk}}} ->
        with_timeout_response(
          port,
          request_id,
          stage,
          timeout_ms,
          pending_line <> to_string(chunk),
          recent_output
        )

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, response_timeout_error(stage, timeout_ms, pending_line, recent_output)}
    end
  end

  defp handle_response(port, request_id, stage, data, timeout_ms, recent_output) do
    payload = to_string(data)

    case Jason.decode(payload) do
      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, {:response_error, error}}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^request_id} = response_payload} ->
        {:error, {:response_error, response_payload}}

      {:ok, %{} = other} ->
        Logger.debug("Ignoring message while waiting for response: #{inspect(other)}")

        with_timeout_response(port, request_id, stage, timeout_ms, "", recent_output)

      {:error, _} ->
        log_non_json_stream_line(payload, "response stream")

        with_timeout_response(
          port,
          request_id,
          stage,
          timeout_ms,
          "",
          remember_timeout_context_line(recent_output, payload)
        )
    end
  end

  defp response_stage(@initialize_id), do: :initialize
  defp response_stage(@thread_start_id), do: :thread_start
  defp response_stage(@turn_start_id), do: :turn_start

  defp response_timeout_error(stage, timeout_ms, pending_line, recent_output) do
    timeout_context = timeout_context_lines(pending_line, recent_output)

    case timeout_context do
      [] ->
        {:response_timeout, stage, timeout_ms}

      lines ->
        {:response_timeout, stage, timeout_ms, lines}
    end
  end

  defp timeout_context_lines(pending_line, recent_output) do
    recent_output = Enum.take(recent_output, -@max_timeout_context_lines)

    case normalize_timeout_context_line(pending_line) do
      nil -> recent_output
      line -> Enum.take(recent_output ++ ["[partial] " <> line], -@max_timeout_context_lines)
    end
  end

  defp remember_timeout_context_line(recent_output, line) do
    case normalize_timeout_context_line(line) do
      nil -> recent_output
      normalized -> Enum.take(recent_output ++ [normalized], -@max_timeout_context_lines)
    end
  end

  defp normalize_timeout_context_line(line) do
    line
    |> to_string()
    |> String.trim()
    |> String.slice(0, @max_stream_log_bytes)
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp log_non_json_stream_line(data, stream_label) do
    text = normalize_timeout_context_line(data)

    if is_binary(text) do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Codex #{stream_label} output: #{text}")
      else
        Logger.debug("Codex #{stream_label} output: #{text}")
      end
    end
  end

  defp protocol_message_candidate?(data) do
    data
    |> to_string()
    |> String.trim_leading()
    |> String.starts_with?("{")
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
    end
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp metadata_from_message(port, payload) do
    port |> port_metadata(nil) |> maybe_set_usage(payload)
  end

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    usage = Map.get(payload, "usage") || Map.get(payload, :usage)

    if is_map(usage) do
      Map.put(metadata, :usage, usage)
    else
      metadata
    end
  end

  defp maybe_set_usage(metadata, _payload), do: metadata

  defp workspace_root do
    Config.settings!().workspace.root
  end

  defp codex_command do
    Config.settings!().codex.command
  end

  defp codex_turn_timeout_ms do
    Config.settings!().codex.turn_timeout_ms
  end

  defp codex_read_timeout_ms do
    Config.settings!().codex.read_timeout_ms
  end

  defp linear_api_token do
    Config.settings!().tracker.api_key
  end

  defp linear_image_inputs do
    image_inputs =
      Config.settings!().tracker
      |> Map.get(:image_inputs, %{})

    %{
      enabled: Map.get(image_inputs, :enabled, true),
      max_images: Map.get(image_inputs, :max_images, 3),
      allowed_hosts: Map.get(image_inputs, :allowed_hosts, ["uploads.linear.app"]),
      allow_http: Map.get(image_inputs, :allow_http, false)
    }
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp default_on_message(_message), do: :ok

  defp tool_call_name(params) when is_map(params) do
    case Map.get(params, "tool") || Map.get(params, :tool) || Map.get(params, "name") || Map.get(params, :name) do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp tool_call_name(_params), do: nil

  defp tool_call_arguments(params) when is_map(params) do
    Map.get(params, "arguments") || Map.get(params, :arguments) || %{}
  end

  defp tool_call_arguments(_params), do: %{}

  defp send_message(port, message) do
    line = Jason.encode!(message) <> "\n"
    Port.command(port, line)
  end

  defp needs_input?(method, payload)
       when is_binary(method) and is_map(payload) do
    String.starts_with?(method, "turn/") && input_required_method?(method, payload)
  end

  defp needs_input?(_method, _payload), do: false

  defp input_required_method?(method, payload) when is_binary(method) do
    method in [
      "turn/input_required",
      "turn/needs_input",
      "turn/need_input",
      "turn/request_input",
      "turn/request_response",
      "turn/provide_input",
      "turn/approval_required"
    ] || request_payload_requires_input?(payload)
  end

  defp request_payload_requires_input?(payload) do
    params = Map.get(payload, "params")
    needs_input_field?(payload) || needs_input_field?(params)
  end

  defp needs_input_field?(payload) when is_map(payload) do
    Map.get(payload, "requiresInput") == true or
      Map.get(payload, "needsInput") == true or
      Map.get(payload, "input_required") == true or
      Map.get(payload, "inputRequired") == true or
      Map.get(payload, "type") == "input_required" or
      Map.get(payload, "type") == "needs_input"
  end

  defp needs_input_field?(_payload), do: false
end
