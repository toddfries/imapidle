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

use strict;
use warnings;
use Test::More;
use Digest::SHA qw(sha256_hex);
use File::Find qw(find);
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use IO::Select ();
use IO::Socket::INET ();
use MIME::Base64 qw(encode_base64);
use POSIX qw(_exit WNOHANG);
use Socket qw(AF_UNIX SOCK_STREAM);
use Time::HiRes qw(time);

my $built = system('make', '-C', "$Bin/../ext/imsg");
is($built, 0, 'the imsg wrapper builds') or BAIL_OUT('imsg build failed');

my $home = tempdir('imapidle-dry-XXXX', TMPDIR => 1, CLEANUP => 1);
my $state = "$home/.local/imapidle";
mkdir "$home/.local", 0700 or die "mkdir: $!";
mkdir $state, 0700 or die "mkdir: $!";

my $listen = IO::Socket::INET->new(
	LocalAddr => '127.0.0.1',
	LocalPort => 0,
	Listen    => 4,
	Reuse     => 1,
	Proto     => 'tcp',
) or die "listen: $!";
my $port = $listen->sockport;

my $key = encode_base64('box:INBOX', '');
open my $real, '>', "$state/mbsync-real" or die $!;
print $real "# key\tcount\ttotal\n";
print $real "$key\t1\t4\n";
close $real;
open my $keep, '>', "$state/keep" or die $!;
print $keep "stay\n";
close $keep;
open my $trap, '>', "$home/known_hosts" or die $!;
print $trap "trap\n";
close $trap;

my $cfg = "$home/imapidle.conf";
open my $cf, '>', $cfg or die $!;
print $cf <<"EOF";
[srv]
type = server
host = 127.0.0.1
port = $port
proto = notls

[box]
type = account
server = srv
user = alice
pass = secret

[watch]
type = idle
channel = box
folder0 = INBOX;priority=1
EOF
close $cf;

my $before = _tree($home);
my $server = fork();
die "fork server: $!" unless defined $server;
if ($server == 0) {
	$SIG{PIPE} = 'IGNORE';
	_imap($listen);
	_exit(0);
}
close $listen;

socketpair(my $err_r, my $err_w, AF_UNIX, SOCK_STREAM, 0)
    or die "socketpair: $!";
_autoflush($err_r);
_autoflush($err_w);

my $t0 = time();
my $daemon = fork();
die "fork daemon: $!" unless defined $daemon;
if ($daemon == 0) {
	setpgrp(0, 0);
	close $err_r;
	open STDOUT, '>', '/dev/null' or _exit(127);
	open STDERR, '>&', $err_w or _exit(127);
	close $err_w;
	$ENV{HOME} = $home;
	$ENV{PATH} = '/usr/bin:/bin:/usr/local/bin';
	exec $^X, "$Bin/../imapidle", '-d', '-n', '-c', $cfg
	    or _exit(127);
}
close $err_w;

END {
	_stop($daemon) if $daemon;
	_stop($server) if $server;
}

my $would_re = qr{would mbsync INBOX for (\d+)s \(predict (\d+) \+/- (-?\d+)\)};
my ($log, $secs, $base, $delta) = _until($err_r, 15, $would_re);
ok(defined $secs, 'a sync is logged instead of run') or diag($log);
is($base, 4, 'the prediction is the saved average');
ok(defined $delta && $delta >= -1 && $delta <= 1,
    'the swing is about a quarter of the average');
is($secs, (defined $base && defined $delta) ? $base + $delta : '',
    'the wait is the prediction plus the swing');

my @comms = _comms($daemon);
ok((!grep { $_ eq 'mbsync' } @comms), 'mbsync was not started')
    or diag(join ' ', @comms);

my $done_re = defined $secs
    ? qr/would mbsync INBOX done \Q$secs\Es/
    : qr/would mbsync INBOX done (\d+)s/;
my ($done_log, $hit_done) = _until($err_r, 20, $done_re, $log);
ok(defined $hit_done, 'the fake sync finishes after its wait')
    or diag($done_log);
my $elapsed = time() - $t0;
ok(defined $secs && $elapsed + 0.5 >= $secs,
    "waited about ${secs}s (saw $elapsed)");

my $during = _tree($home);
is($during, $before, 'the fake sync leaves the home directory unchanged')
    or diag($during);

my ($idle_pid) = _role_pids($daemon, 'idle');
ok($idle_pid, 'an idle worker is running')
    or diag(join("\n", _role_args($daemon)));
if ($idle_pid) {
	kill 'TERM', $idle_pid;
	my ($drop_log, $dropped) = _until($err_r, 8,
	    qr/idle INBOX dropped/, $done_log);
	ok($dropped, 'the hub notices a dead idle worker') or diag($drop_log);
	my $again = 0;
	my $until = time() + 8;
	while (time() < $until) {
		my @now = _role_pids($daemon, 'idle');
		if (grep { $_ ne $idle_pid } @now) {
			$again = 1;
			last;
		}
		select(undef, undef, undef, 0.1);
	}
	ok($again, 'the parent starts a replacement idle worker');
} else {
	fail('the hub notices a dead idle worker');
	fail('the parent starts a replacement idle worker');
}

my $status = _stop($daemon);
$daemon = 0;
is($status & 127, 0, 'shutdown is not a signal');
is($status >> 8, 0, 'the dry run exits 0');
_stop($server);
$server = 0;

my $after = _tree($home);
is($after, $before, 'shutdown leaves the home directory unchanged')
    or diag($after);

done_testing;

sub _until {
	my ($fh, $seconds, $re, $buf) = @_;
	$buf = '' unless defined $buf;
	my $deadline = time() + $seconds;
	while (time() < $deadline) {
		if (my @got = ($buf =~ $re)) {
			return ($buf, @got);
		}
		my $left = $deadline - time();
		last if $left <= 0;
		my $sel = IO::Select->new($fh);
		my @ready = $sel->can_read($left > 0.2 ? 0.2 : $left);
		next unless @ready;
		my $n = sysread($fh, my $chunk, 8192);
		last if !defined $n || $n == 0;
		$buf .= $chunk;
	}
	my @got = ($buf =~ $re);
	return ($buf, @got);
}

sub _role_pids {
	my ($root, $role) = @_;
	my $want = "imapidle: $role";
	open my $fh, '-|', '/bin/ps', '-axww', '-o', 'pid=', '-o', 'ppid=',
	    '-o', 'args=' or die "ps: $!";
	my (%ppid, %args);
	while (<$fh>) {
		next unless /^\s*(\d+)\s+(\d+)\s+(\S.*\S|\S)\s*$/;
		$ppid{$1} = $2;
		$args{$1} = $3;
	}
	close $fh;
	my @q = ($root);
	my %seen;
	my @hit;
	while (@q) {
		my $pid = shift @q;
		next if $seen{$pid}++;
		for my $child (keys %ppid) {
			next unless $ppid{$child} == $pid;
			push @hit, $child
			    if ($args{$child} // '') =~ /^\Q$want\E(?:\s|\(|$)/;
			push @q, $child;
		}
	}
	return @hit;
}

sub _role_args {
	my ($root) = @_;
	open my $fh, '-|', '/bin/ps', '-axww', '-o', 'pid=', '-o', 'ppid=',
	    '-o', 'args=' or return 'ps failed';
	my (%ppid, %args);
	while (<$fh>) {
		next unless /^\s*(\d+)\s+(\d+)\s+(\S.*\S|\S)\s*$/;
		$ppid{$1} = $2;
		$args{$1} = $3;
	}
	close $fh;
	my @out;
	my @q = ($root);
	my %seen;
	while (@q) {
		my $pid = shift @q;
		next if $seen{$pid}++;
		for my $child (keys %ppid) {
			next unless $ppid{$child} == $pid;
			push @out, "$child $args{$child}";
			push @q, $child;
		}
	}
	return @out;
}

sub _comms {
	my ($root) = @_;
	open my $fh, '-|', '/bin/ps', '-ax', '-o', 'pid=', '-o', 'ppid=', '-o', 'comm='
	    or die "ps: $!";
	my (%ppid, %comm);
	while (<$fh>) {
		next unless /^\s*(\d+)\s+(\d+)\s+(\S+)/;
		$ppid{$1} = $2;
		$comm{$1} = $3;
	}
	close $fh;
	my @out;
	my @q = ($root);
	my %seen;
	while (@q) {
		my $pid = shift @q;
		next if $seen{$pid}++;
		for my $child (keys %ppid) {
			next unless $ppid{$child} == $pid;
			push @out, $comm{$child} // '';
			push @q, $child;
		}
	}
	return @out;
}

sub _tree {
	my ($root) = @_;
	my @rows;
	find(sub {
		my $rel = $File::Find::name;
		$rel =~ s/^\Q$root\E\/?//;
		return if $rel eq '';
		my @st = lstat or return;
		my $sum = '';
		if (-f $_) {
			open my $in, '<', $_ or die "read $rel: $!";
			binmode $in;
			local $/;
			$sum = sha256_hex(<$in>);
			close $in;
		}
		push @rows, sprintf('%s %o %s', $rel, $st[2] & 07777, $sum);
	}, $root);
	return join("\n", sort @rows);
}

sub _imap {
	my ($listen) = @_;
	while (my $c = $listen->accept) {
		$c->autoflush(1);
		print $c "* OK fake ready\r\n";
		my $buf = '';
		my $idle = '';
		my $sel = IO::Select->new($c);
		while (1) {
			my @ready = $sel->can_read(30);
			last unless @ready;
			my $n = sysread($c, my $chunk, 4096);
			last if !defined $n || $n == 0;
			$buf .= $chunk;
			while ($buf =~ s/^(.*?)\r?\n//) {
				my $line = $1;
				if ($line =~ /^(\S+) LOGIN\b/i) {
					print $c "$1 OK logged in\r\n";
				} elsif ($line =~ /^(\S+) SELECT\b/i) {
					print $c "* 2 EXISTS\r\n";
					print $c "* OK [UIDNEXT 10]\r\n";
					print $c "$1 OK selected\r\n";
				} elsif ($line =~ /^(\S+) IDLE\b/i) {
					$idle = $1;
					print $c "+ idling\r\n";
					print $c "* 3 EXISTS\r\n";
				} elsif ($line eq 'DONE' && $idle ne '') {
					print $c "$idle OK idle done\r\n";
					$idle = '';
				} elsif ($line =~ /^(\S+) LOGOUT\b/i) {
					print $c "* BYE\r\n";
					print $c "$1 OK logout\r\n";
					close $c;
					return;
				}
			}
		}
		close $c;
	}
	return;
}

sub _stop {
	my ($pid) = @_;
	return -1 unless $pid && $pid > 0;
	kill 'TERM', $pid;
	my $until = time() + 3;
	while (time() < $until) {
		my $got = waitpid($pid, WNOHANG);
		return $? if $got > 0;
		return 0 if $got < 0;
		select(undef, undef, undef, 0.05);
	}
	kill 'TERM', -$pid;
	kill 'KILL', $pid;
	waitpid($pid, 0);
	return $?;
}

sub _autoflush {
	my ($fh) = @_;
	my $old = select($fh);
	$| = 1;
	select($old);
	return;
}
