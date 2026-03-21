defmodule SymphonyElixir.StartupOverridesTest do
  use ExUnit.Case, async: false

  import SymphonyElixir.TestSupport, only: [restore_env: 2]

  alias SymphonyElixir.StartupOverrides

  @app_env_keys [:workflow_file_path, :log_file, :server_port_override]

  @env_keys [
    "GH_TOKEN",
    "GITHUB_TOKEN",
    "SYMPHONY_GH_TOKEN",
    "SYMPHONY_GITHUB_TOKEN",
    "SYMPHONY_GH_TOKEN_FILE",
    "SYMPHONY_GITHUB_TOKEN_FILE",
    "SYMPHONY_WORKFLOW_FILE",
    "SYMPHONY_LOGS_ROOT",
    "SYMPHONY_PORT"
  ]

  setup do
    previous_values = Map.new(@app_env_keys, &{&1, Application.get_env(:symphony_elixir, &1)})
    previous_env = Map.new(@env_keys, &{&1, System.get_env(&1)})

    Enum.each(@app_env_keys, &Application.delete_env(:symphony_elixir, &1))
    Enum.each(@env_keys, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous_values, fn {key, value} -> restore_app_env(key, value) end)
      Enum.each(previous_env, fn {key, value} -> restore_env(key, value) end)
    end)

    :ok
  end

  test "apply/0 reads release env vars from the system environment" do
    System.put_env("SYMPHONY_WORKFLOW_FILE", "tmp/system-env/WORKFLOW.md")
    System.put_env("SYMPHONY_LOGS_ROOT", "tmp/system-env-logs")
    System.put_env("SYMPHONY_PORT", "4041")
    System.put_env("SYMPHONY_GITHUB_TOKEN", "service-github-token")

    assert :ok = StartupOverrides.apply()
    assert Application.get_env(:symphony_elixir, :workflow_file_path) == Path.expand("tmp/system-env/WORKFLOW.md")
    assert Application.get_env(:symphony_elixir, :log_file) == Path.join(Path.expand("tmp/system-env-logs"), "log/symphony.log")
    assert Application.get_env(:symphony_elixir, :server_port_override) == 4041
    assert System.get_env("GH_TOKEN") == "service-github-token"
    assert System.get_env("GITHUB_TOKEN") == "service-github-token"
  end

  test "apply/1 loads workflow, logs root, and port overrides from env" do
    workflow_path = Path.expand("tmp/release/WORKFLOW.md")
    logs_root = Path.expand("tmp/release-logs")

    assert :ok =
             StartupOverrides.apply(%{
               "SYMPHONY_WORKFLOW_FILE" => "tmp/release/WORKFLOW.md",
               "SYMPHONY_LOGS_ROOT" => "tmp/release-logs",
               "SYMPHONY_PORT" => "4040"
             })

    assert Application.get_env(:symphony_elixir, :workflow_file_path) == workflow_path
    assert Application.get_env(:symphony_elixir, :log_file) == Path.join(logs_root, "log/symphony.log")
    assert Application.get_env(:symphony_elixir, :server_port_override) == 4040
  end

  test "apply/1 injects GH_TOKEN and GITHUB_TOKEN from Symphony service env vars" do
    assert :ok =
             StartupOverrides.apply(%{
               "SYMPHONY_GH_TOKEN" => "service-gh-token"
             })

    assert System.get_env("GH_TOKEN") == "service-gh-token"
    assert System.get_env("GITHUB_TOKEN") == "service-gh-token"
  end

  test "apply/1 injects GitHub auth from a Symphony token file" do
    test_root = Path.join(System.tmp_dir!(), "symphony-startup-overrides-#{System.unique_integer([:positive])}")
    token_path = Path.join(test_root, "github-token")

    File.mkdir_p!(test_root)
    File.write!(token_path, "file-token\n")

    on_exit(fn -> File.rm_rf(test_root) end)

    assert :ok =
             StartupOverrides.apply(%{
               "SYMPHONY_GITHUB_TOKEN_FILE" => token_path
             })

    assert System.get_env("GH_TOKEN") == "file-token"
    assert System.get_env("GITHUB_TOKEN") == "file-token"
  end

  test "apply/1 preserves explicit app env overrides over release env vars" do
    Application.put_env(:symphony_elixir, :workflow_file_path, "/tmp/already-set/WORKFLOW.md")
    Application.put_env(:symphony_elixir, :log_file, "/tmp/already-set/log/symphony.log")
    Application.put_env(:symphony_elixir, :server_port_override, 5050)

    assert :ok =
             StartupOverrides.apply(%{
               "SYMPHONY_WORKFLOW_FILE" => "tmp/release/WORKFLOW.md",
               "SYMPHONY_LOGS_ROOT" => "tmp/release-logs",
               "SYMPHONY_PORT" => "4040"
             })

    assert Application.get_env(:symphony_elixir, :workflow_file_path) == "/tmp/already-set/WORKFLOW.md"
    assert Application.get_env(:symphony_elixir, :log_file) == "/tmp/already-set/log/symphony.log"
    assert Application.get_env(:symphony_elixir, :server_port_override) == 5050
  end

  test "apply/1 preserves explicit GH_TOKEN and GITHUB_TOKEN over Symphony service token env vars" do
    System.put_env("GH_TOKEN", "already-set-gh")
    System.put_env("GITHUB_TOKEN", "already-set-github")

    assert :ok =
             StartupOverrides.apply(%{
               "SYMPHONY_GITHUB_TOKEN" => "service-token"
             })

    assert System.get_env("GH_TOKEN") == "already-set-gh"
    assert System.get_env("GITHUB_TOKEN") == "already-set-github"
  end

  test "apply/1 rejects invalid SYMPHONY_PORT values without applying partial overrides" do
    assert {:error, message} =
             StartupOverrides.apply(%{
               "SYMPHONY_WORKFLOW_FILE" => "tmp/release/WORKFLOW.md",
               "SYMPHONY_LOGS_ROOT" => "tmp/release-logs",
               "SYMPHONY_PORT" => "abc"
             })

    assert message =~ "Invalid SYMPHONY_PORT"
    assert Application.get_env(:symphony_elixir, :workflow_file_path) == nil
    assert Application.get_env(:symphony_elixir, :log_file) == nil
    assert Application.get_env(:symphony_elixir, :server_port_override) == nil
  end

  test "apply/1 rejects negative SYMPHONY_PORT values without applying partial overrides" do
    assert {:error, message} =
             StartupOverrides.apply(%{
               "SYMPHONY_WORKFLOW_FILE" => "tmp/release/WORKFLOW.md",
               "SYMPHONY_LOGS_ROOT" => "tmp/release-logs",
               "SYMPHONY_PORT" => "-1"
             })

    assert message =~ "Invalid SYMPHONY_PORT"
    assert Application.get_env(:symphony_elixir, :workflow_file_path) == nil
    assert Application.get_env(:symphony_elixir, :log_file) == nil
    assert Application.get_env(:symphony_elixir, :server_port_override) == nil
  end

  test "apply/1 rejects unreadable Symphony GitHub token files without applying partial overrides" do
    missing_path = Path.join(System.tmp_dir!(), "missing-github-token-#{System.unique_integer([:positive])}")

    assert {:error, message} =
             StartupOverrides.apply(%{
               "SYMPHONY_GITHUB_TOKEN_FILE" => missing_path
             })

    assert message =~ "Invalid SYMPHONY_GITHUB_TOKEN_FILE"
    assert System.get_env("GH_TOKEN") == nil
    assert System.get_env("GITHUB_TOKEN") == nil
  end

  test "apply/1 rejects conflicting Symphony GitHub token sources" do
    assert {:error, message} =
             StartupOverrides.apply(%{
               "SYMPHONY_GH_TOKEN" => "first-token",
               "SYMPHONY_GITHUB_TOKEN" => "second-token"
             })

    assert message =~ "Conflicting Symphony GitHub token overrides"
    assert System.get_env("GH_TOKEN") == nil
    assert System.get_env("GITHUB_TOKEN") == nil
  end

  test "apply/1 ignores blank release env vars" do
    assert :ok =
             StartupOverrides.apply(%{
               "SYMPHONY_GITHUB_TOKEN" => "   ",
               "SYMPHONY_WORKFLOW_FILE" => "   ",
               "SYMPHONY_LOGS_ROOT" => "",
               "SYMPHONY_PORT" => "  "
             })

    assert Application.get_env(:symphony_elixir, :workflow_file_path) == nil
    assert Application.get_env(:symphony_elixir, :log_file) == nil
    assert Application.get_env(:symphony_elixir, :server_port_override) == nil
    assert System.get_env("GH_TOKEN") == nil
    assert System.get_env("GITHUB_TOKEN") == nil
  end

  test "apply/1 ignores non-binary release env values" do
    assert :ok =
             StartupOverrides.apply(%{
               "SYMPHONY_WORKFLOW_FILE" => nil,
               "SYMPHONY_LOGS_ROOT" => 123,
               "SYMPHONY_PORT" => false
             })

    assert Application.get_env(:symphony_elixir, :workflow_file_path) == nil
    assert Application.get_env(:symphony_elixir, :log_file) == nil
    assert Application.get_env(:symphony_elixir, :server_port_override) == nil
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
