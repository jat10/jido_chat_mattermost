defmodule Jido.Chat.Mattermost.Transport.ReqClient do
  @moduledoc """
  Req-based Mattermost REST API v4 HTTP client.

  Resolves base URL and token from (in priority order):
    1. `opts[:url]` / `opts[:token]`
    2. `Application.get_env(:jido_chat_mattermost, :url)` / `:token`
  """

  @behaviour Jido.Chat.Mattermost.Transport

  @impl true
  def send_message(channel_id, text, opts) do
    body =
      %{"channel_id" => channel_id, "message" => text || ""}
      |> Map.merge(thread_params(opts))
      |> maybe_put_body("file_ids", opts[:file_ids])

    post("/api/v4/posts", body, opts)
  end

  @impl true
  def upload_files(channel_id, [_ | _] = files, opts) do
    with {:ok, parts} <- multipart_files(files),
         {:ok, limit} <- upload_limit(opts),
         {:ok, batches} <- upload_batches(channel_id, parts, limit) do
      Enum.reduce_while(batches, {:ok, nil}, fn batch, {:ok, previous} ->
        with {:ok, result} <- upload_batch(channel_id, batch, opts) do
          {:cont, {:ok, merge_upload_results(previous, result)}}
        else
          {:error, reason} = error ->
            if opts[:attachment_failure_policy] in [:continue, :abort] do
              {:halt, {:error, {:partial_upload, %{reason: reason, uploaded: previous || %{"file_infos" => []}}}}}
            else
              {:halt, error}
            end
        end
      end)
    end
  end

  def upload_files(_channel_id, _files, _opts), do: {:error, :missing_file_source}

  defp upload_batch(channel_id, batch, opts) do
    with {:ok, result} <- post_multipart("/api/v4/files", [{:channel_id, channel_id} | batch], opts),
         :ok <- confirm_upload_batch(result, length(batch)) do
      {:ok, result}
    end
  rescue
    error ->
      if opts[:attachment_failure_policy] in [:continue, :abort],
        do: {:error, :transport_exception},
        else: reraise(error, __STACKTRACE__)
  catch
    :exit, reason ->
      if opts[:attachment_failure_policy] in [:continue, :abort],
        do: {:error, :transport_exit},
        else: exit(reason)
  end

  defp multipart_files(files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, parts} ->
      case multipart_file(file) do
        {:ok, part} -> {:cont, {:ok, parts ++ [{:files, part}]}}
        error -> {:halt, error}
      end
    end)
  end

  defp upload_limit(opts) do
    case Keyword.get(opts, :max_file_size, Application.get_env(:jido_chat_mattermost, :max_file_size)) do
      nil -> {:error, {:missing_configuration, :max_file_size}}
      limit when is_integer(limit) and limit > 0 -> {:ok, limit}
      _ -> {:error, {:invalid_configuration, :max_file_size}}
    end
  end

  defp upload_batches(channel_id, parts, limit) do
    # Mattermost v10 permits MaxFileSize + bytes.MinRead (512 bytes).
    # Plan every request before uploading, using the same parts as Req.post/2.
    Enum.reduce_while(parts, {:ok, []}, fn part, {:ok, batches} ->
      if upload_size(channel_id, [part]) > limit + 512 do
        {:halt, {:error, :upload_request_too_large}}
      else
        case List.pop_at(batches, -1) do
          {nil, _} ->
            {:cont, {:ok, [[part]]}}

          {last, rest} ->
            if upload_size(channel_id, last ++ [part]) <= limit + 512,
              do: {:cont, {:ok, rest ++ [last ++ [part]]}},
              else: {:cont, {:ok, batches ++ [[part]]}}
        end
      end
    end)
  end

  defp upload_size(channel_id, parts) do
    Req.Utils.encode_form_multipart([{:channel_id, channel_id} | parts]).size
  end

  defp confirm_upload_batch(%{"file_infos" => [_ | _] = infos}, count) do
    ids = Enum.map(infos, fn info -> if is_map(info), do: info["id"] end)

    if length(ids) == count and length(Enum.uniq(ids)) == count and
         Enum.all?(ids, &(is_binary(&1) and &1 != "")),
       do: :ok,
       else: {:error, :unconfirmed_upload}
  end

  defp confirm_upload_batch(_result, _count), do: {:error, :missing_uploaded_file_id}

  defp merge_upload_results(nil, result), do: result

  defp merge_upload_results(previous, result) do
    Map.merge(previous, result, fn
      key, left, right when key in ["file_infos", "client_ids"] -> left ++ right
      _key, _left, right -> right
    end)
  end

  defp multipart_file(%{path: path} = file) when is_binary(path) and path != "" do
    {:ok, {File.stream!(path, 2048), multipart_file_options(file, Map.get(file, :filename) || Path.basename(path))}}
  end

  defp multipart_file(%{body: body, filename: filename} = file)
       when is_binary(body) and body != "" and is_binary(filename) and filename != "" do
    {:ok, {body, multipart_file_options(file, filename)}}
  end

  defp multipart_file(_file), do: {:error, :missing_file_source}

  @impl true
  def download_file(file_id, opts) do
    url = base_url(opts) <> "/api/v4/files/#{file_id}"

    case Req.get(url, headers: auth_headers(opts), decode_body: false) do
      {:ok, %{status: status, body: resp_body}} when status in 200..299 -> {:ok, resp_body}
      {:ok, %{status: status, body: resp_body}} -> {:error, {status, resp_body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def edit_message(channel_id, post_id, text, opts) do
    body =
      %{"id" => post_id, "channel_id" => channel_id, "message" => text}
      |> maybe_put_body("file_ids", opts[:file_ids])

    put("/api/v4/posts/#{post_id}", body, opts)
  end

  @impl true
  def delete_message(_channel_id, post_id, opts) do
    delete("/api/v4/posts/#{post_id}", opts)
  end

  @impl true
  def add_reaction(post_id, emoji, opts) do
    with {:ok, user_id} <- resolve_user_id(opts) do
      body = %{"user_id" => user_id, "post_id" => post_id, "emoji_name" => emoji}
      post("/api/v4/reactions", body, opts)
    end
  end

  @impl true
  def remove_reaction(post_id, emoji, user_id, opts) do
    delete("/api/v4/users/#{user_id}/posts/#{post_id}/reactions/#{emoji}", opts)
  end

  @impl true
  def fetch_posts(channel_id, opts) do
    params = build_fetch_params(opts)
    get("/api/v4/channels/#{channel_id}/posts", params, opts)
  end

  @impl true
  def fetch_post(post_id, opts) do
    get("/api/v4/posts/#{post_id}", [], opts)
  end

  @impl true
  def fetch_thread(root_id, opts) do
    get("/api/v4/posts/#{root_id}/thread", [], opts)
  end

  @impl true
  def fetch_channel(channel_id, opts) do
    get("/api/v4/channels/#{channel_id}", [], opts)
  end

  @impl true
  def send_typing(channel_id, opts) do
    case post("/api/v4/users/me/typing", %{"channel_id" => channel_id}, opts) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @impl true
  def get_user(user_id, opts) do
    get("/api/v4/users/#{user_id}", [], opts)
  end

  @doc """
  Creates or returns the existing DM channel between two users.

  Requires the bot user ID and the target user ID. Returns the channel map on
  success, including `"id"` which can be used as a `channel_id` for sending.

      ReqClient.open_dm_channel(bot_user_id, target_user_id, opts)
  """
  @impl true
  def open_dm_channel(bot_user_id, target_user_id, opts) do
    post("/api/v4/channels/direct", [bot_user_id, target_user_id], opts)
  end

  @doc "Lists all teams the bot belongs to."
  def list_teams(opts) do
    get("/api/v4/users/me/teams", [], opts)
  end

  @doc "Lists public channels for a given team."
  def list_public_channels(team_id, opts) do
    get("/api/v4/teams/#{team_id}/channels", [per_page: 200], opts)
  end

  # --- private helpers ---

  defp resolve_user_id(opts) do
    case opts[:user_id] do
      nil ->
        case get("/api/v4/users/me", [], opts) do
          {:ok, %{"id" => id}} -> {:ok, id}
          {:error, _} = err -> err
        end

      user_id ->
        {:ok, user_id}
    end
  end

  defp thread_params(opts) do
    case opts[:thread_id] do
      nil -> %{}
      root_id -> %{"root_id" => root_id}
    end
  end

  defp build_fetch_params(opts) do
    []
    |> maybe_put(:per_page, opts[:limit])
    |> maybe_put(:before, opts[:before])
    |> maybe_put(:after, opts[:after])
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: [{key, value} | params]

  defp maybe_put_body(body, _key, value) when value in [nil, []], do: body
  defp maybe_put_body(body, key, value), do: Map.put(body, key, value)

  defp multipart_file_options(file, filename) do
    []
    |> Keyword.put(:filename, filename)
    |> maybe_put(:content_type, Map.get(file, :content_type))
  end

  defp base_url(opts) do
    opts[:url] || Application.get_env(:jido_chat_mattermost, :url) ||
      raise "Mattermost URL not configured. Set opts[:url] or config :jido_chat_mattermost, url: ..."
  end

  defp token(opts) do
    opts[:token] || Application.get_env(:jido_chat_mattermost, :token) ||
      raise "Mattermost token not configured. Set opts[:token] or config :jido_chat_mattermost, token: ..."
  end

  defp auth_headers(opts), do: [{"Authorization", "Bearer #{token(opts)}"}]

  defp post(path, body, opts) do
    url = base_url(opts) <> path

    case Req.post(url, json: body, headers: auth_headers(opts)) do
      {:ok, %{status: status, body: resp_body}} when status in 200..299 -> {:ok, resp_body}
      {:ok, %{status: status, body: resp_body}} -> {:error, {status, resp_body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp post_multipart(path, form, opts) do
    url = base_url(opts) <> path

    case Req.post(url, form_multipart: form, headers: auth_headers(opts)) do
      {:ok, %{status: status, body: resp_body}} when status in 200..299 -> {:ok, resp_body}
      {:ok, %{status: status, body: resp_body}} -> {:error, {status, resp_body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp put(path, body, opts) do
    url = base_url(opts) <> path

    case Req.put(url, json: body, headers: auth_headers(opts)) do
      {:ok, %{status: status, body: resp_body}} when status in 200..299 -> {:ok, resp_body}
      {:ok, %{status: status, body: resp_body}} -> {:error, {status, resp_body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete(path, opts) do
    url = base_url(opts) <> path

    case Req.delete(url, headers: auth_headers(opts)) do
      {:ok, %{status: status, body: resp_body}} when status in 200..299 -> {:ok, resp_body}
      {:ok, %{status: status, body: resp_body}} -> {:error, {status, resp_body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get(path, params, opts) do
    url = base_url(opts) <> path

    case Req.get(url, params: params, headers: auth_headers(opts)) do
      {:ok, %{status: status, body: resp_body}} when status in 200..299 -> {:ok, resp_body}
      {:ok, %{status: status, body: resp_body}} -> {:error, {status, resp_body}}
      {:error, reason} -> {:error, reason}
    end
  end
end
