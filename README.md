# imapidle
```
Date: Thu, 19 Nov 2026 16:08:24 -0600
Subject: imapidle - a perl daemon that runs mbsync when IMAP mail changes
From: Todd T. Fries <todd@fries.net>
To: anyone reading this
```

I made this because mbsync connects, syncs, and exits. Mail that arrives
after that sits on the server until something runs mbsync again. imapidle
stays logged in and starts mbsync when a mailbox changes.

A few rules it keeps:

- mbsync is the short run. imapidle is the process that stays up.
- An idle section holds one IDLE connection per folder. The server's
  message count is the signal. A higher count schedules that folder.
- Priority is the minimum time between mbsync runs for one folder.
  Priority 1 waits 7 seconds. The default, priority 5, waits 420 seconds.
  Write it as `INBOX;priority=1`. A bare `INBOX;1` stays priority 5.
- Mail that arrives inside that gap is remembered and runs when the gap
  ends. Once the gap has passed, folders on the same channel share a 5
  second window so one mbsync covers them.
- A pulse section sweeps mailboxes that are not held in IDLE, on a timer.
- A folder that stays quiet is still synced when its resync time elapses.
  The default is 12 hours.
- One account failing does not stop the others. A bad password, a dead
  server, or a failed mbsync is logged and retried. The process exits on
  SIGTERM, SIGINT, or a shutdown file under ~/tmp.
- The config is ~/.config/imapidle/imapidle.conf. Runtime state is
  ~/.local/imapidle. imapidlectl talks to ~/var/run/imapidle.sock.
- `-d` stays in the foreground and copies the log to stderr. `-v` adds
  the IDLE keepalive. `-n` loads the config and the state, watches, and
  logs the mbsync it would have run. It does not write state and does
  not run mbsync, so it can sit beside a daemon that does.

```
man imapidle
man imapidle.conf
make test
./imapidle -d
```

Enjoy!

Thanks,

```
--
Todd Fries .. todd@fries.net .. twitter:@unix2mars .. github:toddfries

Label   | Data           | Notes
--------+----------------+------------------------------
Motto   | In support of  | free software solutions.
Phone   | 1.405.252.0702 | SMS/voice everywhere
Mobile  | 1.405.203.6124 | SMS/voice mobile only
Employer| self employed  | Free Daemon Consulting, LLC
Address | PO Box 16169   | Oklahoma City, OK 73113-2169
PGP     | 3F42004A       |
```
