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

# One account that is not in IDLE. The hub asks for STATUS. This
# process owns the socket. It has no config file and no state directory.

package IMAPIDLE::Account;

use strict;
use warnings;

use IO::Select ();
use OpenBSD::Pledge ();

use IMAPIDLE ();
use IMAPIDLE::Idle ();
use IMAPIDLE::Imsg;

sub run {
	my ($sock) = @_;
	IMAPIDLE::Imsg::set_title('imapidle: account');
	my $ib = IMAPIDLE::Imsg->open(fileno($sock));
	OpenBSD::Pledge::pledge(qw(stdio inet dns rpath recvfd))
	    or die "account pledge: $!\n";
	my $msg = $ib->recv;
	return if !$msg || $msg->{type} == IMAPIDLE::IMSG_SHUTDOWN;
	die "account login\n" unless $msg->{type} == IMAPIDLE::IMSG_LOGIN;
	my $info = IMAPIDLE::json_decode($msg->{data});
	die "account login\n" unless $info && $info->{host} && $info->{user};
	my $account = $info->{account} // '';
	my $secret = $info->{secret};
	delete $info->{secret};
	if (!main::secret_line_ok($secret)) {
		undef $secret;
		return;
	}

	my ($fh, $preauth) = IMAPIDLE::Idle::_open_session(
	    $ib, $info, $secret, $account, '');
	undef $secret;
	return if !$fh;
	$ib->send(IMAPIDLE::IMSG_READY, IMAPIDLE::json_encode({
		account => $account,
		mode    => 'status',
	}));
	OpenBSD::Pledge::pledge('stdio')
	    or die "account pledge stdio: $!\n";
	_loop($ib, $sock, $fh, $account);
	return;
}

sub _loop {
	my ($ib, $sock, $fh, $account) = @_;
	my $sel = IO::Select->new($sock, $fh);
	while (1) {
		return if _shutdown($ib, $fh, $account);
		if (_server_gone($fh, $ib, $account)) {
			return;
		}
		my @ready = $sel->can_read(30);
		for my $ready (@ready) {
			if (fileno($ready) == fileno($sock)) {
				my $n = $ib->read_more;
				return if defined $n && $n == 0;
				if (!defined $n || $n < 0) {
					next if $!{EINTR} || $!{EAGAIN} || $!{EWOULDBLOCK};
					die "imsg\n";
				}
			} else {
				my $n = sysread($fh, my $chunk, 8192);
				if (!defined $n) {
					next if $!{EINTR} || $!{EAGAIN} || $!{EWOULDBLOCK};
					die "imap read\n";
				}
				if ($n == 0) {
					_drop($ib, $account);
					return;
				}
				IMAPIDLE::Idle::feed($fh, $chunk);
			}
		}
	}
}

# Queued probes run to completion before the next wait. A shutdown
# wins over a probe that has not started.
sub _shutdown {
	my ($ib, $fh, $account) = @_;
	my @msgs = $ib->queued;
	for my $msg (@msgs) {
		if ($msg->{type} == IMAPIDLE::IMSG_SHUTDOWN) {
			_logout($fh) if $fh;
			return 1;
		}
	}
	return 0 unless $fh;
	for my $msg (@msgs) {
		next unless $msg->{type} == IMAPIDLE::IMSG_PROBE;
		my $row = IMAPIDLE::json_decode($msg->{data}) // {};
		my $box = $row->{box} // '';
		next if $box eq '';
		my ($messages, $uidnext) = _status_box($fh, $box);
		$ib->send(IMAPIDLE::IMSG_COUNT, IMAPIDLE::json_encode({
			account  => $account,
			box      => $box,
			messages => $messages,
			uidnext  => $uidnext,
		}));
	}
	return 0;
}

sub _server_gone {
	my ($fh, $ib, $account) = @_;
	while (defined(my $line = IMAPIDLE::Idle::_take($fh))) {
		if ($line =~ /^\* BYE\b/i) {
			_drop($ib, $account);
			return 1;
		}
	}
	return 0;
}

sub _status_box {
	my ($fh, $box) = @_;
	my $tag = IMAPIDLE::Idle::_cmd($fh,
	    'STATUS ' . IMAPIDLE::Idle::_quote($box) . ' (MESSAGES UIDNEXT)');
	my ($messages, $uidnext);
	IMAPIDLE::Idle::_until_tag($fh, $tag, sub {
		my ($line) = @_;
		return unless $line =~ /^\* STATUS\b/i;
		$messages = $1 + 0 if $line =~ /\bMESSAGES (\d+)/i;
		$uidnext  = $1 + 0 if $line =~ /\bUIDNEXT (\d+)/i;
	});
	die "status\n" unless defined $messages && defined $uidnext;
	return ($messages, $uidnext);
}

sub _logout {
	my ($fh) = @_;
	eval {
		my $bye = IMAPIDLE::Idle::_cmd($fh, 'LOGOUT');
		IMAPIDLE::Idle::_until_tag($fh, $bye);
	};
	return;
}

sub _drop {
	my ($ib, $account) = @_;
	eval {
		$ib->send(IMAPIDLE::IMSG_DROP, IMAPIDLE::json_encode({
			account => $account,
			mode    => 'status',
		}));
	};
	return;
}

1;
