defmodule SymphonyElixir.IssueImagesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.IssueImages

  test "extract_urls returns valid markdown and html image URLs from allowed hosts" do
    description = """
    Markdown image: ![diagram](https://uploads.linear.app/demo/a.png)
    HTML image: <img src="https://uploads.linear.app/demo/b.jpg" alt="demo" />
    """

    assert IssueImages.extract_urls(description, allowed_hosts: ["uploads.linear.app"], max_images: 10) == [
             "https://uploads.linear.app/demo/a.png",
             "https://uploads.linear.app/demo/b.jpg"
           ]
  end

  test "extract_urls filters unsupported hosts and schemes" do
    description = """
    ![ok](https://uploads.linear.app/demo/a.png)
    ![blocked](https://example.com/demo/b.png)
    ![http](http://uploads.linear.app/demo/c.png)
    """

    assert IssueImages.extract_urls(description, allowed_hosts: ["uploads.linear.app"], max_images: 10) == [
             "https://uploads.linear.app/demo/a.png"
           ]
  end

  test "extract_urls supports wildcard hosts and preserves signed query strings" do
    description = """
    ![signed](https://assets.linear.app/file.png?X-Amz-Signature=abc123)
    """

    assert IssueImages.extract_urls(
             description,
             allowed_hosts: ["*.linear.app"],
             max_images: 10
           ) == ["https://assets.linear.app/file.png?X-Amz-Signature=abc123"]
  end

  test "extract_urls returns empty lists for nil and empty descriptions" do
    assert IssueImages.extract_urls(nil) == []
    assert IssueImages.extract_urls("") == []
  end

  test "extract_urls allows http when enabled and strips fragments" do
    description = """
    ![http](http://Uploads.Linear.App/demo/a.png#section)
    """

    assert IssueImages.extract_urls(
             description,
             allowed_hosts: [" ", " uploads.linear.app ", nil],
             allow_http: true,
             max_images: 10
           ) == ["http://uploads.linear.app/demo/a.png"]
  end

  test "extract_urls accepts wildcard suffix roots and defaults invalid max_images to one" do
    description = """
    ![root](https://linear.app/root.png)
    ![dup](https://linear.app/root.png)
    ![other](https://assets.linear.app/other.png)
    """

    assert IssueImages.extract_urls(
             description,
             allowed_hosts: ["*.linear.app"],
             max_images: 0
           ) == ["https://linear.app/root.png"]
  end

  test "extract_urls rejects invalid hosts and userinfo URLs" do
    description = """
    ![userinfo](https://user:pass@uploads.linear.app/secret.png)
    ![allowed](https://uploads.linear.app/demo/a.png)
    """

    assert IssueImages.extract_urls(
             description,
             allowed_hosts: :invalid,
             max_images: 10
           ) == []

    assert IssueImages.extract_urls(
             description,
             allowed_hosts: ["uploads.linear.app"],
             max_images: 10
           ) == ["https://uploads.linear.app/demo/a.png"]
  end
end
