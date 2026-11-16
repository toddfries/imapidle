# future-todo

These options are not in the program. Each leaf says what that option would do.

## Pidfile

The boot script finds the process by matching the perl command line. It does not read a pid file. This option writes the daemon pid after the handoff and removes that file on shutdown, so another program can signal that process from the number in the file.

## Logging

### Log level

Choose how much a background process writes, without staying in the foreground. Today -d keeps the process in the foreground and copies every line to stderr, and -v adds the IDLE keepalive and the re-arm line. A level would select quiet, normal, or the keepalive noise while the process still daemonizes.

## Empty mailboxes

The aim is to leave mbsync slots for mailboxes that contain messages. The program asks STATUS (MESSAGES UIDNEXT) on the primary connection and waits the empty interval, one day unless the config sets another value, when the count is zero and UIDNEXT is unchanged. The leaves below are other schedulers for that same aim.

### Token bucket

Each empty mailbox earns one token a day. The refill is smooth, so the empty class cannot spend a day's tokens as one burst after a restart. Mailboxes that contain messages keep the interval formula and the connection cap.

### One empty proof

The first sync that sees zero messages sets that mailbox's wait to a day and marks the row. A mailbox that has messages takes a free slot ahead of a marked row. One new message clears the mark and returns the mailbox to the short interval. The count still comes from running mbsync.

### Minute of the day

Hash each empty mailbox onto one minute of the day, so a restart does not make them all due together. Run one only while no mailbox that has messages is due. A child exit does not wake an empty mailbox while a live one is waiting.

### Two groups

Keep folders that have had mail on a short timer. Put the rest on a daily timer after one empty sync. Spread the daily due times so that group does not start together.
