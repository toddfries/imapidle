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
use File::Temp qw(tempdir tempfile);
use Test::More;

require './imapidle';

my $dir = tempdir('imapidle-poll-XXXX', CLEANUP => 1, TMPDIR => 1);
set_runtime_dir_for_test($dir);
set_state_dir_for_test($dir);
set_learned_for_test("$dir/learned");
set_foreground_for_test(0);
clear_conns_for_test();
reset_schedule_for_test();

like(load_config(write_conf(<<'EOF')), qr/\[acct\] bad poll/, 'poll below 60 is rejected');
[acct]
type = account
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = ch
poll = 30

[acct-watch]
type = idle
channel = acct
folder0 = INBOX

EOF
like(load_config(write_conf(<<'EOF')), qr/\[acct\] bad poll/, 'a non-numeric poll is rejected');
[acct]
type = account
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = ch
poll = soon

[acct-watch]
type = idle
channel = acct
folder0 = INBOX

EOF
is(load_config(write_conf(<<'EOF')), '', 'an omitted poll loads');
[acct]
type = account
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = ch

[acct-watch]
type = idle
channel = acct
folder0 = INBOX

EOF
is(loaded_account('acct')->{poll}, 60, 'an omitted poll is 60 seconds');

is(load_config(write_conf(<<'EOF')), '', 'poll of 120 loads');
[acct]
type = account
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = ch
poll = 120

[acct-watch]
type = idle
channel = acct
folder0 = INBOX;priority=5
folder1 = Sent;priority=5

EOF
is(loaded_account('acct')->{poll}, 120, 'poll of 120 is stored');

my $neither = capture(sub {
    is(setup_notification('ma', { server => 'neither.example', port => 993 },
        bless({}, 'CapNeither'), []), 0, 'a server with neither extension does not arm NOTIFY');
});
is($neither, "imapidle: ma      : server does not advertise NOTIFY or IDLE, polling\n",
    'the first look logs polling');
like(slurp("$dir/learned"), qr/^neither\.example:993\tabsent\tcap_no_idle=1$/m,
    'neither extension stores cap_no_idle');
ok(server_needs_poll('neither.example', 993), 'that host polls');
my $neither_again = capture(sub {
    is(setup_notification('ma', { server => 'neither.example', port => 993 },
        bless({}, 'CapBoom'), []), 0, 'a cached poll host is not probed again');
});
is($neither_again, '', 'a repeated poll discovery is quiet');

my $idle_log = capture(sub {
    is(setup_notification('ma', { server => 'idle.example', port => 993 },
        bless({}, 'CapIdle'), []), 0, 'IDLE without NOTIFY does not arm NOTIFY');
});
is($idle_log, "imapidle: ma      : server does not advertise NOTIFY, using IDLE\n",
    'IDLE without NOTIFY still uses IDLE');
ok(!server_needs_poll('idle.example', 993), 'an IDLE server does not poll');
unlike(slurp("$dir/learned"), qr/idle\.example:993.*cap_no_idle/,
    'an IDLE server does not store cap_no_idle');

my $reject_log = capture(sub {
    is(setup_notification('ma', { server => 'rej.example', port => 993 },
        bless({}, 'CapReject'), []), 0, 'a rejected NOTIFY falls back');
});
like($reject_log, qr/NOTIFY rejected, falling back to IDLE/, 'the rejection still names IDLE');
unlike($reject_log, qr/polling/, 'a rejected NOTIFY is not a poll');
ok(!server_needs_poll('rej.example', 993), 'a rejected NOTIFY does not poll');
unlike(slurp("$dir/learned"), qr/rej\.example:993.*cap_no_idle/,
    'a rejected NOTIFY does not store cap_no_idle');

open my $old, '>>', "$dir/learned" or die "append learned: $!";
print $old "old.example:993\tabsent\n";
print $old "forced.example:993\trejected\tcap_no_idle=1\n";
print $old "quiet.example:993\tabsent\tcap_next=1\n";
close $old;
refresh_local_state();
ok(!server_needs_poll('old.example', 993), 'an old absent line stays on IDLE');
my $old_log = capture(sub {
    is(setup_notification('ma', { server => 'old.example', port => 993 },
        bless({}, 'CapBoom'), []), 0, 'an old absent line is not probed');
});
is($old_log, '', 'an old absent line does not log polling');
ok(!server_needs_poll('forced.example', 993), 'rejected stays off poll even with the bit');

my $switch = capture(sub {
    is(consider_capability('ma', bless({}, 'CapNeither'),
        'quiet.example', 993, [], time()), 0, 'a due absent host with neither extension does not arm NOTIFY');
});
is($switch, "imapidle: ma      : server does not advertise NOTIFY or IDLE, polling\n",
    'the first capability list on an old absent host logs polling once');
ok(server_needs_poll('quiet.example', 993), 'that host polls after the list is seen');
my $switch_again = capture(sub {
    consider_capability('ma', bless({}, 'CapBoom'), 'quiet.example', 993, [], time());
});
is($switch_again, '', 'the poll line is not repeated while the capability record is current');

clear_conns_for_test();
reset_schedule_for_test();
my $imap = PollIMAP->new(
    INBOX => '* STATUS "INBOX" (MESSAGES 3 UIDNEXT 10)',
    Sent  => '* STATUS "Sent" (MESSAGES 1 UIDNEXT 4)',
);
my $key = plant_poll_for_test('acct');
my $conn = set_conn_imap_for_test($key, $imap);
ok($conn, 'a poll connection can be planted');
ok(account_covered('acct'), 'one poll connection covers every folder');
is(restart_idle($conn), 1, 'a poll connection is not re-armed');
is(restart_idle(undef), 1, 'a missing connection is not an error');
is($imap->{idle}, 0, 'IDLE is not sent on a poll connection');
is($imap->{done}, 0, 'DONE is not sent on a poll connection');

my $t0 = time();
my $base = capture(sub { _poll_conn($conn, $t0) });
is($base, '', 'the first look is quiet');
ok(!defined schedule_deadline('ch'), 'the first look does not schedule mbsync');
cmp_ok($conn->{poll_next} - $t0, '>=', 119, 'the next poll is about 120 seconds out');
cmp_ok($conn->{poll_next} - $t0, '<=', 121, 'the poll gap is the account value');
is(scalar @{ $imap->{cmds} }, 2, 'each configured folder is asked once');
like($imap->{cmds}[0], qr/^STATUS "INBOX" \(MESSAGES UIDNEXT\)$/, 'STATUS asks for both counts');

$imap->{replies}{Sent} = '* STATUS "Sent" (MESSAGES 1 UIDNEXT 9)';
$conn->{poll_next} = 0;
my $ready = capture(sub { _poll_conn($conn, $t0) });
like($ready, qr/acct +: ready +Sent /, 'a new UIDNEXT is ready');
ok(defined schedule_deadline('ch'), 'a changed folder is scheduled');
my @jobs = due_mbsync_jobs($t0 + 5);
is_deeply(\@jobs, [ { args => ['ch:Sent'], wait => 0 } ], 'only the changed folder is due');
ok(!defined schedule_deadline('ch'), 'taking the job clears the deadline');

$conn->{poll_next} = 0;
my $same = capture(sub { _poll_conn($conn, $t0 + 6) });
is($same, '', 'unchanged counts stay quiet');
ok(!defined schedule_deadline('ch'), 'unchanged counts do not schedule mbsync');

$imap->{replies}{INBOX} = '* STATUS "INBOX" (MESSAGES 2 UIDNEXT 10)';
$conn->{poll_next} = 0;
my $drop = capture(sub { _poll_conn($conn, $t0 + 6 + 420) });
like($drop, qr/acct +: ready +INBOX /, 'a dropped message count is ready after the gap');
ok(defined schedule_deadline('ch'), 'a smaller message count schedules mbsync');
reset_schedule_for_test();

my $soon = time();
$conn->{poll_next} = $soon + 10;
my $wait = loop_timeout();
cmp_ok($wait, '>=', 8, 'a future poll wakes the loop');
cmp_ok($wait, '<=', 10, 'the loop does not sleep past that poll') or diag($wait);
$conn->{poll_next} = $soon - 5;
my $overdue = loop_timeout();
cmp_ok($overdue, '>=', 29, 'an overdue poll does not busy-poll');
cmp_ok($overdue, '<=', 30, 'an overdue poll keeps the 30 second cap') or diag($overdue);

my @info = info_lines($soon);
is($info[1], 'acct: POLL server imap.example.com channel ch', 'state names POLL');

_retarget_conns('acct', loaded_account('acct'), {
    folders        => [ { name => 'INBOX' }, { name => 'Sent' }, { name => 'Archive' } ],
    wait           => 3,
    mbsync_channel => 'other',
});
is($conn->{channel}, 'other', 'reload retargets the poll channel');
is($conn->{wait}, 3, 'reload retargets the poll wait');
is(scalar @{ $conn->{folders} }, 3, 'reload retargets the poll folders');

$imap->{die} = 1;
$conn->{poll_next} = 0;
my $failed = capture(sub { _poll_conn($conn, time()) });
like($failed, qr/acct +: poll failed:/, 'a failed STATUS is logged');
like($failed, qr/dropping POLL: poll failed/, 'the poll connection is dropped');
ok(!conn_exists_for_test('acct:POLL'), 'a failed poll leaves no connection');
is(conn_count(), 0, 'a failed poll does not keep the socket');
cmp_ok(account_next_try('acct'), '>', time() - 1, 'the account is parked for retry');

clear_conns_for_test();
note_success('acct');
set_learned_for_test("$dir/clocks");
open my $clocks, '>', "$dir/clocks" or die "clocks: $!";
print $clocks "imap.example.com:993\tabsent\t"
    . "id_hash=abc\tid_next=9999999999\tid_status=ok\t"
    . "cap_next=9999999999\tcap_no_idle=1\n";
close $clocks;
set_list_next_for_test('ch', time() + 100000);
my $quiet_imap = PollIMAP->new(
    INBOX => '* STATUS "INBOX" (MESSAGES 3 UIDNEXT 10)',
    Sent  => '* STATUS "Sent" (MESSAGES 1 UIDNEXT 4)',
);
my $quiet_key = plant_poll_for_test('acct');
my $quiet = set_conn_imap_for_test($quiet_key, $quiet_imap);
$quiet->{poll_next} = time() + 50;
capture(sub { housekeeping() });
is($quiet_imap->{noop}, 0, 'a poll connection is not sent NOOP');
is($quiet_imap->{idle}, 0, 'housekeeping does not IDLE a poll connection');
is($quiet_imap->{done}, 0, 'housekeeping does not DONE a poll connection');
is(scalar @{ $quiet_imap->{cmds} }, 0, 'a future poll is not asked early');
ok(conn_exists_for_test('acct:POLL'), 'the poll connection stays up');
$quiet->{poll_next} = 0;
capture(sub { housekeeping() });
is(scalar @{ $quiet_imap->{cmds} }, 2, 'a due poll asks each folder');
is($quiet_imap->{noop}, 0, 'the due poll still does not NOOP');
cmp_ok($quiet->{poll_next}, '>', time(), 'the poll clock moves forward before the next wake');

set_foreground_for_test(0);
done_testing;

sub write_conf {
    my ($body) = @_;
    my ($fh, $path) = tempfile('imapidle-poll-XXXX', SUFFIX => '.conf', TMPDIR => 1);
    print $fh $body;
    close $fh;
    return $path;
}

sub capture {
    my ($code) = @_;
    my ($fh, $errpath) = tempfile('imapidle-poll-err-XXXX', UNLINK => 1, TMPDIR => 1);
    close $fh;
    open my $old, '>&', \*STDERR or die "dup stderr: $!";
    open STDERR, '>', $errpath or die "redirect stderr: $!";
    set_foreground_for_test(1);
    my $err;
    eval { $code->(); 1 } or $err = $@;
    set_foreground_for_test(0);
    open STDERR, '>&', $old or die "restore stderr: $!";
    close $old;
    open my $in, '<', $errpath or die "read stderr: $!";
    local $/;
    my $buf = <$in> // '';
    close $in;
    die $err if $err;
    return $buf;
}

sub slurp {
    my ($file) = @_;
    open my $in, '<', $file or die "read $file: $!";
    local $/;
    return scalar <$in>;
}

package CapBoom;
sub capability { die "probed\n"; }
sub tag_and_run { die "probed\n"; }

package CapNeither;
sub capability { return qw(IMAP4rev1); }
sub tag_and_run { die "command sent without NOTIFY or IDLE\n"; }

package CapIdle;
sub capability { return qw(IMAP4rev1 IDLE); }
sub tag_and_run { die "NOTIFY was sent without an advertisement\n"; }

package CapReject;
sub capability { return qw(IMAP4rev1 NOTIFY); }
sub tag_and_run {
    my (undef, $cmd) = @_;
    return 'A5 BAD NOTIFY unavailable.';
}

package PollIMAP;
sub new {
    my ($class, %replies) = @_;
    return bless {
        replies => \%replies,
        cmds    => [],
        die     => 0,
        noop    => 0,
        idle    => 0,
        done    => 0,
        up      => 1,
    }, $class;
}
sub IsConnected { $_[0]{up} }
sub LastError   { '' }
sub noop { $_[0]{noop}++; die "noop\n" }
sub idle { $_[0]{idle}++; die "idle\n" }
sub done { $_[0]{done}++; die "done\n" }
sub logout { }
sub capability { die "capability\n" }
sub folders_hash { die "LIST\n" }
sub tag_and_run {
    my ($self, $cmd) = @_;
    push @{ $self->{cmds} }, $cmd;
    die "STATUS broke\n" if $self->{die};
    my ($box) = $cmd =~ /STATUS "((?:\\.|[^"\\])*)"/;
    $box =~ s/\\"/"/g if defined $box;
    $box =~ s/\\\\/\\/g if defined $box;
    my $line = $self->{replies}{$box // ''};
    return defined $line ? $line : ();
}

package main;
