import gleeunit
import gleeunit/should
import sqlight
import pig/workspace/schema
import pig/workspace/vfs
import gleam/string
import gleam/list

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
    entries
    |> list.contains("data")
    |> should.be_true()
  })
}

pub fn mkdir_already_exists_test() {
  with_db(fn(conn) {
    let assert Ok(Nil) = vfs.mkdir(conn, "/data")
    let assert Error(vfs.AlreadyExists(path: "/data")) = vfs.mkdir(conn, "/data")
  })
}

pub fn write_file_creates_file_test() {
  with_db(fn(conn) {
    let assert Ok(Nil) = vfs.write_file(conn, "/test.txt", "hello")
    let assert Ok(content) = vfs.read_file(conn, "/test.txt")
    content
    |> should.equal("hello")
  })
}

pub fn write_file_overwrites_test() {
  with_db(fn(conn) {
    let assert Ok(Nil) = vfs.write_file(conn, "/test.txt", "hello")
    let assert Ok(Nil) = vfs.write_file(conn, "/test.txt", "world")
    let assert Ok(content) = vfs.read_file(conn, "/test.txt")
    content
    |> should.equal("world")
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
    entries
    |> should.equal(["a.txt", "b.txt"])
  })
}

pub fn list_directory_subdirectory_test() {
  with_db(fn(conn) {
    let assert Ok(Nil) = vfs.mkdir(conn, "/data")
    let assert Ok(Nil) = vfs.write_file(conn, "/data/file.txt", "content")
    let assert Ok(entries) = vfs.list_directory(conn, "/data")
    entries
    |> should.equal(["file.txt"])
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
    let assert Error(vfs.NotEmpty(path: "/data")) = vfs.delete_file(conn, "/data")
  })
}

pub fn read_file_lines_with_offset_limit_test() {
  with_db(fn(conn) {
    let content = "line0\nline1\nline2\nline3\nline4"
    let assert Ok(Nil) = vfs.write_file(conn, "/test.txt", content)
    let assert Ok(lines) = vfs.read_file_lines(conn, "/test.txt", 1, 2)
    lines
    |> should.equal("1\tline1\n2\tline2")
  })
}

pub fn write_file_large_content_test() {
  with_db(fn(conn) {
    // Create content larger than 4096 bytes
    let large_content = string.repeat("A", 5000)
    let assert Ok(Nil) = vfs.write_file(conn, "/large.txt", large_content)
    let assert Ok(read_back) = vfs.read_file(conn, "/large.txt")
    read_back
    |> should.equal(large_content)
  })
}

pub fn write_file_in_subdirectory_test() {
  with_db(fn(conn) {
    let assert Ok(Nil) = vfs.mkdir(conn, "/data")
    let assert Ok(Nil) = vfs.write_file(conn, "/data/test.txt", "hello")
    let assert Ok(content) = vfs.read_file(conn, "/data/test.txt")
    content
    |> should.equal("hello")
  })
}

pub fn mkdir_nested_test() {
  with_db(fn(conn) {
    let assert Ok(Nil) = vfs.mkdir(conn, "/a")
    let assert Ok(Nil) = vfs.mkdir(conn, "/a/b")
    let assert Ok(Nil) = vfs.write_file(conn, "/a/b/file.txt", "nested")
    let assert Ok(content) = vfs.read_file(conn, "/a/b/file.txt")
    content
    |> should.equal("nested")
  })
}
