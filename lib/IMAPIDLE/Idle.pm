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
	IMAPIDLE::Imsg::set_title('imapidle: idle');
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
	my $secret = $info->{secret};
	delete $info->{secret};

	my ($fh, $preauth) = _connect($info);
	if (!$preauth) {
		_authenticate($fh, $info, $secret);
	}
	undef $secret;
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
	while (1) {
		if (_shutdown($ib)) {
			_leave($fh, $idle_tag);
			return;
		}
		while (defined(my $line = _take($fh))) {
			if ($line =~ /^\* (\d+) EXISTS\b/i) {
				my $n = $1 + 0;
				if ($n > $total) {
					$total = $n;
					$ib->send(IMAPIDLE::IMSG_MAIL,
					    IMAPIDLE::json_encode({
						account => $account,
						folder  => $folder,
						total   => $total,
					    }));
				} else {
					$total = $n;
				}
			} elsif ($line =~ /^\* BYE\b/i) {
				_drop($ib, $account, $folder);
				return;
			}
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
					_drop($ib, $account, $folder);
					return;
				}
				$HOLD{fileno($fh)} .= $chunk;
			}
		}
	}
}

sub _shutdown {
	my ($ib) = @_;
	for my $msg ($ib->queued) {
		return 1 if $msg->{type} == IMAPIDLE::IMSG_SHUTDOWN;
	}
	return 0;
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
	_until_tag($fh, $tag);
	return;
}

sub _select_box {
	my ($fh, $folder) = @_;
	my $tag = _cmd($fh, 'SELECT ' . _quote($folder));
	my $total = 0;
	my $uidnext = 0;
	_until_tag($fh, $tag, sub {
		my ($line) = @_;
		$total = $1 + 0 if $line =~ /^\* (\d+) EXISTS\b/i;
		$uidnext = $1 + 0 if $line =~ /^\* OK \[UIDNEXT (\d+)\]/i;
	});
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

sub _until_tag {
	my ($fh, $tag, $on) = @_;
	while (1) {
		my $line = _line($fh);
		return if $line =~ /^\Q$tag\E OK\b/i;
		die "imap failed\n" if $line =~ /^\Q$tag\E (NO|BAD)\b/i;
		$on->($line) if $on;
	}
}

sub _until_plus {
	my ($fh, $tag) = @_;
	while (1) {
		my $line = _line($fh);
		return if $line =~ /^\+/;
		die "imap idle\n" if $line =~ /^\Q$tag\E (NO|BAD)\b/i;
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

sub _take {
	my ($fh) = @_;
	my $fd = fileno($fh);
	return unless defined $HOLD{$fd} && $HOLD{$fd} =~ s/^(.*?)\r?\n//;
	return $1;
}

1;
