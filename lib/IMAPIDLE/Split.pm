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
# is a sibling of the hub and has one socketpair to the hub. The parent
# hands the worker a kernel fd. The worker would start TLS on that fd.
# A dead hub ends the parent. This pass runs one worker to completion
# and exits non-zero if that worker fails.

package IMAPIDLE::Split;

use strict;
use warnings;

use IO::Select ();
use JSON::PP ();
use OpenBSD::Pledge ();
use POSIX qw(_exit);
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use IMAPIDLE ();
use IMAPIDLE::Imsg;

our $ACTIVE = 0;
our $IS_CHILD = 0;
our $HUB;
our $IDLE;

END {
	return if !$ACTIVE || $IS_CHILD;
	kill 'TERM', $HUB if $HUB;
	kill 'TERM', $IDLE if $IDLE;
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

1;
