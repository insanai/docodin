#+build !windows
package main

import "core:sys/posix"

// Writing to a pipe whose reader exited fails with ``EPIPE`` instead of
// ending the process.
ignore_sigpipe :: proc() {
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
}
