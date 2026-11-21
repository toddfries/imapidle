# Copyright (c) 2026 Todd T. Fries <todd@fries.net>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

# One parent supervises. The hub owns mailbox state. Each idle worker
# is a sibling of the hub and has one socketpair to the hub.
# demonstrate() passes one kernel fd and exits with that worker.
# serve() is imapidle -n: the worker opens its own mailbox, and a
# sync the hub would have started is a timer in the hub.

package IMAPIDLE::Split;

use strict;
use warnings;

use Errno qw(ECHILD EINTR);
use IO::Select ();
use JSON::PP ();
use OpenBSD::Pledge ();
use POSIX qw(_exit WNOHANG);
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use Time::HiRes qw(time);

use IMAPIDLE ();
use IMAPIDLE::Imsg;

our $ACTIVE = 0;
our $IS_CHILD = 0;
our $HUB;
our $IDLE;
our $PARENT_FH;
our %WORKER_PID;

# Live hub: mbsync and state live here. -n leaves this off.
my $REAL = 0;
my %FLIGHT;

END {
	return if !$ACTIVE || $IS_CHILD;
	kill 'TERM', $HUB if $HUB;
	kill 'TERM', $IDLE if $IDLE;
	kill 'TERM', grep { $_ } values %WORKER_PID;
}

sub demonstrate {
	my ($report) = @_;
	local $SIG{ALRM} = sub { die "imsg split timed out\n" };
	alarm 8;
	$ACTIVE = 1;
	IMAPIDLE::Imsg::set_title('imapidle: parent');
	_autoflush($report);
	print $report "ready\n";
	my $go = <$report>;
	die "split did not start\n" unless defined $go && $go =~ /^go/;

	OpenBSD::Pledge::pledge(qw(stdio proc sendfd recvfd unveil))
	    or die "parent pledge: $!\n";

	my ($to_hub, $to_parent) = _spair();
	$HUB = fork();
	die "fork hub: $!\n" unless defined $HUB;
	if ($HUB == 0) {
		$IS_CHILD = 1;
		$ACTIVE = 0;
		close $report;
		close $to_hub;
		eval { _hub($to_parent) };
		warn $@ if $@;
		_exit($@ ? 1 : 0);
	}
	close $to_parent;

	my $ctl = IMAPIDLE::Imsg->open(fileno($to_hub));
	my ($hub_end, $idle_end) = _spair();
	$ctl->send_fd(IMAPIDLE::IMSG_ATTACH,
	    IMAPIDLE::json_encode({ peer => 'idle' }), fileno($hub_end));
	close $hub_end;
	my $ack = $ctl->recv;
	die "hub did not ack idle\n"
	    unless $ack && $ack->{type} == IMAPIDLE::IMSG_ACK;

	my ($mail_p, $mail_c) = _spair();
	$IDLE = fork();
	die "fork idle: $!\n" unless defined $IDLE;
	if ($IDLE == 0) {
		$IS_CHILD = 1;
		$ACTIVE = 0;
		close $report;
		close $to_hub;
		close $mail_p;
		eval { _idle($idle_end) };
		warn $@ if $@;
		_exit($@ ? 1 : 0);
	}
	close $idle_end;

	$ctl->send_fd(IMAPIDLE::IMSG_SOCKET,
	    IMAPIDLE::json_encode({
		account => 'fdc-main',
		folder  => 'INBOX',
	    }), fileno($mail_c));
	close $mail_c;
	syswrite($mail_p, 'ping') == 4 or die "ping: $!\n";
	close $mail_p;

	my $mail = $ctl->recv;
	die "hub sent no mailbox count\n" unless $mail;
	die "mail type\n" unless $mail->{type} == IMAPIDLE::IMSG_MAIL;
	my $row = IMAPIDLE::json_decode($mail->{data});
	die "mail row\n" unless $row
	    && $row->{account} eq 'fdc-main'
	    && $row->{folder} eq 'INBOX'
	    && $row->{total} == 3
	    && $row->{saw} eq 'ping';

	$ctl->send(IMAPIDLE::IMSG_SHUTDOWN, '');
	_wait_child($HUB, 'hub');
	_wait_child($IDLE, 'idle');
	$HUB = undef;
	$IDLE = undef;
	$ACTIVE = 0;
	print $report "imsg ok account=$row->{account} "
	    . "folder=$row->{folder} total=$row->{total} saw=$row->{saw}\n";
	close $report;
	alarm 0;
	return;
}

sub _hub {
	my ($up_fh) = @_;
	IMAPIDLE::Imsg::set_title('imapidle: hub');
	my $up = IMAPIDLE::Imsg->open(fileno($up_fh));
	OpenBSD::Pledge::pledge(qw(stdio sendfd recvfd))
	    or die "hub pledge: $!\n";
	my $down;
	my $down_fh;
	my $sel = IO::Select->new($up_fh);
	while (1) {
		for my $msg (_take($up)) {
			if ($msg->{type} == IMAPIDLE::IMSG_ATTACH) {
				my $info = IMAPIDLE::json_decode($msg->{data});
				die "attach peer\n"
				    unless $info && $info->{peer} eq 'idle';
				die "attach fd\n"
				    if !defined $msg->{fd} || $msg->{fd} < 0;
				open $down_fh, '+<&=', $msg->{fd}
				    or die "idle fd: $!\n";
				$down = IMAPIDLE::Imsg->open(fileno($down_fh));
				$sel->add($down_fh);
				$up->send(IMAPIDLE::IMSG_ACK, 'idle');
			} elsif ($msg->{type} == IMAPIDLE::IMSG_SOCKET) {
				die "socket before idle\n" unless $down;
				die "socket fd\n"
				    if !defined $msg->{fd} || $msg->{fd} < 0;
				$down->send_fd(IMAPIDLE::IMSG_SOCKET,
				    $msg->{data}, $msg->{fd});
				POSIX::close($msg->{fd});
			} elsif ($msg->{type} == IMAPIDLE::IMSG_SHUTDOWN) {
				$down->send(IMAPIDLE::IMSG_SHUTDOWN, '') if $down;
				return;
			} else {
				die "parent message $msg->{type}\n";
			}
		}
		if ($down) {
			for my $msg (_take($down)) {
				die "idle message $msg->{type}\n"
				    unless $msg->{type} == IMAPIDLE::IMSG_MAIL;
				$up->send(IMAPIDLE::IMSG_MAIL, $msg->{data});
			}
		}
		my @ready = $sel->can_read(2);
		for my $fh (@ready) {
			my $ib = ($down_fh && fileno($fh) == fileno($down_fh))
			    ? $down : $up;
			my $n = $ib->read_more;
			die "imsgbuf_read: $!\n" if !defined $n || $n < 0;
			die "imsg closed\n" if $n == 0;
		}
	}
}

sub _idle {
	my ($sock) = @_;
	IMAPIDLE::Imsg::set_title('imapidle: idle');
	my $ib = IMAPIDLE::Imsg->open(fileno($sock));
	OpenBSD::Pledge::pledge(qw(stdio recvfd))
	    or die "idle pledge: $!\n";
	my $msg = $ib->recv;
	die "missing mailbox fd\n" unless $msg
	    && $msg->{type} == IMAPIDLE::IMSG_SOCKET
	    && defined $msg->{fd} && $msg->{fd} >= 0;
	my $info = IMAPIDLE::json_decode($msg->{data});
	die "socket account\n" unless $info
	    && $info->{account} eq 'fdc-main'
	    && $info->{folder} eq 'INBOX';
	OpenBSD::Pledge::pledge('stdio')
	    or die "idle pledge stdio: $!\n";
	open my $fh, '+<&=', $msg->{fd} or die "mailbox fd: $!\n";
	my $buf = '';
	while (length($buf) < 4) {
		my $n = sysread($fh, $buf, 4 - length($buf), length($buf));
		die "mailbox read: $!\n" if !defined $n;
		die "mailbox closed\n" if $n == 0;
	}
	die "mailbox bytes\n" unless $buf eq 'ping';
	$ib->send(IMAPIDLE::IMSG_MAIL, IMAPIDLE::json_encode({
		account => $info->{account},
		folder  => $info->{folder},
		total   => 3,
		saw     => 'ping',
	}));
	my $end = $ib->recv;
	die "idle shutdown\n" unless $end
	    && $end->{type} == IMAPIDLE::IMSG_SHUTDOWN;
	return;
}

sub _take {
	my ($ib) = @_;
	return $ib->queued;
}

sub _wait_child {
	my ($pid, $name) = @_;
	my $got = waitpid($pid, 0);
	die "wait $name: $!\n" if $got < 0;
	die "$name exited $?\n" if $?;
	return;
}

sub _spair {
	socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
	    or die "socketpair: $!\n";
	_autoflush($a);
	_autoflush($b);
	return ($a, $b);
}

sub _autoflush {
	my ($fh) = @_;
	my $old = select($fh);
	$| = 1;
	select($old);
	return;
}

# imapidle -n. The hub loads config and state. This process only
# supervises. A dead hub ends the parent.
sub serve_live {
	my ($config, $foreground) = @_;
	$REAL = 1;
	return serve($config, $foreground);
}

sub serve {
	my ($config, $foreground) = @_;
	die "dry config\n" if !defined $config || $config eq '';
	$ACTIVE = 1;
	main::daemonize() if !$foreground;
	IMAPIDLE::Imsg::set_title('imapidle: parent');
	# mbsync is exec'd by the live hub and keeps this pledge.
	# -n never execs it, so that parent can be narrowed.
	if (!$REAL) {
		OpenBSD::Pledge::pledge(
		    qw(stdio proc exec rpath sendfd recvfd inet dns unix unveil))
		    or die "parent pledge: $!\n";
	}

	my ($to_hub, $to_parent) = _spair();
	$HUB = fork();
	die "fork hub: $!\n" unless defined $HUB;
	if ($HUB == 0) {
		$IS_CHILD = 1;
		$ACTIVE = 0;
		close $to_hub;
		eval {
			if ($REAL) {
				_live_hub($to_parent, $config);
			} else {
				_dry_hub($to_parent, $config);
			}
		};
		if ($@) {
			my $err = main::scrub($@);
			$err = 'hub failed' if $err eq '';
			eval { main::log_error("hub: $err") };
			warn "imapidle: hub: $err\n";
			_exit(1);
		}
		_exit(0);
	}
	close $to_parent;
	$PARENT_FH = $to_hub;
	_parent_loop($to_hub);
}

sub _parent_loop {
	my ($hub_fh) = @_;
	my $ctl = IMAPIDLE::Imsg->open(fileno($hub_fh));
	my $sel = IO::Select->new($hub_fh);
	my $stop = 0;
	my $stopped = 0;
	my $hub_dead = 0;
	my $hub_status = 0;
	local $SIG{TERM} = sub { $stop = 1 };
	local $SIG{INT}  = sub { $stop = 1 };
	local $SIG{HUP}  = $REAL
	    ? sub { kill 'HUP', $HUB if defined $HUB && $HUB }
	    : 'IGNORE';
	local $SIG{PIPE} = 'IGNORE';
	while (!$hub_dead) {
		_reap(\$hub_dead, \$hub_status);
		if ($stop && !$stopped) {
			eval { $ctl->send(IMAPIDLE::IMSG_SHUTDOWN, '') };
			$stopped = 1;
		}
		my @ready = $sel->can_read(1);
		if (@ready) {
			my $n = $ctl->read_more;
			if (!defined $n || $n < 0) {
				next if $!{EINTR};
				$hub_dead = 1;
				next;
			}
			$hub_dead = 1 if $n == 0;
		}
		# A later SPAWN can arrive while this process waits for the
		# ack. Leave those on @later or the ack wait treats them
		# as the reply and the parent exits.
		my @later;
		for my $msg ($ctl->queued) {
			next unless $msg->{type} == IMAPIDLE::IMSG_SPAWN;
			push @later, $msg;
		}
		while (my $msg = shift @later) {
			my $row = IMAPIDLE::json_decode($msg->{data}) // {};
			eval { _spawn_worker($ctl, $row, \@later) };
			next unless $@;
			my $err = main::scrub($@);
			$err = 'parent failed' if $err eq '';
			eval { main::log_error("parent: $err") };
			warn "imapidle: parent: $err\n";
			_finish(1);
		}
	}
	# A live hub that exits 0 asked to stop (control socket or the
	# shutdown file). -n still requires the parent's own signal.
	my $clean = ($hub_status == 0) && ($stopped || $REAL);
	my $code = $clean ? 0 : 1;
	_finish($code);
}

sub _reap {
	my ($dead, $status) = @_;
	while (1) {
		my $pid = waitpid(-1, WNOHANG);
		last if !defined $pid || $pid <= 0;
		if (defined $HUB && $pid == $HUB) {
			$$dead = 1;
			$$status = $?;
			$HUB = undef;
			next;
		}
		for my $id (keys %WORKER_PID) {
			delete $WORKER_PID{$id} if $WORKER_PID{$id} == $pid;
		}
	}
	return;
}

sub _spawn_worker {
	my ($ctl, $row, $later) = @_;
	my $id = $row->{id} // '';
	die "spawn id\n" if $id eq '';
	my ($hub_end, $worker_end) = _spair();
	my $peer = ($row->{peer} // '') eq 'account' ? 'account' : 'idle';
	$ctl->send_fd(IMAPIDLE::IMSG_ATTACH, IMAPIDLE::json_encode({
		id   => $id,
		peer => $peer,
	}), fileno($hub_end));
	close $hub_end;
	my $ack;
	while (1) {
		$ack = _recv_eintr($ctl);
		last unless $ack && $ack->{type} == IMAPIDLE::IMSG_SPAWN;
		push @$later, $ack;
	}
	die "hub did not ack\n"
	    unless $ack && $ack->{type} == IMAPIDLE::IMSG_ACK;
	my $pid = fork();
	die "fork idle: $!\n" unless defined $pid;
	if ($pid == 0) {
		$IS_CHILD = 1;
		$ACTIVE = 0;
		# Forked after the parent's stop handler. A default TERM
		# is what the hub's restart path waits on.
		$SIG{TERM} = $SIG{INT} = $SIG{HUP} = $SIG{CHLD} = 'DEFAULT';
		close $PARENT_FH if $PARENT_FH;
		eval {
			if ($peer eq 'account') {
				require IMAPIDLE::Account;
				IMAPIDLE::Account::run($worker_end);
			} else {
				require IMAPIDLE::Idle;
				IMAPIDLE::Idle::run($worker_end);
			}
		};
		if ($@) {
			my $err = main::scrub($@);
			$err = 'worker failed' if $err eq '';
			eval { main::log_error("$peer: $err") };
			warn "imapidle: $peer: $err\n";
			_exit(1);
		}
		_exit(0);
	}
	close $worker_end;
	$WORKER_PID{$id} = $pid;
	return;
}

sub _recv_eintr {
	my ($ib) = @_;
	while (1) {
		my $msg = $ib->get;
		return $msg if $msg;
		my $r = $ib->read_more;
		return undef if defined $r && $r == 0;
		if (!defined $r || $r < 0) {
			next if $!{EINTR};
			die "imsgbuf_read: $!\n";
		}
	}
}

sub _finish {
	my ($code) = @_;
	for my $pid (grep { $_ } values %WORKER_PID) {
		kill 'TERM', $pid;
	}
	my $until = time() + 2;
	while (time() < $until) {
		my $pid = waitpid(-1, WNOHANG);
		last if !defined $pid || $pid < 0;
		select(undef, undef, undef, 0.05) if $pid == 0;
	}
	%WORKER_PID = ();
	$HUB = undef;
	$ACTIVE = 0;
	exit $code;
}

sub _dry_hub {
	my ($up_fh, $config) = @_;
	$SIG{TERM} = $SIG{INT} = $SIG{HUP} = $SIG{CHLD} = 'DEFAULT';
	IMAPIDLE::Imsg::set_title('imapidle: hub');
	my $err = main::load_config($config);
	if ($err) {
		main::log_error($err);
		die "$err\n";
	}
	main::open_state_dir();
	OpenBSD::Pledge::pledge(
	    qw(stdio rpath sendfd recvfd proc exec unix inet dns))
	    or die "hub pledge: $!\n";

	my $up = IMAPIDLE::Imsg->open(fileno($up_fh));
	my $sel = IO::Select->new($up_fh);
	my %fd_job;
	my %jobs = _dry_jobs();
	my $quit = 0;
	_dry_summary(\%jobs);
	while (!$quit) {
		$quit = _dry_drain($up, \%jobs, $sel, \%fd_job);
		last if $quit;
		my $now = time();
		_dry_finish($now, \%jobs);
		_dry_spawn($up, $now, \%jobs);
		_dry_start($now, \%jobs);
		my @ready = $sel->can_read(_dry_wake($now, \%jobs));
		for my $fh (@ready) {
			$quit = _dry_read($fh, $up_fh, $up, \%jobs, \%fd_job, $sel);
			last if $quit;
		}
	}
	for my $job (values %jobs) {
		next unless $job->{ib};
		eval { $job->{ib}->send(IMAPIDLE::IMSG_SHUTDOWN, '') };
	}
	return;
}

sub _dry_jobs {
	my %jobs;
	my $now = time();
	for my $name (main::account_names()) {
		my $acc = main::loaded_account($name) or next;
		next if $acc->{config_disabled} || $acc->{disabled};
		my $role = $acc->{role} // '';
		if ($role eq 'idle') {
			for my $folder (@{ $acc->{folders} // [] }) {
				my $box = $folder->{name} // '';
				next if $box eq '';
				my $id = "$name\t$box";
				$jobs{$id} = {
					kind     => 'idle',
					id       => $id,
					account  => $name,
					folder   => $box,
					channel  => $acc->{mbsync_channel} // $name,
					host     => $acc->{server},
					port     => $acc->{port},
					proto    => $acc->{proto} // 'tls',
					user     => $acc->{user},
					auth     => $acc->{auth} // 'login',
					wait     => $acc->{wait} // 0,
					debounce => $folder->{debounce}
					    || main::calculate_debounce($folder->{priority} // 5),
					resync   => $folder->{resync} || main::default_resync(),
					backoff  => 2,
					startup  => 0,
					pending  => 0,
					armed    => 0,
					up       => 0,
					last_sync   => 0,
					busy_until  => 0,
					busy_for    => 0,
					restart_at  => 0,
				};
			}
		} elsif ($role eq 'pulse') {
			my $ch = $acc->{mbsync_channel} // $name;
			my @boxes = main::channel_folder_names($ch);
			@boxes = ('') unless @boxes;
			my $sweep = $acc->{sweep} || 3600;
			$sweep = 1 if $sweep < 1;
			for my $box (@boxes) {
				my $id = "pulse\t$ch\t$box";
				$jobs{$id} = {
					kind       => 'pulse',
					id         => $id,
					account    => $name,
					folder     => $box,
					channel    => $ch,
					sweep      => $sweep,
					next_at    => $now + $sweep,
					backoff    => 2,
					startup    => 0,
					pending    => 0,
					armed      => 0,
					up         => 0,
					last_sync  => 0,
					busy_until => 0,
					busy_for   => 0,
				};
			}
			# STATUS for this login is its own process. The hub
			# does not open the socket. An empty name is the
			# sweep timer above, not a mailbox to probe.
			my @probe = grep { $_ ne '' } @boxes;
			my $id = "account\t$name";
			$jobs{$id} = {
				kind     => 'account',
				id       => $id,
				account  => $name,
				folder   => '',
				channel  => $ch,
				host     => $acc->{server},
				port     => $acc->{port},
				proto    => $acc->{proto} // 'tls',
				user     => $acc->{user},
				auth     => $acc->{auth} // 'login',
				wait     => $acc->{wait} // 0,
				boxes    => \@probe,
				seen     => {},
				backoff  => 2,
				armed    => 0,
				up       => 0,
				restart_at => 0,
			};
		}
	}
	return %jobs;
}

sub _dry_summary {
	my ($jobs) = @_;
	my $idle = 0;
	my $pulse = 0;
	for my $job (values %$jobs) {
		$idle++ if $job->{kind} eq 'idle';
		$pulse++ if $job->{kind} eq 'pulse';
	}
	my $rows = main::loaded_track_rows();
	main::log_info("dry: $idle idle folder(s), $pulse pulse box(es), "
	    . "$rows track row(s), state stays in memory");
	return;
}

sub _dry_drain {
	my ($up, $jobs, $sel, $fd_job) = @_;
	for my $msg (_take($up)) {
		return 1 if _dry_parent($msg, $up, $jobs, $sel, $fd_job);
	}
	for my $id (keys %$jobs) {
		my $ib = $jobs->{$id}{ib} or next;
		for my $msg (_take($ib)) {
			_dry_worker($jobs->{$id}, $msg, $jobs);
		}
	}
	return 0;
}

sub _dry_parent {
	my ($msg, $up, $jobs, $sel, $fd_job) = @_;
	if ($msg->{type} == IMAPIDLE::IMSG_SHUTDOWN) {
		# Let a running mbsync finish. -n has nothing to wait for.
		if ($REAL) {
			main::request_shutdown('TERM');
			return 0;
		}
		return 1;
	}
	if ($msg->{type} != IMAPIDLE::IMSG_ATTACH) {
		die "parent message $msg->{type}\n";
	}
	my $info = IMAPIDLE::json_decode($msg->{data}) // {};
	my $id = $info->{id} // '';
	my $job = $jobs->{$id} or die "attach $id\n";
	die "attach fd\n" if !defined $msg->{fd} || $msg->{fd} < 0;
	# The glob and the imsg each close their own descriptor.
	my $dup = POSIX::dup($msg->{fd});
	die "dup: $!\n" if !defined $dup || $dup < 0;
	open my $fh, '+<&=', $msg->{fd} or die "idle fd: $!\n";
	my $down = IMAPIDLE::Imsg->open($dup);
	$job->{fh} = $fh;
	$job->{ib} = $down;
	$job->{up} = 1;
	$sel->add($fh);
	$fd_job->{fileno($fh)} = $id;
	$up->send(IMAPIDLE::IMSG_ACK, $id);
	_dry_login($job);
	return 0;
}

sub _dry_login {
	my ($job) = @_;
	my $secret = main::account_pass($job->{account});
	if (!defined $secret || $secret eq '') {
		eval { $job->{ib}->send(IMAPIDLE::IMSG_SHUTDOWN, '') };
		return;
	}
	$job->{ib}->send(IMAPIDLE::IMSG_LOGIN, IMAPIDLE::json_encode({
		id      => $job->{id},
		account => $job->{account},
		folder  => $job->{folder},
		channel => $job->{channel},
		host    => $job->{host},
		port    => $job->{port} + 0,
		proto   => $job->{proto},
		user    => $job->{user},
		secret  => $secret,
		auth    => $job->{auth},
	}));
	undef $secret;
	return;
}

sub _dry_worker {
	my ($job, $msg, $jobs) = @_;
	my $row = IMAPIDLE::json_decode($msg->{data}) // {};
	if ($msg->{type} == IMAPIDLE::IMSG_READY) {
		$job->{armed} = 1;
		$job->{backoff} = 2;
		if (($job->{kind} // '') eq 'account') {
			my $n = @{ $job->{boxes} // [] };
			my $word = $n == 1 ? 'mailbox' : 'mailboxes';
			my $who = main::_log_name($job->{channel});
			main::log_info("$who: pulse speaker up, $n $word");
			if ($REAL) {
				main::imsg_folder_up($job->{account}, '', 1);
			} else {
				for my $box (@{ $job->{boxes} // [] }) {
					$job->{ib}->send(IMAPIDLE::IMSG_PROBE,
					    IMAPIDLE::json_encode({ box => $box }));
				}
			}
		} else {
			$job->{total} = ($row->{total} // 0) + 0;
			$job->{uidnext} = ($row->{uidnext} // 0) + 0;
			$job->{startup} = 1;
			main::imsg_folder_up($job->{account}, $job->{folder}, 1)
			    if $REAL;
		}
		# A login that finished after the cap was learned can be the
		# one that fills the server. Close the extra folder here too.
		_shed_login($jobs, $job, main::imsg_conn_limit_until($job->{account}))
		    if $REAL;
	} elsif ($REAL && $msg->{type} == IMAPIDLE::IMSG_DROP && $row->{limit}) {
		my $open = _armed_on_login($jobs, $job->{account}, $job);
		my $probe = main::note_imsg_conn_limit(
		    $job->{account}, $row->{detail} // '', $open);
		$job->{restart_at} = $probe if $probe && $probe > time();
		_shed_login($jobs, $job, $probe);
	} elsif ($msg->{type} == IMAPIDLE::IMSG_MAIL) {
		my $n = ($row->{total} // 0) + 0;
		if ($REAL) {
			main::note_mail_event(
			    $job->{channel}, $job->{folder},
			    $job->{debounce} // 0,
			    $job->{wait} // 0,
			) if $n > ($job->{total} // 0);
		} else {
			$job->{pending} = 1 if !defined $job->{total} || $n > $job->{total};
		}
		$job->{total} = $n;
	} elsif ($msg->{type} == IMAPIDLE::IMSG_COUNT) {
		if ($REAL) {
			_live_count($job, $row);
		} else {
			_dry_count($job, $row, $jobs);
		}
	}
	return;
}

# The first count is the baseline. A later change makes that
# mailbox due. The sweep clock is unchanged when the count holds.
sub _dry_count {
	my ($job, $row, $jobs) = @_;
	my $box = $row->{box} // '';
	return if $box eq '';
	return unless defined $row->{messages} && defined $row->{uidnext};
	my $messages = $row->{messages} + 0;
	my $uidnext = $row->{uidnext} + 0;
	my $prev = $job->{seen}{$box};
	$job->{seen}{$box} = {
		messages => $messages,
		uidnext  => $uidnext,
	};
	my $who = main::_log_name($job->{channel});
	main::log_info("$who: STATUS $box messages $messages uidnext $uidnext");
	return unless $prev;
	return if $prev->{messages} == $messages && $prev->{uidnext} == $uidnext;
	my $now = time();
	for my $other (values %{ $jobs // {} }) {
		next unless ($other->{kind} // '') eq 'pulse';
		next if ($other->{account} // '') ne ($job->{account} // '');
		next if ($other->{folder} // '') ne $box;
		$other->{next_at} = $now;
	}
	return;
}

sub _dry_read {
	my ($fh, $up_fh, $up, $jobs, $fd_job, $sel) = @_;
	my $fd = fileno($fh);
	my $id = $fd_job->{$fd};
	my $ib = defined $id ? $jobs->{$id}{ib} : $up;
	my $n = $ib->read_more;
	if (!defined $n || $n < 0) {
		return 0 if $!{EINTR};
		die "imsgbuf_read: $!\n";
	}
	if ($n == 0) {
		return 1 if !defined $id;
		_dry_gone($jobs->{$id}, $sel, $fd_job, time());
	}
	return 0;
}

sub _dry_gone {
	my ($job, $sel, $fd_job, $now) = @_;
	return unless $job;
	if ($job->{fh}) {
		my $fd = fileno($job->{fh});
		$sel->remove($job->{fh});
		delete $fd_job->{$fd} if defined $fd;
		# Drop the imsg first so each owner closes its own fd.
		$job->{ib} = undef;
		$job->{fh} = undef;
	}
	$job->{up} = 0;
	$job->{armed} = 0;
	$job->{limit_hold} = 0;
	if ($REAL) {
		if (($job->{kind} // '') eq 'account') {
			main::imsg_folder_up($job->{account}, '', 0);
		} else {
			main::imsg_folder_up($job->{account}, $job->{folder}, 0);
		}
		_drop_flight($job->{channel});
	}
	my $wait = $job->{backoff} || 2;
	my $soon = $now + $wait;
	# A connection-limit refusal already picked a later probe.
	if (!$job->{restart_at} || $job->{restart_at} < $soon) {
		$job->{restart_at} = $soon;
	}
	$wait *= 2;
	$wait = 30 if $wait > 30;
	$job->{backoff} = $wait;
	my $who = main::_log_name($job->{channel});
	if (($job->{kind} // '') eq 'account') {
		main::log_warn("$who: pulse speaker dropped, retry in "
		    . int($job->{restart_at} - $now) . 's');
		return;
	}
	main::log_warn("$who: idle $job->{folder} dropped, retry in "
	    . int($job->{restart_at} - $now) . 's');
	return;
}

sub _dry_spawn {
	my ($up, $now, $jobs) = @_;
	for my $id (sort keys %$jobs) {
		my $job = $jobs->{$id};
		next if $job->{kind} ne 'idle' && $job->{kind} ne 'account';
		next if $job->{up};
		next if $job->{restart_at} && $job->{restart_at} > $now;
		if ($REAL) {
			my $open = _armed_on_login($jobs, $job->{account});
			if (main::imsg_conn_limit_blocked($job->{account}, $open, $now)) {
				my $until = main::imsg_conn_limit_until($job->{account});
				$until = $now + 30 if !$until || $until <= $now;
				$job->{restart_at} = $until;
				next;
			}
		}
		$job->{up} = 'pending';
		$up->send(IMAPIDLE::IMSG_SPAWN, IMAPIDLE::json_encode({
			id      => $id,
			account => $job->{account},
			folder  => $job->{folder},
			peer    => $job->{kind} eq 'account' ? 'account' : 'idle',
		}));
		# A test leaves a gap so the next request arrives before the
		# ack. One read would otherwise hide that race.
		select(undef, undef, undef, 0.05) if $ENV{IMAPIDLE_SPAWN_PAUSE};
	}
	return;
}

sub _dry_start {
	my ($now, $jobs) = @_;
	my $cap = main::_connection_cap();
	my $running = grep {
		$_->{busy_until} && $_->{busy_until} > $now
	} values %$jobs;
	for my $id (sort keys %$jobs) {
		last if $running >= $cap;
		my $job = $jobs->{$id};
		next if ($job->{kind} // '') eq 'account';
		next if $job->{busy_until} && $job->{busy_until} > $now;
		next if _dry_channel_busy($job, $now, $jobs);
		my $due = 0;
		if ($job->{kind} eq 'pulse') {
			$due = $job->{next_at} && $job->{next_at} <= $now;
		} elsif ($job->{armed}) {
			if ($job->{last_sync}
			    && $now >= $job->{last_sync} + $job->{resync}) {
				$job->{pending} = 1;
			}
			$due = $job->{startup}
			    || ($job->{pending}
				&& (!$job->{last_sync}
				    || $now >= $job->{last_sync} + $job->{debounce}));
		}
		next unless $due;
		_dry_fake($job, $now);
		$running++;
	}
	return;
}

sub _dry_channel_busy {
	my ($job, $now, $jobs) = @_;
	my $ch = $job->{channel} // '';
	for my $other (values %$jobs) {
		next if $other == $job;
		next if ($other->{channel} // '') ne $ch;
		return 1 if $other->{busy_until} && $other->{busy_until} > $now;
	}
	return 0;
}

sub _dry_fake {
	my ($job, $now) = @_;
	my ($secs, $base, $delta) = _dry_predict($job->{channel}, $job->{folder});
	$job->{busy_until} = $now + $secs;
	$job->{busy_for} = $secs;
	$job->{last_sync} = $now;
	$job->{startup} = 0;
	$job->{pending} = 0;
	if ($job->{kind} eq 'pulse') {
		my $sweep = $job->{sweep} || 3600;
		$job->{next_at} = $now + $sweep;
	}
	my $who = main::_log_name($job->{channel});
	my $box = $job->{folder} // '';
	my $tail = $box ne '' ? "$box " : '';
	main::log_info("$who: would mbsync ${tail}for ${secs}s "
	    . "(predict $base +/- $delta)");
	main::note_folder_sync($job->{account}, $box, $now) if $box ne '';
	return;
}

sub _dry_finish {
	my ($now, $jobs) = @_;
	for my $job (values %$jobs) {
		next unless $job->{busy_until} && $job->{busy_until} <= $now;
		my $secs = $job->{busy_for};
		$job->{busy_until} = 0;
		my $who = main::_log_name($job->{channel});
		my $box = $job->{folder} // '';
		my $tail = $box ne '' ? "$box " : '';
		main::log_info("$who: would mbsync ${tail}done ${secs}s");
	}
	return;
}

sub _dry_predict {
	my ($channel, $folder) = @_;
	my $key = (defined $folder && $folder ne '')
	    ? "$channel:$folder" : $channel;
	my $avg = main::_argv_real_avg($key);
	my $base = defined $avg ? int($avg + 0.5) : 5;
	$base = 1 if $base < 1;
	my $span = int($base / 4);
	$span = 1 if $span < 1;
	my $delta = int(rand(2 * $span + 1)) - $span;
	my $secs = $base + $delta;
	$secs = 1 if $secs < 1;
	return ($secs, $base, $delta);
}

sub _dry_wake {
	my ($now, $jobs) = @_;
	my $wake = $now + 30;
	for my $job (values %$jobs) {
		for my $when ($job->{busy_until}, $job->{restart_at}, $job->{next_at}) {
			next unless $when && $when > $now && $when < $wake;
			$wake = $when;
		}
		next unless $job->{kind} eq 'idle' && $job->{armed};
		next if $job->{busy_until} && $job->{busy_until} > $now;
		if ($job->{pending} && $job->{last_sync}) {
			my $when = $job->{last_sync} + $job->{debounce};
			$wake = $when if $when > $now && $when < $wake;
		}
		if ($job->{last_sync}) {
			my $when = $job->{last_sync} + $job->{resync};
			$wake = $when if $when > $now && $when < $wake;
		}
	}
	my $d = $wake - time();
	$d = 0.05 if $d < 0.05;
	$d = 30 if $d > 30;
	return $d;
}

sub _live_count {
	my ($job, $row) = @_;
	my $box = $row->{box} // '';
	return if $box eq '';
	my $id = ($job->{channel} // '') . "\0" . $box;
	delete $FLIGHT{$id};
	return unless defined $row->{messages} && defined $row->{uidnext};
	main::note_status_sample(
	    $job->{channel}, $box,
	    $row->{messages} + 0, $row->{uidnext} + 0, time(),
	);
	return;
}

sub _drop_flight {
	my ($channel) = @_;
	return unless defined $channel && $channel ne '';
	for my $id (keys %FLIGHT) {
		my ($ch) = split /\0/, $id, 2;
		delete $FLIGHT{$id} if defined $ch && $ch eq $channel;
	}
	return;
}

sub _live_summary {
	my ($jobs) = @_;
	my $idle = 0;
	my $speakers = 0;
	for my $job (values %$jobs) {
		$idle++ if ($job->{kind} // '') eq 'idle';
		$speakers++ if ($job->{kind} // '') eq 'account';
	}
	my $rows = main::loaded_track_rows();
	main::log_info("imsg: $idle idle folder(s), $speakers pulse speaker(s), "
	    . "$rows track row(s)");
	return;
}

sub _guard_channels {
	my ($jobs) = @_;
	my %ch;
	for my $job (values %$jobs) {
		my $kind = $job->{kind} // '';
		next if $kind ne 'idle' && $kind ne 'account';
		my $name = $job->{channel} // '';
		next if $name eq '';
		$ch{$name} = 1;
	}
	main::set_external_probe($_, 1) for sort keys %ch;
	return;
}

sub _same_login {
	my ($a, $b) = @_;
	return 0 unless $a && $b;
	return 0 if ($a->{server} // '') ne ($b->{server} // '');
	return 0 if (($a->{port} // 0) + 0) != (($b->{port} // 0) + 0);
	return 0 if ($a->{user} // '') ne ($b->{user} // '');
	return 1;
}

# Workers that finished LOGIN for this account's server, port, and user.
sub _armed_on_login {
	my ($jobs, $account, $skip) = @_;
	my $acc = main::loaded_account($account) or return 0;
	my $n = 0;
	for my $job (values %$jobs) {
		next if $skip && $job == $skip;
		next unless $job->{armed};
		my $other = main::loaded_account($job->{account}) or next;
		$n++ if _same_login($acc, $other);
	}
	return $n;
}

# Close armed workers on this login until the stored cap remains.
# The largest debounce leaves first. A pulse speaker stays while an
# idle folder can go. A worker already told to leave is not asked again.
sub _shed_login {
	my ($jobs, $job, $probe) = @_;
	return unless $job && $job->{account};
	my $cap = main::imsg_conn_limit_cap($job->{account});
	return if !$cap || $cap < 1;
	my $now = time();
	return if !$probe || $probe <= $now;
	my $acc = main::loaded_account($job->{account}) or return;
	my @live;
	for my $other (values %$jobs) {
		next unless $other->{armed} && !$other->{limit_hold};
		next if ($other->{kind} // '') ne 'idle'
		    && ($other->{kind} // '') ne 'account';
		my $oa = main::loaded_account($other->{account}) or next;
		next unless _same_login($acc, $oa);
		push @live, $other;
	}
	@live = sort {
		_shed_rank($a) <=> _shed_rank($b)
		    || ($a->{id} // '') cmp ($b->{id} // '')
	} @live;
	while (@live > $cap) {
		my $drop = shift @live;
		$drop->{limit_hold} = 1;
		$drop->{restart_at} = $probe;
		my $who = main::_log_name($drop->{channel} // $drop->{account});
		if (($drop->{kind} // '') eq 'account') {
			main::log_warn("$who: pulse speaker paused for the "
			    . 'connection limit');
		} else {
			main::log_warn("$who: idle $drop->{folder} paused for the "
			    . 'connection limit');
		}
		eval { $drop->{ib}->send(IMAPIDLE::IMSG_SHUTDOWN, '') }
		    if $drop->{ib};
	}
	return;
}

# Smaller rank leaves first.
sub _shed_rank {
	my ($job) = @_;
	return 1_000_000 if ($job->{kind} // '') eq 'account';
	return -($job->{debounce} // 0);
}

sub _armed_imap {
	my ($jobs) = @_;
	my $n = 0;
	for my $job (values %$jobs) {
		my $kind = $job->{kind} // '';
		next if $kind ne 'idle' && $kind ne 'account';
		$n++ if $job->{armed};
	}
	return $n;
}

# One worker per channel answers STATUS. A pulse speaker wins over an
# IDLE folder. At most 40 are in flight, which is the probe batch.
sub _live_probes {
	my ($jobs) = @_;
	my $now = time();
	my %prober;
	for my $id (sort keys %$jobs) {
		my $job = $jobs->{$id};
		next unless $job->{armed} && $job->{ib};
		my $kind = $job->{kind} // '';
		next if $kind ne 'idle' && $kind ne 'account';
		my $ch = $job->{channel} // '';
		next if $ch eq '';
		my $cur = $prober{$ch};
		if (!$cur || ($kind eq 'account' && ($cur->{kind} // '') ne 'account')) {
			$prober{$ch} = $job;
		}
	}
	for my $ch (sort keys %prober) {
		my $job = $prober{$ch};
		my $n = 0;
		for my $id (keys %FLIGHT) {
			my ($fch) = split /\0/, $id, 2;
			$n++ if defined $fch && $fch eq $ch;
		}
		my $room = 40 - $n;
		next if $room <= 0;
		for my $id (main::due_unprobed_ids($ch, $now)) {
			last if $room <= 0;
			next if $FLIGHT{$id};
			my (undef, $box) = split /\0/, $id, 2;
			next if !defined $box || $box eq '';
			$job->{ib}->send(IMAPIDLE::IMSG_PROBE,
			    IMAPIDLE::json_encode({ box => $box }));
			$FLIGHT{$id} = 1;
			$room--;
		}
	}
	return;
}

sub _service_sync {
	my ($sel, $have) = @_;
	my %want;
	for my $fh (main::service_fds()) {
		my $fd = fileno($fh);
		next unless defined $fd;
		$want{$fd} = $fh;
		$sel->add($fh) unless $have->{$fd};
		$have->{$fd} = $fh;
	}
	for my $fd (keys %$have) {
		next if $want{$fd};
		$sel->remove($have->{$fd}) if $have->{$fd};
		delete $have->{$fd};
	}
	return;
}

sub _live_hub {
	my ($up_fh, $config) = @_;
	$SIG{TERM} = $SIG{INT} = 'DEFAULT';
	$SIG{PIPE} = 'IGNORE';
	$SIG{HUP} = \&main::request_reload;
	IMAPIDLE::Imsg::set_title('imapidle: hub');
	main::set_imsg_sched(1);
	my $err = main::load_config($config);
	if ($err) {
		main::log_error($err);
		die "$err\n";
	}
	main::open_state_dir();
	main::install_chld_signal();
	main::install_info_signal();
	# Those installs block CHLD and INFO except across pselect.
	# This loop waits with select, so the handlers have to run.
	main::_restore_wake_mask();
	main::ctl_listen();
	main::prime_named_folders(time());

	my $up = IMAPIDLE::Imsg->open(fileno($up_fh));
	my $sel = IO::Select->new($up_fh);
	my %fd_job;
	my %have;
	my %jobs = _dry_jobs();
	_guard_channels(\%jobs);
	_live_summary(\%jobs);
	my $quit = 0;
	while (!$quit) {
		$quit = _dry_drain($up, \%jobs, $sel, \%fd_job);
		last if $quit;
		main::set_imsg_conn_count(_armed_imap(\%jobs));
		_dry_spawn($up, time(), \%jobs);
		main::refresh_local_state();
		main::reap_children();
		main::apply_reload();
		my $phase = main::shutdown_phase();
		if ($phase eq 'exit') {
			main::_close_for_shutdown();
			last;
		}
		if (!$phase) {
			main::pump_schedule();
			_live_probes(\%jobs);
		}
		my $now = time();
		my $wait = main::loop_timeout();
		my $jobs_wait = _dry_wake($now, \%jobs);
		$wait = $jobs_wait if !defined $wait || $jobs_wait < $wait;
		$wait = 1 if $phase eq 'wait' && (!defined $wait || $wait < 1);
		$wait = 30 if !defined $wait || $wait > 30;
		$wait = 0.05 if $wait < 0.05;
		_service_sync($sel, \%have);
		my @ready = $sel->can_read($wait);
		if (!@ready && $! && $!{EINTR}) {
			next;
		}
		for my $fh (@ready) {
			if (main::service_ready($fh)) {
				next;
			}
			$quit = _dry_read($fh, $up_fh, $up, \%jobs, \%fd_job, $sel);
			last if $quit;
		}
	}
	for my $job (values %jobs) {
		next unless $job->{ib};
		eval { $job->{ib}->send(IMAPIDLE::IMSG_SHUTDOWN, '') };
	}
	return;
}

1;
