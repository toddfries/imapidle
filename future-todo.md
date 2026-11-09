# future-todo

Parked from imap-idle-notify-session-extraction.md (2026-11-09). The handoff says these stay out until asked. Doing them before the process_notification exit(1) is decided spends the work on a daemon that dies on the first socket event.

- password_cmd or a mode-600 password file. Why: the conf holds the password in plaintext. Saving: one auth path, no second password store to invent mid-debug.
- SIGHUP config reload. Why: today a config change needs a restart. TERM/INT already shut down. Saving: leave the signal map alone until the drain path works.
- Pidfile and an OpenBSD rc.d script. Why: no pidfile yet. Saving: skip rc integration while the process exits 1 on first mail.
- Max concurrent mbsync processes. Why: forks are unlimited. Saving: a semaphore is unused while one event kills the parent.
- After-sync hook (for example notmuch new). Why: the child only execs mbsync. Saving: one less process to supervise.
- Poll fallback for servers without IDLE or NOTIFY. Why: the code already tries NOTIFY, then IDLE. Saving: no third mode until those two run.
- XOAUTH2 / SASL beyond a password. Why: login is user plus password only. Saving: no token flow in this tree.
- Trigger only on EXISTS, ignore flag-only events. Why: every drained line can arm mbsync. Saving: filter after the drain loop is real.
- Log level or debug switch. Why: every line is syslog INFO/WARNING/ERR. Saving: no second logger while the tripwire is the loudest line.
