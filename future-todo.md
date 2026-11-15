# future-todo

Parked from imap-idle-notify-session-extraction.md. Todd asked for a password command and for one failure to stay inside that account. Those two are in imapidle, as pass_cmd and per-account retry. A missing required config key exits 1 before the daemon starts. SIGHUP re-reads the config. The rest stays parked until he asks.

- Pidfile and an OpenBSD rc.d script. Why: no pidfile yet. Saving: skip rc integration until the foreground run looks right.
- Max concurrent mbsync processes. Why: forks are unlimited. Saving: a semaphore is unused until more than one account is syncing.
- After-sync hook (for example notmuch new). Why: the child only execs mbsync. Saving: one less process to supervise.
- Poll fallback for servers without IDLE or NOTIFY. Why: the code tries NOTIFY, then IDLE. Saving: no third mode until those two have been watched against a real server.
- Trigger only on EXISTS, ignore flag-only events. Why: every drained line can arm mbsync. Saving: filter after a live trace shows which lines matter.
- Log level switch beyond -d. Why: -d copies every line to stderr. Saving: no second logger until a real run is noisy.

Parked 2026-11-14 when the STATUS probe was chosen. The aim is to stop spending mbsync on mailboxes that contain no messages, so mailboxes that have messages can use the slots. The probe that shipped asks STATUS (MESSAGES UIDNEXT) on the primary connection and waits a day when the count is zero.

- Token bucket per class. Why: the empty class gets one token per mailbox per day, refilled smoothly, and cannot spend them as a burst. Mailboxes with messages keep the interval formula and the connection cap. Saving: a budget is more machinery than a due time.
- One empty proof, then a day, and a live mailbox wins the slot. Why: a priority bit on the row, not a second list. The first zero-message sync sets the wait, and one new message returns it to the short interval. Saving: it still runs mbsync to learn the count.
- Hash empty mailboxes onto a minute of the day and run them only while nothing with mail is due. Why: a restart does not line them up, and a child exit does not wake an empty mailbox while a live one is waiting. Saving: that is a scheduler of its own.
- Two groups, the Outlook send/receive shape and a per-channel mbsync timer. Why: active folders stay on a short timer and everything else is daily, with membership after one empty sync. Saving: the daily group herds unless the due times are spread.
