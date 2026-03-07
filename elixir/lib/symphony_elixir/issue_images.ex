defmodule SymphonyElixir.IssueImages do
  @moduledoc """
  Extracts and validates image URLs from issue descriptions for Codex turn input.
  """

  @markdown_image_regex ~r/!\[[^\]]*\]\((?<url>https?:\/\/[^)\s]+)(?:\s+"[^"]*")?\)/
  @html_image_regex ~r/<img[^>]+src=["'](?<url>https?:\/\/[^"']+)["'][^>]*>/i

  @type options :: [
          allowed_hosts: [String.t()],
          max_images: pos_integer() | nil,
          allow_http: boolean()
        ]

  @spec extract_urls(String.t() | nil) :: [String.t()]
  def extract_urls(description), do: extract_urls(description, [])

  @spec extract_urls(String.t() | nil, options()) :: [String.t()]
  def extract_urls(description, _opts) when description in [nil, ""], do: []

  @spec extract_urls(String.t() | nil, options()) :: [String.t()]
  def extract_urls(description, opts) when is_binary(description) do
    allowed_hosts =
      opts
      |> Keyword.get(:allowed_hosts, [])
      |> normalize_allowed_hosts()

    max_images =
      opts
      |> Keyword.get(:max_images, 1)
      |> normalize_max_images()

    allow_http = Keyword.get(opts, :allow_http, false) == true

    description
    |> collect_candidate_urls()
    |> Enum.map(&normalize_and_validate_url(&1, allow_http, allowed_hosts))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> maybe_take_max_images(max_images)
  end

  defp collect_candidate_urls(description) do
    markdown_images = Regex.scan(@markdown_image_regex, description, capture: ["url"]) |> List.flatten()
    html_images = Regex.scan(@html_image_regex, description, capture: ["url"]) |> List.flatten()
    markdown_images ++ html_images
  end

  defp normalize_and_validate_url(raw_url, allow_http, allowed_hosts) do
    with trimmed when trimmed != "" <- String.trim(raw_url),
         %URI{} = uri <- URI.parse(trimmed),
         true <- valid_scheme?(uri.scheme, allow_http),
         true <- is_nil(uri.userinfo),
         host when is_binary(host) <- normalize_host(uri.host),
         true <- host_allowed?(host, allowed_hosts) do
      uri
      |> Map.put(:scheme, String.downcase(uri.scheme))
      |> Map.put(:host, host)
      |> Map.put(:userinfo, nil)
      |> Map.put(:fragment, nil)
      |> URI.to_string()
    else
      _ -> nil
    end
  end

  defp valid_scheme?("https", _allow_http), do: true
  defp valid_scheme?("http", true), do: true
  defp valid_scheme?(_scheme, _allow_http), do: false

  defp host_allowed?(_host, []), do: false
  defp host_allowed?(host, allowed_hosts), do: Enum.any?(allowed_hosts, &host_matches?(host, &1))

  defp host_matches?(host, "*." <> suffix) do
    host == suffix or String.ends_with?(host, "." <> suffix)
  end

  defp host_matches?(host, allowed_host), do: host == allowed_host

  defp normalize_allowed_hosts(hosts) when is_list(hosts) do
    hosts
    |> Enum.map(&normalize_host/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_allowed_hosts(_hosts), do: []

  defp normalize_host(host) when is_binary(host) do
    case host |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_host(_host), do: nil

  defp maybe_take_max_images(urls, nil), do: urls

  defp maybe_take_max_images(urls, max_images) when is_integer(max_images) and max_images > 0,
    do: Enum.take(urls, max_images)

  defp normalize_max_images(nil), do: nil
  defp normalize_max_images(max_images) when is_integer(max_images) and max_images > 0, do: max_images
  defp normalize_max_images(_max_images), do: 1
end
