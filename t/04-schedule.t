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
use File::Temp qw(tempfile tempdir);
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use Test::More;

require './imapidle';

sub jobs {
    my ($now) = @_;
    return map { join(' ', @{ $_->{args} }) . ' wait=' . $_->{wait} } due_mbsync_jobs($now);
}

reset_schedule_for_test();
note_mail_event('ch1', 'INBOX', 420, 0, 1000);
is(schedule_deadline('ch1'), 1005, 'first ready event waits 5s');
is_deeply([jobs(1004)], [], 'nothing runs before the 5s window ends');
is_deeply([jobs(1005)], ['ch1:INBOX wait=0'], 'mbsync runs when the 5s ends');

reset_schedule_for_test();
note_mail_event('ch1', 'INBOX', 420, 2, 1000);
note_mail_event('ch1', 'Archive', 8, 9, 1004);
is(schedule_deadline('ch1'), 1005, 'a later event joins and does not restart the 5s');
is_deeply(
    [jobs(1005)],
    ['ch1:Archive ch1:INBOX wait=9'],
    'one invocation lists every ready box on the channel',
);

# The run above was at 1005. Another INBOX event inside 420s is kept.
note_mail_event('ch1', 'INBOX', 420, 0, 1100);
ok(!defined schedule_deadline('ch1'), 'an event inside the minimum gap does not open a window');
is_deeply([jobs(1424)], [], 'the kept event does not run early');
is_deeply([jobs(1425)], ['ch1:INBOX wait=0'], 'the kept event runs when the 420s end');

# Quiet gap: the folder is ready, so the next event uses the 5s wait.
is_deeply([jobs(2000)], [], 'no event during the gap schedules nothing');
note_mail_event('ch1', 'INBOX', 420, 0, 2000);
is(schedule_deadline('ch1'), 2005, 'a later event on a ready folder waits 5s');
is_deeply([jobs(2005)], ['ch1:INBOX wait=0'], 'that ready event then runs');

reset_schedule_for_test();
note_mail_event('ch1', 'INBOX', 420, 0, 1000);
note_mail_event('ch2', 'INBOX', 420, 0, 1000);
is_deeply(
    [jobs(1005)],
    ['ch1:INBOX wait=0', 'ch2:INBOX wait=0'],
    'different channels stay separate invocations',
);

# INBOX ran at 1005 in the previous case. Rebuild a gap and overlap it
# with another folder's 5s window.
reset_schedule_for_test();
note_mail_event('ch1', 'INBOX', 420, 0, 1000);
is_deeply([jobs(1005)], ['ch1:INBOX wait=0'], 'prime INBOX run at 1005');
note_mail_event('ch1', 'INBOX', 420, 0, 1100);
note_mail_event('ch1', 'Archive', 8, 0, 1422);
is(schedule_deadline('ch1'), 1427, 'Archive opens the combine window');
is_deeply([jobs(1424)], [], 'INBOX is not due yet and Archive is still combining');
is_deeply([jobs(1425)], [], 'INBOX joins the open window instead of running alone');
is_deeply(
    [jobs(1427)],
    ['ch1:Archive ch1:INBOX wait=0'],
    'the kept INBOX event and Archive share the invocation',
);

my $idle = { mode => 'IDLE', folder => 'INBOX', debounce => 420, channel => 'ch1', wait => 0 };
is_deeply([folders_for_lines($idle, '* 1 EXISTS')], ['INBOX'], 'IDLE event is that folder');

my $notify = {
    mode    => 'NOTIFY',
    channel => 'ch1',
    folders => [
        { name => 'INBOX',   debounce => 420 },
        { name => 'Archive', debounce => 3600 },
    ],
};
is_deeply(
    [folders_for_lines($notify, '* STATUS INBOX (MESSAGES 2)')],
    ['INBOX'],
    'NOTIFY STATUS names one folder',
);
is_deeply(
    [folders_for_lines($notify, '* 1 EXISTS')],
    ['Archive', 'INBOX'],
    'NOTIFY without a mailbox schedules every configured folder',
);

ok(mail_event_line('* 1 EXISTS'), 'EXISTS is mail');
ok(mail_event_line('* 12 FETCH (FLAGS (\Seen))'), 'FETCH is still a mailbox notice');
ok(mail_event_line('* STATUS INBOX (MESSAGES 2)'), 'STATUS is mail');
ok(!mail_event_line('* OK Still here'), 'IDLE keepalive is not mail');
ok(!mail_event_line('+ idling'), 'IDLE continuation is not mail');
ok(!mail_event_line('a001 OK IDLE completed'), 'tagged reply is not mail');

is(_clock(1425.25), _clock(1425) =~ s/\.000000\z/.250000/r,
    'subseconds are six digits after the seconds');
is(_clock(1425.9999996), _clock(1426), 'a fraction that rounds up carries into the next second');

reset_schedule_for_test();
is_deeply([jobs(1005)], [], 'no run is queued yet');
set_foreground_for_test(1);
my $ready = capture(sub { note_mail_event('ch1', 'INBOX', 420, 0, 1000); });
set_foreground_for_test(0);
like($ready, qr/ch1 +: ready INBOX mbsync combines in 5s at \Q@{[_clock(1005)]}\E/,
    'a ready event names the action, then the folder and the clock time');
is_deeply([jobs(1005)], ['ch1:INBOX wait=0'], 'the gap clock starts at the run');
set_foreground_for_test(1);
my $kept = capture(sub { note_mail_event('ch1', 'INBOX', 420, 0, 1100); });
set_foreground_for_test(0);
like($kept, qr/ch1 +: kept  INBOX next sync in 325s at \Q@{[_clock(1425)]}\E/,
    'a kept event names the action, then the folder and the clock time');

my $box = { messages => 10 };
ok(!idle_sync_decision($box, '* 4 EXPUNGE', 0), 'a removal does not sync');
is($box->{messages}, 9, 'a removal lowers the remembered total');
ok(idle_sync_decision($box, '* 10 EXISTS', 0), 'an arrival back to the old total still syncs');
is($box->{messages}, 10, 'the arrival is the new total');
ok(!idle_sync_decision($box, '* 10 EXISTS', 0), 'the same total does not sync again');
ok(!idle_sync_decision($box, '* 2 FETCH (FLAGS (\Seen))', 0), 'a flag update does not sync');
is($box->{messages}, 10, 'a flag update leaves the total');
ok(!idle_sync_decision($box, '* 1 RECENT', 0), 'RECENT does not sync');
ok(idle_sync_decision($box, '* 3 EXPUNGE', 1), 'hyperdelete syncs a removal');
is($box->{messages}, 9, 'hyperdelete still lowers the total');

my $gone = { messages => 10 };
ok(!idle_sync_decision($gone, '* VANISHED 8:10', 0), 'VANISHED does not sync');
is($gone->{messages}, 7, 'VANISHED lowers the total by the uid span');
ok(idle_sync_decision($gone, '* 8 EXISTS', 0), 'EXISTS above the lowered total syncs');
my $hist = { messages => 10 };
ok(!idle_sync_decision($hist, '* VANISHED (EARLIER) 1:3', 0),
    'an earlier vanished set is history');
is($hist->{messages}, 10, 'history does not change the total');

my $lost = { messages => 10 };
ok(!idle_sync_decision($lost, '* VANISHED *', 0), 'an open uid set does not sync');
ok(!defined $lost->{messages}, 'an open uid set forgets the total');
ok(idle_sync_decision($lost, '* 9 EXISTS', 0), 'the next total syncs once');
is($lost->{messages}, 9, 'that total is the new baseline');

my $shrink = { messages => 10 };
ok(idle_sync_decision($shrink, '* 8 EXISTS', 1), 'hyperdelete syncs a smaller total');
is($shrink->{messages}, 8, 'the smaller total is remembered');

my $quiet = { mode => 'IDLE', messages => 4 };
my @quiet = _idle_mail_lines($quiet, '* 1 EXPUNGE', '* 1 FETCH (FLAGS (\Seen))');
is(scalar @quiet, 0, 'an IDLE folder leaves a removal and a flag change');
is($quiet->{messages}, 3, 'the IDLE removal is still remembered');
my $noted = { mode => 'NOTIFY', messages => 4 };
my @noted = _idle_mail_lines($noted, '* 1 FETCH (FLAGS (\Seen))');
is(scalar @noted, 1, 'NOTIFY still treats a flag change as mail');

my $fresh = {};
ok(!idle_sync_decision($fresh, '* 4 EXISTS', 0), 'the first total is a baseline');
is($fresh->{messages}, 4, 'the baseline is remembered');
ok(idle_sync_decision($fresh, '* 5 EXISTS', 0), 'a higher total syncs');

reset_schedule_for_test();
my $aged = tempdir('imapidle-age-XXXX', CLEANUP => 1, TMPDIR => 1);
set_runtime_dir_for_test($aged);
set_state_dir_for_test($aged);
set_learned_for_test("$aged/learned");
set_foreground_for_test(0);
my ($cfh, $cpath) = tempfile('imapidle-age-XXXX', SUFFIX => '.conf', TMPDIR => 1);
print $cfh <<'EOF';
[acct]
type = account
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = ch
hyperdelete = yes

[acct-watch]
type = idle
channel = acct
folder0 = INBOX;5;3600

EOF
close $cfh;
is(load_config($cpath), '', 'the resync config loads');
my $from_acct = { mode => 'IDLE', name => 'acct', messages => 4 };
my @from_acct = _idle_mail_lines($from_acct, '* 2 EXPUNGE');
is(scalar @from_acct, 1, 'the account hyperdelete syncs a removal');
is($from_acct->{messages}, 3, 'that removal lowers the IDLE total');
note_mail_event('ch', 'INBOX', 420, 0, 1000);
is_deeply([jobs(1005)], ['ch:INBOX wait=0'], 'the first run still waits out the combine window');
is_deeply([jobs(4604)], [], 'the resync ceiling has not elapsed');
is_deeply([jobs(4605)], [], 'the ceiling opens the combine window');
is_deeply([jobs(4610)], ['ch:INBOX wait=0'], 'the folder syncs when the ceiling elapses');

is_deeply(
    [count_follow_decision({ messages => 10, uidnext => 30, chase => 0 }, 12, 40)],
    [1, 0],
    'a higher total after sync schedules',
);
is_deeply(
    [count_follow_decision({ messages => 10, uidnext => 30, chase => 0 }, 10, 31)],
    [1, 1],
    'a new UIDNEXT schedules one confirmation',
);
is_deeply(
    [count_follow_decision({ messages => 10, uidnext => 30, chase => 1 }, 10, 32)],
    [0, 0],
    'a second UIDNEXT bump does not schedule',
);
is_deeply(
    [count_follow_decision({ messages => 10, uidnext => 30, chase => 1 }, 11, 32)],
    [1, 0],
    'mail during the confirmation still schedules',
);
is_deeply(
    [count_follow_decision({ messages => 10, uidnext => 30, chase => 0 }, 9, 31)],
    [1, 1],
    'a new UIDNEXT with a lower total confirms once',
);
is_deeply(
    [count_follow_decision({ messages => 10, uidnext => 30, chase => 0 }, 9, 30)],
    [0, 0],
    'a lower total alone does not schedule',
);
is_deeply(
    [count_follow_decision({ chase => 0 }, 4, 8)],
    [0, 0],
    'a first sample learns the numbers',
);

{
    package AfterStatusIMAP;
    sub new {
        my ($class, $lines) = @_;
        return bless { lines => $lines, cmds => [], idle => 0, done => 0 }, $class;
    }
    sub IsConnected { 1 }
    sub LastError   { '' }
    sub Results     { return ('* 10 EXISTS', '* OK [UIDNEXT 30] Predicted next UID'); }
    sub done        { $_[0]->{done}++; return 'A1 OK DONE'; }
    sub idle        { $_[0]->{idle}++; return 'A2'; }
    sub tag_and_run {
        my ($self, $cmd) = @_;
        push @{ $self->{cmds} }, $cmd;
        return @{ $self->{lines} };
    }
}
package main;

is(selected_uidnext(AfterStatusIMAP->new([])), 30, 'SELECT UIDNEXT is remembered');

reset_schedule_for_test();
clear_conns_for_test();
my $akey = plant_idle_for_test('acct', 'INBOX', 420, 'ch');
my $aimap = AfterStatusIMAP->new(['* STATUS "INBOX" (MESSAGES 12 UIDNEXT 40)', 'A OK']);
my $aconn = set_conn_imap_for_test($akey, $aimap, 'T1');
$aconn->{idling}   = 1;
$aconn->{messages} = 10;
$aconn->{uidnext}  = 30;
settle_counts_after({
    count_snap => {
        "ch\0INBOX" => { channel => 'ch', box => 'INBOX', messages => 10, uidnext => 30, chase => 0 },
    },
});
is($aconn->{messages}, 12, 'the after-sync total replaces the remembered one');
is($aconn->{uidnext}, 40, 'the after-sync UIDNEXT is remembered');
ok(defined schedule_deadline('ch'), 'a higher total queues another sync');
is($aimap->{done}, 1, 'IDLE is paused for the after-sync STATUS');
is($aimap->{idle}, 1, 'IDLE resumes after the after-sync STATUS');
like($aimap->{cmds}[0], qr/^STATUS "INBOX" \(MESSAGES UIDNEXT\)$/, 'STATUS asks for both numbers');

reset_schedule_for_test();
$aconn->{uidnext_chase} = 1;
my $taken = _folder_count_snaps('ch:INBOX');
is($taken->{"ch\0INBOX"}{chase}, 1, 'the forked run records the confirmation');
is($taken->{"ch\0INBOX"}{messages}, 12, 'the fork copies the remembered total');
ok(!_chase_on($aconn, 'INBOX'), 'taking the copy spends the confirmation');
is_deeply(_folder_count_snaps('ch'), {}, 'a whole-channel run has no folder count');

reset_schedule_for_test();
$aimap->{lines} = ['* STATUS "INBOX" (MESSAGES 12 UIDNEXT 41)', 'A OK'];
settle_counts_after({
    count_snap => {
        "ch\0INBOX" => { channel => 'ch', box => 'INBOX', messages => 12, uidnext => 40, chase => 1 },
    },
});
is($aconn->{uidnext}, 41, 'the confirmation stores the new UIDNEXT');
ok(!_chase_on($aconn, 'INBOX'), 'the confirmation does not arm another one');
ok(!defined schedule_deadline('ch'), 'a repeated UIDNEXT bump does not queue');

reset_schedule_for_test();
$aimap->{lines} = ['* STATUS "INBOX" (MESSAGES 9 UIDNEXT 42)', 'A OK'];
settle_counts_after({
    count_snap => {
        "ch\0INBOX" => { channel => 'ch', box => 'INBOX', messages => 12, uidnext => 41, chase => 0 },
    },
});
is($aconn->{messages}, 9, 'a lower total is stored');
ok(defined schedule_deadline('ch'), 'that lower total still confirms a new UIDNEXT once');
ok(_chase_on($aconn, 'INBOX'), 'the confirmation is armed');

clear_conns_for_test();
reset_schedule_for_test();
my $pkey = plant_idle_for_test('acct', 'INBOX', 420, 'ch');
my $pmap = AfterStatusIMAP->new(['* STATUS "INBOX" (MESSAGES 4 UIDNEXT 8)', 'A OK']);
my $pconn = set_conn_imap_for_test($pkey, $pmap, 'T2');
$pconn->{mode}    = 'POLL';
$pconn->{idling}  = 0;
$pconn->{folders} = [ { name => 'INBOX', debounce => 420 } ];
$pconn->{seen}    = { INBOX => { messages => 4, uidnext => 7 } };
settle_counts_after({
    count_snap => {
        "ch\0INBOX" => { channel => 'ch', box => 'INBOX', messages => 4, uidnext => 7, chase => 0 },
    },
});
is($pconn->{seen}{INBOX}{uidnext}, 8, 'a poll folder stores the after-sync UIDNEXT');
is($pmap->{done}, 0, 'a poll connection does not leave IDLE');
ok(_chase_on($pconn, 'INBOX'), 'the poll folder arms one confirmation');
ok(defined schedule_deadline('ch'), 'the poll folder queues that confirmation');

clear_conns_for_test();
reset_schedule_for_test();

sub arm_exists {
    my ($n) = @_;
    socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
    my $imap = ExistsIMAP->new($n);
    my $acc = loaded_account('acct');
    my $folder = $acc->{folders}[0];
    arm_idle('acct', $acc, $folder, $a, $imap);
    close $b;
    return "acct:$folder->{name}";
}

my $gap_key = arm_exists(4);
ok(!defined schedule_deadline('ch'), 'the first SELECT total is a baseline');
drop_conn($gap_key, 'test', 1);
$gap_key = arm_exists(4);
ok(!defined schedule_deadline('ch'), 'the same SELECT total does not schedule');
drop_conn($gap_key, 'test', 1);
$gap_key = arm_exists(3);
ok(!defined schedule_deadline('ch'), 'a lower SELECT total does not schedule');
drop_conn($gap_key, 'test', 1);
$gap_key = arm_exists(6);
ok(defined schedule_deadline('ch'), 'a higher SELECT total schedules one sync');
drop_conn($gap_key, 'test', 1);

done_testing;

package ExistsIMAP;
sub new {
    my ($class, $n) = @_;
    return bless { n => $n, up => 1 }, $class;
}
sub IsConnected { $_[0]{up} }
sub idle        { 'A1' }
sub Results     { return ("* $_[0]{n} EXISTS") }
sub done        { return ('A1 OK') }
sub logout      { $_[0]{up} = 0 }
sub LastError   { '' }

package main;

sub capture {
    my ($code) = @_;
    my ($fh, $path) = tempfile('imapidle-sched-XXXX', UNLINK => 1, TMPDIR => 1);
    close $fh;
    open my $old, '>&', \*STDERR or die "dup stderr: $!";
    open STDERR, '>', $path or die "redirect stderr: $!";
    my $err;
    eval { $code->(); 1 } or $err = $@;
    open STDERR, '>&', $old or die "restore stderr: $!";
    close $old;
    open my $in, '<', $path or die "read stderr: $!";
    local $/;
    my $buf = <$in> // '';
    close $in;
    die $err if $err;
    return $buf;
}
