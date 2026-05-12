import gleam/list
import gleam/string
import gleeunit
import pig/workspace/schema
import pig/workspace/vfs
import sqlight

pub fn main() {
  gleeunit.main()
}

fn with_db(f: fn(sqlight.Connection) -> a) -> a {
  let assert Ok(conn) = sqlight.open(":memory:")
  let assert Ok(Nil) = schema.init(conn)
  let result = f(conn)
  let assert Ok(Nil) = sqlight.close(conn)
  result
}

pub fn mkdir_creates_directory_test() {
  with_db(fn(conn) {
    let assert Ok(Nil) = vfs.mkdir(conn, "/data")
    let assert Ok(entries) = vfs.list_directory(conn, "/")
    assert list.contains(entries, "data")
  })
}

pub fn mkdir_already_exists_test() {
  with_db(fn(conn) {
    let assert Ok(Nil) = vfs.mkdir(conn, "/data")
    let assert Error(vfs.AlreadyExists(path: "/data")) =
      vfs.mkdir(conn, "/data")
  })
}

pub fn write_file_creates_file_test() {
  with_db(fn(conn) {
    let assert Ok(Nil) = vfs.write_file(conn, "/test.txt", "hello")
    let assert Ok(content) = vfs.read_file(conn, "/test.txt")
    assert content == "hello"
  })
}

pub fn write_file_overwrites_test() {
  with_db(fn(conn) {
    let assert Ok(Nil) = vfs.write_file(conn, "/test.txt", "hello")
    let assert Ok(Nil) = vfs.write_file(conn, "/test.txt", "world")
    let assert Ok(content) = vfs.read_file(conn, "/test.txt")
    assert content == "world"
  })
}

pub fn read_file_missing_returns_error_test() {
  with_db(fn(conn) {
    let assert Error(vfs.NotFound(path: "/nonexistent.txt")) =
      vfs.read_file(conn, "/nonexistent.txt")
  })
}

pub fn list_directory_returns_entries_test() {
  with_db(fn(conn) {
    let assert Ok(Nil) = vfs.write_file(conn, "/a.txt", "a")
    let assert Ok(Nil) = vfs.write_file(conn, "/b.txt", "b")
    let assert Ok(entries) = vfs.list_directory(conn, "/")
    assert entries == ["a.txt", "b.txt"]
  })
}

pub fn list_directory_subdirectory_test() {
  with_db(fn(conn) {
    let assert Ok(Nil) = vfs.mkdir(conn, "/data")
    let assert Ok(Nil) = vfs.write_file(conn, "/data/file.txt", "content")
    let assert Ok(entries) = vfs.list_directory(conn, "/data")
    assert entries == ["file.txt"]
  })
}

pub fn delete_file_removes_file_test() {
  with_db(fn(conn) {
    let assert Ok(Nil) = vfs.write_file(conn, "/test.txt", "hello")
    let assert Ok(Nil) = vfs.delete_file(conn, "/test.txt")
    let assert Error(vfs.NotFound(path: _)) = vfs.read_file(conn, "/test.txt")
  })
}

pub fn delete_file_missing_returns_error_test() {
  with_db(fn(conn) {
    let assert Error(vfs.NotFound(path: "/nonexistent.txt")) =
      vfs.delete_file(conn, "/nonexistent.txt")
  })
}

pub fn delete_nonempty_directory_returns_error_test() {
  with_db(fn(conn) {
    let assert Ok(Nil) = vfs.mkdir(conn, "/data")
    let assert Ok(Nil) = vfs.write_file(conn, "/data/file.txt", "content")
    let assert Error(vfs.NotEmpty(path: "/data")) =
      vfs.delete_file(conn, "/data")
  })
}

pub fn read_file_lines_with_offset_limit_test() {
  with_db(fn(conn) {
    let content = "line0\nline1\nline2\nline3\nline4"
    let assert Ok(Nil) = vfs.write_file(conn, "/test.txt", content)
    let assert Ok(lines) = vfs.read_file_lines(conn, "/test.txt", 1, 2)
    assert lines == "1\tline1\n2\tline2"
  })
}

pub fn write_file_large_content_test() {
  with_db(fn(conn) {
    // Create content larger than 4096 bytes
    let large_content = string.repeat("A", 5000)
    let assert Ok(Nil) = vfs.write_file(conn, "/large.txt", large_content)
    let assert Ok(read_back) = vfs.read_file(conn, "/large.txt")
    assert read_back == large_content
  })
}

pub fn write_file_in_subdirectory_test() {
  with_db(fn(conn) {
    let assert Ok(Nil) = vfs.mkdir(conn, "/data")
    let assert Ok(Nil) = vfs.write_file(conn, "/data/test.txt", "hello")
    let assert Ok(content) = vfs.read_file(conn, "/data/test.txt")
    assert content == "hello"
  })
}

pub fn mkdir_nested_test() {
  with_db(fn(conn) {
    let assert Ok(Nil) = vfs.mkdir(conn, "/a")
    let assert Ok(Nil) = vfs.mkdir(conn, "/a/b")
    let assert Ok(Nil) = vfs.write_file(conn, "/a/b/file.txt", "nested")
    let assert Ok(content) = vfs.read_file(conn, "/a/b/file.txt")
    assert content == "nested"
  })
}

// ── grep tests ───────────────────────────────────────────────────────

pub fn grep_returns_matching_lines_test() {
  with_db(fn(conn) {
    let assert Ok(Nil) =
      vfs.write_file(conn, "/hello.txt", "hello world\nfoo bar\nhello again")
    let assert Ok(matches) = vfs.grep(conn, "hello", "", "", 0)
    assert matches == [
      vfs.GrepMatch(path: "/hello.txt", line_number: 0, line: "hello world"),
      vfs.GrepMatch(path: "/hello.txt", line_number: 2, line: "hello again"),
    ]
  })
}

pub fn grep_across_multiple_files_test() {
  with_db(fn(conn) {
    let assert Ok(Nil) = vfs.write_file(conn, "/a.txt", "findme here")
    let assert Ok(Nil) = vfs.write_file(conn, "/b.txt", "nope\nfindme too")
    let assert Ok(matches) = vfs.grep(conn, "findme", "", "", 0)
    assert matches == [
      vfs.GrepMatch(path: "/a.txt", line_number: 0, line: "findme here"),
      vfs.GrepMatch(path: "/b.txt", line_number: 1, line: "findme too"),
    ]
  })
}

pub fn grep_with_include_filter_test() {
  with_db(fn(conn) {
    let assert Ok(Nil) = vfs.write_file(conn, "/a.txt", "findme")
    let assert Ok(Nil) = vfs.write_file(conn, "/b.py", "findme")
    let assert Ok(matches) = vfs.grep(conn, "findme", "", "*.py", 0)
    assert matches == [
      vfs.GrepMatch(path: "/b.py", line_number: 0, line: "findme"),
    ]
  })
}

pub fn grep_with_path_filter_test() {
  with_db(fn(conn) {
    let assert Ok(Nil) = vfs.mkdir(conn, "/src")
    let assert Ok(Nil) = vfs.write_file(conn, "/src/app.gleam", "findme")
    let assert Ok(Nil) = vfs.write_file(conn, "/test.gleam", "findme")
    let assert Ok(matches) = vfs.grep(conn, "findme", "/src", "", 0)
    assert matches == [
      vfs.GrepMatch(path: "/src/app.gleam", line_number: 0, line: "findme"),
    ]
  })
}

pub fn grep_with_max_results_test() {
  with_db(fn(conn) {
    let assert Ok(Nil) =
      vfs.write_file(conn, "/big.txt", "match1\nmatch2\nmatch3\nmatch4")
    let assert Ok(matches) = vfs.grep(conn, "match", "", "", 2)
    assert list.length(matches) == 2
  })
}

pub fn grep_no_matches_returns_empty_test() {
  with_db(fn(conn) {
    let assert Ok(Nil) = vfs.write_file(conn, "/a.txt", "hello world")
    let assert Ok(matches) = vfs.grep(conn, "nonexistent", "", "", 0)
    assert matches == []
  })
}

pub fn grep_empty_dir_returns_empty_test() {
  with_db(fn(conn) {
    let assert Ok(Nil) = vfs.mkdir(conn, "/empty")
    let assert Ok(matches) = vfs.grep(conn, "anything", "/empty", "", 0)
    assert matches == []
  })
}
