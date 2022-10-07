defmodule StaleRefs do
  @moduledoc """
  Documentation for `StaleRefs`.
  """

  require Logger

  @url_regex ~r/https?:\/\/(www\.)?[-a-zA-Z0-9@:%._\+~#=]{2,256}\.[a-z]{2,6}\b([-a-zA-Z0-9@:%_\+.~#?&\/\/=]*)/

  def main(args) do
    {_, filenames, _} =
      args
      |> OptionParser.parse(strict: [])


      repos = find_repos_in_files(filenames)
    with {:ok, outdated_repos} <- request_repos_in_chunks(repos) do
      groups =
        outdated_repos
        |> Enum.group_by(fn
          {:ok, repo} ->
            if too_old?(repo.updated_at) do
              :stale
            else
              :fresh
            end


          {bad_status, _repo} ->
            bad_status
        end)

      stale_piece =
        for {_, stale} <- (groups[:stale] || []) do
          "#{stale.updated_at} https://github.com/#{stale.owner}/#{stale.name}"
        end
        |> Enum.join("\n")

      IO.puts("""
      Results
      Fresh count: #{Enum.count(groups[:fresh] || [])}
      Stale count: #{Enum.count(groups[:stale] || [])}
      Not found: #{Enum.count(groups[:not_found] || [])}
      Unknown errors: #{Enum.count(groups[:unknown] || [])}

      #{stale_piece}
      """)
    else
      {:bad_body, body} ->
        IO.puts("""
        Bad body from GitHub response:

        #{inspect(body)}
        """)

      error ->
        IO.puts("""
        Something wrong

        #{inspect(error)}
        """)
    end
  end

  def find_repos_in_files(filenames) do
    filenames
    |> Enum.flat_map(fn path ->
      path
      |> File.read()
      |> elem(1)
      |> find_repos_in_text()
    end)
    |> Enum.dedup()
    |> Enum.map(&github_link_to_repo/1)
  end

  def find_repos_in_text(text) do
    Regex.scan(@url_regex, text)
    |> Stream.map(&hd(&1))
    |> Stream.filter(&is_github_link/1)
    |> Enum.reject(& github_link_to_repo(&1) == :invalid_repo)
  end

  def is_github_link("https://github.com/" <> _), do: true
  def is_github_link(_), do: false

  def github_link_to_repo(url) do
    %URI{path: "/" <> path} = URI.parse(url)

    case String.split(path, "/") do
      [owner, name] ->
        %{owner: owner, name: name}

      _ ->
        :invalid_repo
    end
  end

  def request_repos_in_chunks(repos) do
    mapped_repos =
      repos
      |> Enum.with_index()
      |> Enum.map(fn {val, key} -> {key, val} end)

    mapped_repos
    |> Enum.chunk_every(100)
    # TODO: handle individual errors
    |> Enum.map(&request_repos/1)
    |> Enum.reduce(%{}, &Map.merge/2)
    |> apply_github_data_to_repos(mapped_repos)
  end

  def request_repos(mapped_repos) do
    query = generate_graphql_query_for_repos(mapped_repos)
    headers = ["Authorization": "bearer #{System.get_env("GITHUB_TOKEN")}"]

    with {:ok, body} <- Jason.encode(%{"query" => query}),
         {:ok, response} <- HTTPoison.post("https://api.github.com/graphql", body, headers, recv_timeout: 30_000),
         {:ok, decoded} <- Jason.decode(response.body) do
      case decoded do
        %{"data" => data} when is_map(data) ->
          # TODO: handle error
          data

        body ->
          {:bad_body, body}
      end
    end
  end

  def apply_github_data_to_repos(data, mapped_repos) do
    entries =
      mapped_repos
      |> Enum.map(fn {key, repo} ->
        with {:ok, entry} <- get_repo_from_github_response(data, key),
             {:ok, raw_updated_at} <- get_latest_update(entry),
             {:ok, updated_at, _offset} = DateTime.from_iso8601(raw_updated_at) do
             {:ok, Map.put(repo, :updated_at, updated_at)}
          else
            {:error, :not_found} ->
              {:not_found, repo}

            _ ->
              {:unknown, repo}
        end

      end)

    {:ok, entries}
  end

  def get_repo_from_github_response(data, key) do
    if repo = data["item_#{key}"] do
      {:ok, repo}
    else
      {:error, :not_found}
    end
  end

  def get_latest_update(%{
    "defaultBranchRef" => %{
      "target" => %{
        "history" => %{
          "nodes" => [
            %{
              "authoredDate" => updated,
            }
          ]
        }
      }
    },
  }) do
    {:ok, updated}
  end
  def get_latest_update(_), do: :invalid_format

  def generate_graphql_query_for_repos(mapped_repos) do
    inner_query =
      mapped_repos
      |> Enum.map(fn {key, %{owner: owner, name: name}} ->
        """
          item_#{key}: repository(owner:"#{owner}", name:"#{name}") {
            defaultBranchRef {
              target {
                ... on Commit {
                  history(first: 1) {
                    nodes {
                      authoredDate
                    }
                  }
                }
              }
            }
          }
        """
      end)
      |> Enum.join("\n")

    """
    query {
      #{inner_query}

      rateLimit {
        limit
        cost
        remaining
        resetAt
      }
    }
    """
  end

  # def request_github_api()

  def too_old?(now \\ DateTime.utc_now(), date) do
    one_year_and_a_half = 60 * 60 * 24 * 365 * 1.5
    DateTime.diff(now, date) > one_year_and_a_half
  end
end
