defmodule Jido.Chat.Mattermost.Transport.ReqClientConfigTest do
  use ExUnit.Case, async: true

  test "missing URL and token produce descriptive errors in an isolated VM" do
    script = ~S"""
    import ExUnit.Assertions
    alias Jido.Chat.Mattermost.Transport.ReqClient

    Application.delete_env(:jido_chat_mattermost, :url)
    Application.delete_env(:jido_chat_mattermost, :token)

    assert_raise RuntimeError, ~r/Mattermost URL not configured/, fn ->
      ReqClient.fetch_channel("c1", [])
    end

    assert_raise RuntimeError, ~r/Mattermost token not configured/, fn ->
      ReqClient.fetch_channel("c1", url: "http://localhost:8065")
    end
    """

    paths = Path.wildcard(Path.join([Mix.Project.build_path(), "lib", "*", "ebin"]))
    args = Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", script]
    {output, status} = System.cmd("elixir", args, stderr_to_stdout: true)
    assert status == 0, output
  end

  test "unusable upload sources fail without making a request" do
    for file <- [%{}, %{path: ""}, %{body: ""}, %{body: "bytes"}, %{body: "bytes", filename: ""}] do
      assert {:error, :missing_file_source} =
               Jido.Chat.Mattermost.Transport.ReqClient.upload_files("c1", [file], [])
    end
  end

  test "upload sizing rejects missing or invalid limits before making a request" do
    file = %{body: "x", filename: "file.txt"}

    for {limit, reason} <- [
          {nil, :missing_configuration},
          {0, :invalid_configuration},
          {-1, :invalid_configuration},
          {"10", :invalid_configuration}
        ] do
      assert {:error, {^reason, :max_file_size}} =
               Jido.Chat.Mattermost.Transport.ReqClient.upload_files("room", [file], max_file_size: limit)
    end
  end

  test "multipart overhead is checked for every file before any upload" do
    file = %{body: "x", filename: "small.txt"}
    long_header = %{body: "x", filename: String.duplicate("long", 1000) <> ".txt"}

    # No URL or token: reaching HTTP before planning the later file would raise.
    assert {:error, :upload_request_too_large} =
             Jido.Chat.Mattermost.Transport.ReqClient.upload_files("room", [file, long_header], max_file_size: 1024)
  end
end
