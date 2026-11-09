# future-todo

Parked from imap-idle-notify-session-extraction.md. Todd asked for a password command and for one failure to stay inside that account. Those two are in imapidle, as pass_cmd and per-account retry. A missing required config key exits 1 before the daemon starts. The rest stays parked until he asks. A live monitor and test wait until he has a config.

- SIGHUP config reload. Why: a config change still needs a restart. TERM and INT already shut down. Saving: leave the signal map alone until a real config is in use.
- Pidfile and an OpenBSD rc.d script. Why: no pidfile yet. Saving: skip rc integration until the foreground run looks right.
- Max concurrent mbsync processes. Why: forks are unlimited. Saving: a semaphore is unused until more than one account is syncing.
- After-sync hook (for example notmuch new). Why: the child only execs mbsync. Saving: one less process to supervise.
- Poll fallback for servers without IDLE or NOTIFY. Why: the code tries NOTIFY, then IDLE. Saving: no third mode until those two have been watched against a real server.
- XOAUTH2 / SASL inside this program. Why: pass_cmd already runs a helper that can print a token. The IMAP login is still a password. Saving: no token exchange in this tree.
- Trigger only on EXISTS, ignore flag-only events. Why: every drained line can arm mbsync. Saving: filter after a live trace shows which lines matter.
- Log level switch beyond -d. Why: -d copies every line to stderr. Saving: no second logger until a real run is noisy.
