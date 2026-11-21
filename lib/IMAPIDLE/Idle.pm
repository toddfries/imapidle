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

# One mailbox. The hub sends the login. This process opens the socket,
# starts TLS when the account asks for it, and IDLEs. It has no config
# file and no state directory.

package IMAPIDLE::Idle;

use strict;
use warnings;

use Errno qw(EAGAIN EINTR EWOULDBLOCK);
use IO::Select ();
use IO::Socket::INET ();
use IO::Socket::SSL ();
use OpenBSD::Pledge ();
use Time::HiRes ();

use IMAPIDLE ();
use IMAPIDLE::Imsg;

my %HOLD;
my $SEQ = 0;

sub run {
	my ($sock) = @_;
	my $ib = IMAPIDLE::Imsg->open(fileno($sock));
	OpenBSD::Pledge::pledge(qw(stdio inet dns rpath recvfd))
	    or die "idle pledge: $!\n";
	my $msg = $ib->recv;
	return if !$msg || $msg->{type} == IMAPIDLE::IMSG_SHUTDOWN;
	die "idle login\n" unless $msg->{type} == IMAPIDLE::IMSG_LOGIN;
	my $info = IMAPIDLE::json_decode($msg->{data});
	die "idle login\n" unless $info && $info->{host} && $info->{user};
	my $account = $info->{account} // '';
	my $folder = $info->{folder} // 'INBOX';
	IMAPIDLE::Imsg::set_worker_title('idle', $account, $folder);
	my $secret = $info->{secret};
	delete $info->{secret};
	if (!main::secret_line_ok($secret)) {
		undef $secret;
		return;
	}

	my ($fh, $preauth) = _open_session($ib, $info, $secret, $account, $folder);
	undef $secret;
	return if !$fh;
	my ($total, $uidnext) = _select_box($fh, $folder);
	$ib->send(IMAPIDLE::IMSG_READY, IMAPIDLE::json_encode({
		account => $account,
		folder  => $folder,
		total   => $total,
		uidnext => $uidnext,
	}));
	my $idle_tag = _cmd($fh, 'IDLE');
	_until_plus($fh, $idle_tag);
	OpenBSD::Pledge::pledge('stdio')
	    or die "idle pledge stdio: $!\n";
	$fh->blocking(0);
	_loop($ib, $sock, $fh, $idle_tag, $account, $folder, $total);
	return;
}

sub _loop {
	my ($ib, $sock, $fh, $idle_tag, $account, $folder, $total) = @_;
	my $sel = IO::Select->new($sock, $fh);
	my $armed_at = time();
	while (1) {
		my $did = _commands($ib, $fh, \$idle_tag, $account, $folder, \$total);
		return if $did < 0;
		$armed_at = time() if $did > 0;
		while (defined(my $line = _take($fh))) {
			if ($line =~ /^\* BYE\b/i) {
				_drop($ib, $account, $folder);
				return;
			}
			_note_exists($ib, $account, $folder, \$total, $line);
		}
		my $slice = 30 - (time() - $armed_at);
		$slice = 0.05 if $slice < 0.05;
		my @ready = $sel->can_read($slice);
		if (time() - $armed_at >= 30) {
			my $ok = eval {
				_rearm($fh, \$idle_tag, $ib, $account, $folder, \$total);
				1;
			};
			if (!$ok) {
				_drop($ib, $account, $folder);
				return;
			}
			$armed_at = time();
			main::note_idle_rearmed($account);
			next;
		}
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
					_drop($ib, $account, $folder);
					return;
				}
				$HOLD{fileno($fh)} .= $chunk;
			}
		}
	}
}

# 1 when IDLE was armed again, -1 when this process should exit.
sub _commands {
	my ($ib, $fh, $tag_ref, $account, $folder, $total_ref) = @_;
	my @msgs = $ib->queued;
	for my $msg (@msgs) {
		if ($msg->{type} == IMAPIDLE::IMSG_SHUTDOWN) {
			_leave($fh, $$tag_ref);
			return -1;
		}
	}
	my @probe;
	for my $msg (@msgs) {
		push @probe, $msg if $msg->{type} == IMAPIDLE::IMSG_PROBE;
	}
	return 0 unless @probe;
	my $ok = eval {
		_rearm_done($fh, $tag_ref, $ib, $account, $folder, $total_ref);
		for my $msg (@probe) {
			my $row = IMAPIDLE::json_decode($msg->{data}) // {};
			my $box = $row->{box} // '';
			next if $box eq '';
			my ($messages, $uidnext) = _status_box($fh, $box);
			$ib->send(IMAPIDLE::IMSG_COUNT, IMAPIDLE::json_encode({
				account  => $account,
				folder   => $folder,
				box      => $box,
				messages => $messages,
				uidnext  => $uidnext,
			}));
		}
		$$tag_ref = _cmd($fh, 'IDLE');
		_until_plus($fh, $$tag_ref);
		1;
	};
	if (!$ok) {
		_drop($ib, $account, $folder);
		return -1;
	}
	return 1;
}

sub _note_exists {
	my ($ib, $account, $folder, $total_ref, $line) = @_;
	return unless defined $line && $line =~ /^\* (\d+) EXISTS\b/i;
	my $n = $1 + 0;
	if ($n > $$total_ref) {
		$$total_ref = $n;
		$ib->send(IMAPIDLE::IMSG_MAIL, IMAPIDLE::json_encode({
			account => $account,
			folder  => $folder,
			total   => $$total_ref,
		}));
	} else {
		$$total_ref = $n;
	}
	return;
}

sub _rearm_done {
	my ($fh, $tag_ref, $ib, $account, $folder, $total_ref) = @_;
	my $on = sub {
		_note_exists($ib, $account, $folder, $total_ref, $_[0]);
	};
	_send($fh, 'DONE');
	_until_tag($fh, $$tag_ref, $on);
	return;
}

sub _rearm {
	my ($fh, $tag_ref, $ib, $account, $folder, $total_ref) = @_;
	_rearm_done($fh, $tag_ref, $ib, $account, $folder, $total_ref);
	$$tag_ref = _cmd($fh, 'IDLE');
	_until_plus($fh, $$tag_ref);
	return;
}

sub _status_box {
	my ($fh, $box) = @_;
	my $tag = _cmd($fh, 'STATUS ' . _quote($box) . ' (MESSAGES UIDNEXT)');
	my ($messages, $uidnext);
	_until_tag($fh, $tag, sub {
		my ($line) = @_;
		return unless $line =~ /^\* STATUS\b/i;
		$messages = $1 + 0 if $line =~ /\bMESSAGES (\d+)/i;
		$uidnext  = $1 + 0 if $line =~ /\bUIDNEXT (\d+)/i;
	});
	die "status\n" unless defined $messages && defined $uidnext;
	return ($messages, $uidnext);
}

sub _drop {
	my ($ib, $account, $folder) = @_;
	eval {
		$ib->send(IMAPIDLE::IMSG_DROP, IMAPIDLE::json_encode({
			account => $account,
			folder  => $folder,
		}));
	};
	return;
}

# Connect and log in. A user+IP cap is reported to the hub, not raised.
sub _open_session {
	my ($ib, $info, $secret, $account, $folder) = @_;
	my ($fh, $preauth, $err);
	eval {
		($fh, $preauth) = _connect($info);
		_authenticate($fh, $info, $secret) if !$preauth;
		1;
	} or $err = main::scrub($@, $secret);
	if ($err) {
		if (main::conn_limit_error($err)) {
			$err = main::scrub($err);
			$err =~ s/\s+/ /g;
			$err = substr($err, 0, 160);
			eval {
				$ib->send(IMAPIDLE::IMSG_DROP, IMAPIDLE::json_encode({
					account => $account // '',
					folder  => $folder // '',
					limit   => 1,
					detail  => $err,
				}));
			};
			return;
		}
		die "$err\n";
	}
	return ($fh, $preauth);
}

sub _leave {
	my ($fh, $tag) = @_;
	eval {
		_send($fh, 'DONE');
		_until_tag($fh, $tag);
		my $bye = _cmd($fh, 'LOGOUT');
		_until_tag($fh, $bye);
	};
	return;
}

sub _connect {
	my ($info) = @_;
	my $proto = $info->{proto} // 'tls';
	my $host = $info->{host};
	my $port = $info->{port};
	if ($proto eq 'notls') {
		my $fh = IO::Socket::INET->new(
			PeerAddr => $host,
			PeerPort => $port,
			Proto    => 'tcp',
			Timeout  => 30,
		) or die "connect\n";
		$fh->autoflush(1);
		my $greet = _line($fh);
		die "greeting\n" unless $greet =~ /^\* (OK|PREAUTH)\b/i;
		return ($fh, $greet =~ /PREAUTH/i ? 1 : 0);
	}
	if ($proto eq 'starttls') {
		my $fh = IO::Socket::INET->new(
			PeerAddr => $host,
			PeerPort => $port,
			Proto    => 'tcp',
			Timeout  => 30,
		) or die "connect\n";
		$fh->autoflush(1);
		my $greet = _line($fh);
		die "greeting\n" unless $greet =~ /^\* (OK|PREAUTH)\b/i;
		_send($fh, 'a0 STARTTLS');
		my $line = _line($fh);
		die "starttls\n" unless $line =~ /^a0 OK\b/i;
		my $tls = IO::Socket::SSL->start_SSL(
			$fh,
			SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
			SSL_hostname    => $host,
			Timeout         => 30,
		);
		die "tls\n" unless $tls;
		$tls->autoflush(1);
		return ($tls, 0);
	}
	my $fh = IO::Socket::SSL->new(
		PeerAddr        => $host,
		PeerPort        => $port,
		Proto           => 'tcp',
		Timeout         => 30,
		SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
		SSL_hostname    => $host,
	) or die "connect\n";
	$fh->autoflush(1);
	my $greet = _line($fh);
	die "greeting\n" unless $greet =~ /^\* (OK|PREAUTH)\b/i;
	return ($fh, $greet =~ /PREAUTH/i ? 1 : 0);
}

sub _authenticate {
	my ($fh, $info, $secret) = @_;
	$secret = '' unless defined $secret;
	die "login\n" if $secret eq '';
	if (($info->{auth} // '') eq 'xoauth2') {
		my $blob = main::xoauth2_initial($info->{user}, $secret);
		my $tag = _cmd($fh, "AUTHENTICATE XOAUTH2 $blob");
		_until_tag($fh, $tag, sub {
			my ($line) = @_;
			_send($fh, '') if $line =~ /^\+/;
		});
		return;
	}
	my $tag = _cmd($fh, 'LOGIN '
	    . _quote($info->{user}) . ' ' . _quote($secret));
	eval { _until_tag($fh, $tag); 1 } or do {
		my $err = main::scrub($@, $secret);
		die ($err eq '' ? "login\n" : "$err\n");
	};
	return;
}

sub _select_box {
	my ($fh, $folder) = @_;
	my $tag = _cmd($fh, 'SELECT ' . _quote($folder));
	my $total = 0;
	my $uidnext = 0;
	eval {
		_until_tag($fh, $tag, sub {
			my ($line) = @_;
			$total = $1 + 0 if $line =~ /^\* (\d+) EXISTS\b/i;
			$uidnext = $1 + 0 if $line =~ /^\* OK \[UIDNEXT (\d+)\]/i;
		});
		1;
	} or do {
		my $err = main::scrub($@);
		$err = 'imap failed' if $err eq '';
		die "$folder: $err\n";
	};
	return ($total, $uidnext);
}

sub _quote {
	my ($s) = @_;
	$s = '' unless defined $s;
	die "imap quote\n" if $s =~ /[\r\n\0]/;
	$s =~ s/\\/\\\\/g;
	$s =~ s/"/\\"/g;
	return qq{"$s"};
}

sub _cmd {
	my ($fh, $line) = @_;
	my $tag = 'a' . ++$SEQ;
	_send($fh, "$tag $line");
	return $tag;
}

sub _send {
	my ($fh, $line) = @_;
	my $ok = print $fh $line, "\r\n";
	die "imap write\n" unless $ok;
	return;
}

# Response code only. The rest of a NO line can echo the command.
sub _until_tag {
	my ($fh, $tag, $on) = @_;
	while (1) {
		my $line = _line($fh);
		return if $line =~ /^\Q$tag\E OK\b/i;
		if ($line =~ /^\Q$tag\E (NO|BAD)\b\s*(.*)$/i) {
			my $kind = uc $1;
			my $tail = $2 // '';
			my $code = '';
			$code = $1 if $tail =~ s/^\[([A-Za-z][A-Za-z0-9-]*)\]\s*//;
			$tail =~ s/[^ -~]+/ /g;
			$tail =~ s/\s+/ /g;
			$tail =~ s/\A //;
			$tail =~ s/ \z//;
			$tail = substr($tail, 0, 120);
			die "imap $tag $kind"
			    . ($code ne '' ? " $code" : '')
			    . ($tail ne '' ? " $tail" : '') . "\n";
		}
		$on->($line) if $on;
	}
}

sub _until_plus {
	my ($fh, $tag) = @_;
	while (1) {
		my $line = _line($fh);
		return if $line =~ /^\+/;
		if ($line =~ /^\Q$tag\E (NO|BAD)\b(?:\s+\[([A-Za-z][A-Za-z0-9-]*)\])?/i) {
			my $kind = uc $1;
			my $code = $2 // '';
			die "imap $tag $kind" . ($code ne '' ? " $code" : '') . "\n";
		}
	}
}

sub _line {
	my ($fh) = @_;
	my $fd = fileno($fh);
	my $deadline = Time::HiRes::time() + 30;
	while (1) {
		if (defined $HOLD{$fd} && $HOLD{$fd} =~ s/^(.*?)\r?\n//) {
			return $1;
		}
		my $left = $deadline - Time::HiRes::time();
		die "imap timeout\n" if $left <= 0;
		my $sel = IO::Select->new($fh);
		my @ready = $sel->can_read($left);
		die "imap timeout\n" unless @ready;
		my $n = sysread($fh, my $chunk, 8192);
		die "imap closed\n" if defined $n && $n == 0;
		if (!defined $n) {
			next if $!{EINTR} || $!{EAGAIN} || $!{EWOULDBLOCK};
			die "imap read\n";
		}
		$HOLD{$fd} .= $chunk;
		die "imap line\n" if length($HOLD{$fd}) > 1048576;
	}
}

sub feed {
	my ($fh, $bytes) = @_;
	return unless defined $fh && defined $bytes && $bytes ne '';
	$HOLD{fileno($fh)} .= $bytes;
	return;
}

sub _take {
	my ($fh) = @_;
	my $fd = fileno($fh);
	return unless defined $HOLD{$fd} && $HOLD{$fd} =~ s/^(.*?)\r?\n//;
	return $1;
}

1;
