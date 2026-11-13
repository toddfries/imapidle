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
use File::Temp qw(tempfile);
use Test::More;

require './imapidle';

my ($fh, $path) = tempfile('imapidle-XXXX', SUFFIX => '.conf', TMPDIR => 1);
print $fh <<'EOF';
[acct]
type = idle
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = ch
folder0 = INBOX;priority=5
EOF
close $fh;

sub stderr_of {
    my ($code) = @_;
    my ($out, $file) = tempfile('imapidle-err-XXXX', TMPDIR => 1);
    close $out;
    open my $old, '>&', STDERR or die "dup stderr: $!";
    open STDERR, '>', $file or die "redirect stderr: $!";
    my $ok = eval { $code->(); 1 };
    my $err = $@;
    open STDERR, '>&', $old or die "restore stderr: $!";
    open my $in, '<', $file or die "read stderr: $!";
    local $/;
    my $buf = <$in> // '';
    close $in;
    unlink $file;
    die $err unless $ok;
    return $buf;
}

is(load_config($path), '', 'config loads');
clear_conns_for_test();
reset_schedule_for_test();
set_foreground_for_test(1);

my $limit = start_give_up();
my $gave_up = stderr_of(sub {
    mark_retry('acct') for 1 .. $limit;
});
like($gave_up, qr/acct    : retry in 5s/, 'the first failure is retried');
like($gave_up, qr/acct    : disabled after $limit failures, back in 1800s at \d{8} \d{2}:\d{2}:\d{2}\.\d{6}/,
    'the limit pauses the account for 30 minutes');
unlike($gave_up, qr/retry in 27s/, 'the pausing failure does not schedule another short retry');
ok(loaded_account('acct')->{disabled}, 'the account is paused');
is(loaded_account('acct')->{backoff}, 5, 'the connect backoff is reset');
is(loaded_account('acct')->{fails}, 0, 'the failure count is reset');
is(loaded_account('acct')->{disable_for}, 2700, 'the next pause is 45 minutes');
my $now = time();
my $left = int(account_next_try('acct') - $now);
ok($left == 1800 || $left == 1799, 'the pause is 1800 seconds');
my @info = info_lines($now);
is($info[1], "acct: disabled server imap.example.com channel ch back in ${left}s",
    'state names the pause and how long is left');
is(loop_timeout(), 30, 'a long pause does not shorten the 30s wait');
my $hold = account_next_try('acct');
set_next_try_for_test('acct', time() + 10);
my $woke = loop_timeout();
ok($woke >= 8 && $woke <= 10, 'a pause shorter than 30s wakes the loop') or diag($woke);
set_next_try_for_test('acct', $hold);

my $ended = stderr_of(sub {
    ok(lift_account_disable('acct', $hold), 'the pause ends on its clock');
});
like($ended, qr/acct    : backoff reset/, 'the end of the pause resets the backoff');
ok(!loaded_account('acct')->{disabled}, 'the account tries again');
my $again = stderr_of(sub {
    mark_retry('acct') for 1 .. $limit;
});
like($again, qr/back in 2700s at /, 'the second pause is one and a half times 30 minutes');
is(loaded_account('acct')->{disable_for}, 4050, 'the pause keeps growing by half');

note_success('acct');
ok(!defined loaded_account('acct')->{disable_for}, 'a successful monitor clears the pause ladder');
set_monitored_for_test('acct', 0);
my $restarted = stderr_of(sub {
    mark_retry('acct') for 1 .. $limit;
});
like($restarted, qr/back in 1800s at /, 'the ladder starts over after a success');

my $step = 1800;
my @steps = ($step);
for (1 .. 12) {
    my $n = next_disable_for($step);
    last if $n == $step;
    push @steps, $n;
    $step = $n;
}
is_deeply(\@steps, [1800, 2700, 4050, 6075, 9113, 13670, 20505, 30758],
    'the pause grows by half and stops before 12 hours');
is(next_disable_for(30758), 30758, 'the last step under 12 hours is repeated');
cmp_ok(int(30758 * 1.5 + 0.5), '>', disable_ceiling(),
    'the following step would pass 12 hours');

my $enabled = stderr_of(sub {
    is(reload_config_now($path), '', 'reload accepts the same file');
});
like($enabled, qr/acct    : enabled/, 'SIGHUP enables the account');
ok(!loaded_account('acct')->{disabled}, 'the account is no longer disabled');
is(loaded_account('acct')->{fails}, 0, 'the failure count starts over');
ok(!defined loaded_account('acct')->{disable_for}, 'SIGHUP starts the pause ladder over');
my $after_hup = stderr_of(sub {
    mark_retry('acct') for 1 .. $limit;
});
like($after_hup, qr/back in 1800s at /, 'the next pause after SIGHUP is 30 minutes');

note_success('acct');
stderr_of(sub {
    mark_retry('acct') for 1 .. ($limit + 3);
});
ok(!loaded_account('acct')->{disabled}, 'an account that has monitored keeps retrying');
ok(account_next_try('acct') > time(), 'that account still has a retry time');
my @later = info_lines(time());
like($later[1], qr/^acct: down server imap\.example\.com channel ch retry \d+s$/,
    'a retrying account is down, not disabled');

clear_conns_for_test();
set_foreground_for_test(0);
is(load_config($path), '', 'reload a fresh account for the partial case');
plant_idle_for_test('acct', 'INBOX', 420, 'ch');
stderr_of(sub {
    mark_retry('acct') for 1 .. $limit;
});
ok(conn_exists_for_test('acct:INBOX'), 'a connection already up is left in place');
my $partial_now = time();
my $partial_left = int(account_next_try('acct') - $partial_now);
my @partial = info_lines($partial_now);
is($partial[1], "acct: IDLE INBOX disabled server imap.example.com channel ch back in ${partial_left}s",
    'a partial account shows the open mailbox and the pause');

set_foreground_for_test(0);

sub write_conf {
    my ($body) = @_;
    my ($out, $file) = tempfile('imapidle-XXXX', SUFFIX => '.conf', TMPDIR => 1);
    print $out $body;
    close $out;
    return $file;
}

my $on = write_conf(<<'EOF');
[acct]
type = idle
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = ch
folder0 = INBOX
EOF
my $off = write_conf(<<'EOF');
[acct]
type = idle
disabled = yes
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = ch
folder0 = INBOX
EOF
clear_conns_for_test();
is(load_config($on), '', 'enabled file loads for the flag');
plant_idle_for_test('acct', 'INBOX', 420, 'ch');
set_foreground_for_test(1);
my $flagged = stderr_of(sub {
    is(reload_config_now($off), '', 'reload accepts disabled = yes');
});
like($flagged, qr/acct    : disabled/, 'the flag disables the running section');
ok(!conn_exists_for_test('acct:INBOX'), 'the open connection is dropped');
ok(loaded_account('acct')->{config_disabled}, 'the flag stays on the account');
my $stay = stderr_of(sub {
    is(reload_config_now($off), '', 'reloading the flag again is accepted');
});
unlike($stay, qr/acct    : enabled/, 'the flag is not cleared by another reload');
ok(loaded_account('acct')->{config_disabled}, 'the section remains disabled');
set_foreground_for_test(1);
my $back = stderr_of(sub {
    is(reload_config_now($on), '', 'removing yes enables the section');
});
like($back, qr/acct    : enabled/, 'removing the flag is logged');
ok(!loaded_account('acct')->{disabled}, 'the section is active again');
is(account_next_try('acct'), 0, 'the enabled section is due to connect');
set_foreground_for_test(0);
unlink $on, $off;

clear_conns_for_test();
is(load_config($path), '', 'fresh account for a dead idle session');

package DeadIMAP;
sub new { bless { calls => [] }, shift }
sub IsConnected { 0 }
sub done   { push @{ $_[0]{calls} }, 'done';   die "done\n" }
sub idle   { push @{ $_[0]{calls} }, 'idle';   die "idle\n" }
sub logout { push @{ $_[0]{calls} }, 'logout'; die "logout\n" }
sub LastError { 'NO not connected' }

package DropIMAP;
sub new { bless { up => 1, calls => [], err => '' }, shift }
sub IsConnected { $_[0]{up} }
sub done {
    my ($self) = @_;
    push @{ $self->{calls} }, 'done';
    $self->{up}  = 0;
    $self->{err} = 'socket closed while reading data from server';
    return;
}
sub idle   { push @{ $_[0]{calls} }, 'idle';   die "idle\n" }
sub logout { push @{ $_[0]{calls} }, 'logout'; die "logout\n" }
sub LastError { $_[0]{err} }

package LiveIMAP;
sub new { bless { calls => [] }, shift }
sub IsConnected { 1 }
sub done   { push @{ $_[0]{calls} }, 'done';   return '* OK' }
sub idle   { push @{ $_[0]{calls} }, 'idle';   return 41 }
sub logout { push @{ $_[0]{calls} }, 'logout'; return 1 }
sub LastError { }

package Sock;
sub new { bless { closed => 0 }, shift }
sub close { $_[0]{closed} = 1 }

package main;

my $dead = DeadIMAP->new;
my $dead_conn = { name => 'acct', mode => 'IDLE', tag => '40', imap => $dead };
set_foreground_for_test(1);
my $dead_log = stderr_of(sub {
    ok(!restart_idle($dead_conn), 'a dead IDLE session does not re-arm');
});
is_deeply($dead->{calls}, [], 'DONE and IDLE are not sent on a dead session');
like($dead_log, qr/acct +: idle re-arm failed: not connected/,
    'a dead re-arm is one warning');
unlike($dead_log, qr/Trying command when NOT connected|IMAPClient\.pm/,
    'a dead re-arm does not dump the library stack');

my $drop = DropIMAP->new;
my $drop_conn = { name => 'acct', mode => 'IDLE', tag => '40', imap => $drop };
my $drop_log = stderr_of(sub {
    ok(!restart_idle($drop_conn), 'a DONE that loses the socket does not send IDLE');
});
is_deeply($drop->{calls}, ['done'], 'IDLE is not sent after the socket dies');
like($drop_log, qr/idle re-arm failed: socket closed while reading data from server/,
    'the DONE error is the re-arm warning');
my $sock = Sock->new;
stderr_of(sub { close_session($drop, $sock) });
is_deeply($drop->{calls}, ['done'], 'LOGOUT is not sent on a dead session');
is($sock->{closed}, 1, 'the local socket is still closed');

my $live = LiveIMAP->new;
my $live_conn = { name => 'acct', mode => 'IDLE', tag => '40', imap => $live };
ok(restart_idle($live_conn), 'a live session re-arms');
is_deeply($live->{calls}, [qw(done idle)], 'a live re-arm sends DONE then IDLE');
is($live_conn->{tag}, 41, 'the new IDLE tag is kept');
my $live_sock = Sock->new;
stderr_of(sub { close_session($live, $live_sock) });
is_deeply($live->{calls}, [qw(done idle logout)], 'a live session still logs out');

my $key = plant_idle_for_test('acct', 'INBOX', 420, 'ch');
my $held = DeadIMAP->new;
set_conn_imap_for_test($key, $held, '40');
my $gone = stderr_of(sub { drop_conn($key, 'idle refresh failed') });
is_deeply($held->{calls}, [], 'dropping a dead session sends no IMAP command');
like($gone, qr/acct +: dropping INBOX: idle refresh failed/,
    'the drop is still logged');
like($gone, qr/acct +: retry in \d+s/, 'the account still retries');
unlike($gone, qr/Trying command when NOT connected|IMAPClient\.pm/,
    'the drop does not dump the library stack');
set_foreground_for_test(0);

done_testing;
