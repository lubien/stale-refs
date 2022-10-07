defmodule StaleRefsTest do
  use ExUnit.Case
  doctest StaleRefs

  test "find_repos_in_files/1" do
    filenames = Path.wildcard("test/fixtures/*.md")

    assert StaleRefs.find_repos_in_files(filenames) == [
      "https://github.com/lubien/elixir-telegram-bot-boilerplate",
      "https://github.com/lubien/bookmarker"
    ]
  end

  test "find_repos_in_text/1" do
    assert StaleRefs.find_repos_in_text("""
    gibberish lorem ipsum dolor https://github.com/lubien/bookmarker
    not a repo http://github.io/foo/bar
    [we have this https://github.com/lubien/elixir-telegram-bot-boilerplate](https://github.com/lubien/elixir-telegram-bot-boilerplate)
    """) == [
      "https://github.com/lubien/bookmarker",
      "https://github.com/lubien/elixir-telegram-bot-boilerplate",
      "https://github.com/lubien/elixir-telegram-bot-boilerplate"
    ]
  end

  test "too_old?/2" do
    now = ~U[2022-10-07 20:08:25.703586Z]
    refute StaleRefs.too_old?(now, ~U[2022-10-07 19:16:08Z])
    refute StaleRefs.too_old?(now, ~U[2021-10-07 19:16:08Z])
    assert StaleRefs.too_old?(now, ~U[2021-04-07 19:16:08Z])
    assert StaleRefs.too_old?(now, ~U[2020-04-07 19:16:08Z])
  end
end
