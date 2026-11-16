# future-todo

These options are not in the program. Each leaf says what that option would do.

## Pidfile

The boot script finds the process by matching the perl command line. It does not read a pid file. This option writes the daemon pid after the handoff and removes that file on shutdown, so another program can signal that process from the number in the file.

## Logging

### Log level

Choose how much a background process writes, without staying in the foreground. Today -d keeps the process in the foreground and copies every line to stderr, and -v adds the IDLE keepalive and the re-arm line. A level would select quiet, normal, or the keepalive noise while the process still daemonizes.
