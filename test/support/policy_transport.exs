defmodule Jido.Chat.Mattermost.Test.PolicyTransport do
  @moduledoc false
  @behaviour Jido.Chat.Mattermost.Transport

  def upload_files(_room, files, opts) do
    send(self(), {:upload, Enum.map(files, & &1.filename), opts})

    cond do
      Enum.any?(files, &(&1.filename == "fail.txt")) ->
        {:error, Process.get({__MODULE__, :upload_error}, :upload_rejected)}

      Enum.any?(files, &(&1.filename == "partial.txt")) ->
        {:error,
         {:partial_upload,
          %{
            reason: Process.get({__MODULE__, :upload_error}, :upload_rejected),
            uploaded: %{"file_infos" => [%{"id" => hd(files).filename}]}
          }}}

      true ->
        {:ok, %{"file_infos" => Enum.map(files, &%{"id" => &1.filename, "name" => &1.filename})}}
    end
  end

  def send_message(room, text, opts), do: publish(:send, room, nil, text, opts)
  def edit_message(room, id, text, opts), do: publish(:edit, room, id, text, opts)

  defp publish(action, room, id, text, opts) do
    send(self(), {:publish, action, id, text, opts})
    count = Process.get({__MODULE__, :publications}, 0) + 1
    Process.put({__MODULE__, :publications}, count)

    if Process.get({__MODULE__, :fail_publication}) == count do
      {:error, Process.get({__MODULE__, :publication_error}, :timeout)}
    else
      {:ok, %{"id" => id || "post-#{count}", "channel_id" => room, "file_ids" => opts[:file_ids] || []}}
    end
  end

  for {name, arity} <- [
        download_file: 2,
        delete_message: 3,
        add_reaction: 3,
        remove_reaction: 4,
        fetch_posts: 2,
        fetch_post: 2,
        fetch_thread: 2,
        fetch_channel: 2,
        send_typing: 2,
        get_user: 2,
        open_dm_channel: 3
      ] do
    args = for index <- 1..arity, do: Macro.var(String.to_atom("_arg#{index}"), __MODULE__)
    def unquote(name)(unquote_splicing(args)), do: {:error, :unexpected_call}
  end
end
