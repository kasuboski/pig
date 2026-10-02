# Accept only the user-approved Mist/Gramps Header deprecations; retain diagnostics.
function unfinished_warning() {
  if (pending) {
    print "UNACCEPTED incomplete warning at " origin
    failed = 1
  }
  pending = location = header = 0
}

FNR == 1 { unfinished_warning() }

{
  lower = tolower($0)
  if (lower ~ /warning:|warning treated as error/) {
    unfinished_warning()
    if ($0 == "warning: Deprecated type used") {
      pending = 1
      origin = FILENAME ":" FNR
    } else {
      print "UNACCEPTED " FILENAME ":" FNR ": " $0
      failed = 1
    }
    next
  }

  if (pending) {
    if ($0 ~ /\/build\/packages\/(gramps\/src\/gramps\/http|mist\/src\/mist\/internal\/(encoder|http2|http2\/stream))\.gleam:[0-9]+:[0-9]+$/) {
      location = 1
    }
    if ($0 ~ /List\(Header\)/) header = 1
    if ($0 == "It was deprecated with this message: Use #(String, String) instead") {
      if (location && header) {
        print "ACCEPTED third-party Header deprecation at " origin
        accepted++
      } else {
        print "UNACCEPTED deprecation at " origin
        failed = 1
      }
      pending = location = header = 0
    }
  } else if (lower ~ /deprecated/) {
    print "UNACCEPTED " FILENAME ":" FNR ": " $0
    failed = 1
  }
}

END {
  unfinished_warning()
  printf "%d known third-party warning occurrences accepted; unexpected warnings: %s\n", accepted, failed ? "yes" : "no"
  exit failed
}
