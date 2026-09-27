#+build windows
package main

// Windows has no ``SIGPIPE``: a write to a closed pipe fails.
ignore_sigpipe :: proc() {}
