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
use Errno qw(EAGAIN EWOULDBLOCK);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use File::Temp qw(tempdir tempfile);
use IO::Socket::IP;
use POSIX qw(_exit);
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use Test::More;
use Time::HiRes qw(time);

require './imapidle';

my $run = tempdir('imapidle-io-XXXX', CLEANUP => 1, TMPDIR => 1);
set_runtime_dir_for_test($run);
set_foreground_for_test(0);

my $cap = io_timeout_for_test();
my $kid = 0;
END {
    kill 'KILL', $kid if $kid;
    set_io_timeout_for_test($cap) if defined &set_io_timeout_for_test;
}

sub pair {
    socketpair(my $rd, my $wr, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
        or die "socketpair: $!";
    return ($rd, $wr);
}

my ($rd, $wr) = pair();
my $t0 = time();
ok(!io_wait_fd($rd, 0, 0.25), 'a quiet socket is not ready');
my $idle = time() - $t0;
cmp_ok($idle, '>', 0.2, 'a quiet socket waits for the caller timeout');
cmp_ok($idle, '<', 1, 'a quiet socket does not sit for the 45s cap');

syswrite($wr, 'x') or die "syswrite: $!";
$t0 = time();
ok(io_wait_fd($rd, 0, 5), 'a readable socket is ready');
cmp_ok(time() - $t0, '<', 0.5, 'a ready socket returns without the full timeout');

my $closed = IO::Socket::IP->new(
    LocalAddr => '127.0.0.1',
    LocalPort => 0,
    Proto     => 'tcp',
    Listen    => 1,
    ReuseAddr => 1,
) or die "listen: $!";
my $refused = $closed->sockport;
close $closed;
$t0 = time();
eval { tcp_ssl_connect('127.0.0.1', $refused); };
my $err = $@;
cmp_ok(time() - $t0, '<', 1, 'a refused connect fails at once');
like($err, qr/^tcp connect:/, 'a refused connect is a tcp error') or diag($err);

set_io_timeout_for_test(0.5);
$t0 = time();
eval { tcp_ssl_connect('192.0.2.1', 9); };
$err = $@;
my $black = time() - $t0;
set_io_timeout_for_test($cap);
like($err, qr/^tcp /, 'an unanswered connect fails as tcp') or diag($err);
cmp_ok($black, '<', 2, 'an unanswered connect stays inside the short cap');
if ($err =~ /timeout/) {
    cmp_ok($black, '>', 0.35, 'a blackholed connect waits out the cap');
}

my $ln = IO::Socket::IP->new(
    LocalAddr => '127.0.0.1',
    LocalPort => 0,
    Proto     => 'tcp',
    Listen    => 1,
    ReuseAddr => 1,
) or die "listen: $!";
my $port = $ln->sockport;
$kid = fork();
die "fork: $!" unless defined $kid;
if ($kid == 0) {
    my $cli = $ln->accept();
    if ($cli) {
        my $buf = '';
        sysread($cli, $buf, 4096);
        sleep 30;
    }
    _exit(0);
}
set_io_timeout_for_test(0.6);
$t0 = time();
eval { tcp_ssl_connect('127.0.0.1', $port); };
$err = $@;
my $hand = time() - $t0;
kill 'KILL', $kid;
waitpid $kid, 0;
$kid = 0;
set_io_timeout_for_test($cap);
like($err, qr/^ssl timeout/, 'a silent TLS peer hits the deadline') or diag($err);
cmp_ok($hand, '>', 0.4, 'the TLS wait uses the deadline');
cmp_ok($hand, '<', 2, 'the TLS wait does not run on to 45s');

my ($full_rd, $full_wr) = pair();
my $fl = fcntl($full_wr, F_GETFL, 0);
fcntl($full_wr, F_SETFL, $fl | O_NONBLOCK) or die "fcntl: $!";
my $filled = 0;
my $blk = 'x' x 8192;
for (1 .. 100000) {
    my $n = syswrite($full_wr, $blk);
    if (!defined $n) {
        $filled = 1 if $! == EAGAIN || $! == EWOULDBLOCK;
        last;
    }
    last if $n == 0;
}
ok($filled, 'the send buffer fills');
set_io_timeout_for_test(0.4);
my $writer = bless { Socket => $full_wr, State => 1 }, 'ImapidleClient';
$t0 = time();
my $wrote = $writer->_send_bytes(\('y' x 4096));
my $stall = time() - $t0;
set_io_timeout_for_test($cap);
ok(!defined $wrote, 'a stalled write gives up');
like($writer->LastError // '', qr/timeout waiting to write/, 'a stalled write reports the timeout');
is($writer->State, Mail::IMAPClient::Unconnected(), 'a stalled write marks the session down');
cmp_ok($stall, '>', 0.3, 'the write waits for its deadline');
cmp_ok($stall, '<', 2, 'the write does not run on to 45s');

my ($quiet, $sink) = pair();
my $reader = bless { Socket => $quiet }, 'ImapidleClient';
$t0 = time();
my $rc = imap_read_more($reader, $quiet, 0.25);
my $read_wait = time() - $t0;
is($rc, 0, 'a read with no bytes fails');
like($reader->LastError // '', qr/timeout waiting/, 'a stalled read names the timeout');
ok(!defined $reader->{Socket}, 'a stalled read drops the socket');
cmp_ok($read_wait, '<', 1, 'the read uses the caller timeout');

my ($poll_rd, $poll_wr) = pair();
my $poller = bless { Socket => $poll_rd }, 'ImapidleClient';
$rc = imap_read_more($poller, { error_on_timeout => 0 }, $poll_rd, 0.2);
is($rc, 0, 'an idle poll finds nothing');
ok(defined $poller->{Socket}, 'an idle poll keeps the socket');
is($poller->State, Mail::IMAPClient::Unconnected(), 'an idle poll does not mark the session down');

my ($cfh, $cpath) = tempfile(UNLINK => 1);
print $cfh <<'EOF';
[acct]
type = account
server = 127.0.0.1
user = a@example.com
pass = secret
mbsync_channel = ch

[acct-watch]
type = idle
channel = acct
folder0 = INBOX

EOF
close $cfh;
is(load_config($cpath), '', 'the wait fixture loads');
reset_schedule_for_test();
my @hit;
set_trigger_hook_for_test(sub {
    push @hit, join(' ', @{ $_[1] });
    return 1;
});
my $now = time();
queue_folder('ch', 'INBOX', $now, $now);
my ($hold, $hold_w) = pair();
$t0 = time();
ok(!io_wait_fd($hold, 0, 0.5), 'the focus socket stays quiet');
cmp_ok(time() - $t0, '<', 2, 'the shared wait stays inside its timeout');
is_deeply(\@hit, ['ch:INBOX'], 'a due mbsync starts while a socket waits');
set_trigger_hook_for_test(undef);

my $stop = "$run/shutdown";
open my $sfh, '>', $stop or die "shutdown: $!";
close $sfh;
my ($sd, $sdw) = pair();
print $sdw "ready\n" or die "write: $!";
$t0 = time();
ok(!io_wait_fd($sd, 0, 5), 'a shutdown file ends the IMAP wait');
cmp_ok(time() - $t0, '<', 1, 'that wait does not sit out its timeout');
unlink $stop;
reset_track_for_test();

my $learned = "$run/learned";
set_learned_for_test($learned);
open my $lfh, '>', $learned or die "learned: $!";
print $lfh "slow.example:993\tabsent\n";
close $lfh;
is(server_read_cap('slow.example', 993), 45, 'an unset read cap is 45');
raise_server_read_cap('slow.example', 993);
is(server_read_cap('slow.example', 993), 68, 'a timeout raises the cap by half');
like(slurp($learned), qr/^slow\.example:993\tabsent\tio=68$/m, 'the learned file keeps io');
while (server_read_cap('slow.example', 993) < 900) {
    raise_server_read_cap('slow.example', 993);
}
is(server_read_cap('slow.example', 993), 900, 'the read cap stops at 900');
raise_server_read_cap('slow.example', 993);
is(server_read_cap('slow.example', 993), 900, 'another timeout leaves 900');
idle_sync_decision({ messages => 1 }, '* BYE AccessTokenExpired', 0);
is(server_read_cap('slow.example', 993), 900, 'a BYE does not raise the cap');

set_io_timeout_for_test(0.3);
my ($slow_rd, $slow_wr) = pair();
_note_fd_server($slow_rd, 'slow.example', 993);
my $slow_reader = bless { Socket => $slow_rd }, 'ImapidleClient';
$t0 = time();
is(imap_read_more($slow_reader, { error_on_timeout => 0 }, $slow_rd, 0.6), 0,
    'a mapped read can wait past the global cap');
my $slow_wait = time() - $t0;
cmp_ok($slow_wait, '>', 0.5, 'the learned cap overrides the global clamp');
cmp_ok($slow_wait, '<', 1.2, 'the caller timeout still ends the wait');
is(server_read_cap('slow.example', 993), 900, 'a quiet poll does not raise the cap');
_forget_fd_server($slow_rd);
close $slow_wr;
close $slow_rd;

my ($plain_rd, $plain_wr) = pair();
my $plain_reader = bless { Socket => $plain_rd }, 'ImapidleClient';
$t0 = time();
is(imap_read_more($plain_reader, { error_on_timeout => 0 }, $plain_rd, 2), 0,
    'an unmapped read still fails');
my $plain_wait = time() - $t0;
cmp_ok($plain_wait, '>', 0.2, 'an unmapped read waits out the global cap');
cmp_ok($plain_wait, '<', 1.2, 'an unmapped read does not use the caller timeout');
close $plain_wr;
close $plain_rd;
set_io_timeout_for_test($cap);

my %rows = load_learned();
delete $rows{'slow.example:993'}{io};
save_learned(%rows);
is(server_read_cap('slow.example', 993), 45, 'deleting io returns the cap to 45');
like(slurp($learned), qr/^slow\.example:993\tabsent$/m, 'deleting io keeps the NOTIFY record');

my ($dead_rd, $dead_wr) = pair();
print $dead_wr "* 1 EXISTS\r\n" or die "write: $!";
my $dead_reader = bless { Socket => $dead_rd }, 'ImapidleClient';
set_read_deadline_for_test(Time::HiRes::time() - 1);
$t0 = Time::HiRes::time();
is(imap_read_more($dead_reader, { error_on_timeout => 0 }, $dead_rd, 5), 0,
    'a command deadline ends the read');
cmp_ok(Time::HiRes::time() - $t0, '<', 0.5, 'untagged bytes do not extend that deadline');
clear_read_deadline_for_test();
close $dead_wr;
close $dead_rd;

done_testing;

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "read $path: $!";
    local $/;
    return scalar <$fh>;
}
