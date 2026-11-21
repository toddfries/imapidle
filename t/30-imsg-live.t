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
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use IO::Select ();
use IO::Socket::INET ();
use POSIX qw(_exit WNOHANG);
use Socket qw(AF_UNIX SOCK_STREAM);

my $built = system('make', '-C', "$Bin/../ext/imsg");
is($built, 0, 'the imsg wrapper builds') or BAIL_OUT('imsg build failed');

my $home = tempdir('imapidle-live-XXXX', TMPDIR => 1, CLEANUP => 1);
my $ran = "$home/mbsync-ran";
my $fake = "$home/mbsync";
open my $bin, '>', $fake or die "mbsync: $!";
print $bin "#!/bin/sh\nprintf '%s\\n' \"\$*\" >> '$ran'\nexit 0\n";
close $bin;
chmod 0755, $fake or die "chmod: $!";

my $listen = IO::Socket::INET->new(
	LocalAddr => '127.0.0.1',
	LocalPort => 0,
	Listen    => 4,
	Reuse     => 1,
	Proto     => 'tcp',
) or die "listen: $!";
my $port = $listen->sockport;

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

my $daemon = fork();
die "fork daemon: $!" unless defined $daemon;
if ($daemon == 0) {
	setpgrp(0, 0);
	close $err_r;
	open STDOUT, '>', '/dev/null' or _exit(127);
	open STDERR, '>&', $err_w or _exit(127);
	close $err_w;
	$ENV{HOME} = $home;
	$ENV{IMAPIDLE_MBSYNC} = $fake;
	$ENV{PATH} = '/usr/bin:/bin:/usr/local/bin';
	exec $^X, "$Bin/../imapidle", '-d', '-c', $cfg
	    or _exit(127);
}
close $err_w;

END {
	_stop($daemon) if $daemon;
	_stop($server) if $server;
}

my $start_re = qr/start .*INBOX/;
my ($log, $hit) = _until($err_r, 15, $start_re);
ok(defined $hit, 'a real mbsync is started') or diag($log);
unlike($log, qr/would mbsync/, 'the live hub does not log a dry sync');
my $args = '';
my $ran_until = time() + 5;
while (time() < $ran_until) {
	if (open my $got, '<', $ran) {
		$args = do { local $/; <$got> };
		close $got;
		last if defined $args && $args =~ /box:INBOX/;
	}
	select(undef, undef, undef, 0.05);
}
like($args, qr/box:INBOX/, 'the channel and mailbox are the arguments')
    or diag($args // '');

my $sock = "$home/var/run/imapidle.sock";
my $until = time() + 5;
while (time() < $until && !-S $sock) {
	select(undef, undef, undef, 0.05);
}
ok(-S $sock, 'the control socket is open');

my $idle_pid;
my $idle_until = time() + 8;
while (time() < $idle_until) {
	($idle_pid) = _role_pids($daemon, 'idle');
	last if $idle_pid;
	select(undef, undef, undef, 0.1);
}
ok($idle_pid, 'an idle worker is running')
    or diag(join("\n", _role_args($daemon)));
my ($hub_pid) = _role_pids($daemon, 'hub');
ok($hub_pid, 'the hub is running');

my $status = _stop($daemon);
$daemon = 0;
is($status & 127, 0, 'shutdown is not a signal');
is($status >> 8, 0, 'the daemon exits 0');
_stop($server);
$server = 0;

ok(-f "$home/.local/imapidle/mbsync-real", 'the sync average was written');

done_testing;

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
			next unless @ready;
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
				} elsif ($line eq 'DONE' && $idle ne '') {
					print $c "$idle OK idle done\r\n";
					$idle = '';
				} elsif ($line =~ /^(\S+) LOGOUT\b/i) {
					print $c "* BYE\r\n";
					print $c "$1 OK logout\r\n";
					last;
				}
			}
		}
		close $c;
	}
	return;
}

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
