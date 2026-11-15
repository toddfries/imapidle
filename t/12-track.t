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
use POSIX qw(_exit);
use Test::More;

require './imapidle';

set_foreground_for_test(0);
set_verbose_for_test(0);

my $dir = tempdir('imapidle-track-XXXX', CLEANUP => 1, TMPDIR => 1);
set_runtime_dir_for_test($dir);

# --- config defaults and overrides ---

my $plain = write_conf(<<'EOF');
[acct]
type = idle
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = ch
folder0 = INBOX
EOF
is(load_config($plain), '', 'a file with no track section loads');
my $cfg = track_cfg_for_test();
is($cfg->{disabled}, 0, 'tracking is on when the section is absent');
is($cfg->{list}, 259200, 'list defaults to 3 days');
is($cfg->{id}, 604800, 'id defaults to 7 days');
is($cfg->{capability}, 604800, 'capability defaults to 7 days');
is($cfg->{connections}, 2, 'the mbsync cap defaults to 2');
is($cfg->{min}, 600, 'the floor defaults to 10 minutes');
is($cfg->{messages}, 5, 'the message target defaults to 5');
is($cfg->{initial}, 1800, 'the first interval defaults to 30 minutes');
ok((!grep { $_ eq 'track' } account_names()), 'track is not an account');

my $over = write_conf(<<'EOF');
[acct]
type = idle
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = ch
folder0 = INBOX

[track]
type = global
min = 120
connections = 3
disabled = yes
EOF
is(load_config($over), '', 'a track section loads with an account');
$cfg = track_cfg_for_test();
is($cfg->{disabled}, 1, 'disabled = yes stops tracked syncs');
is($cfg->{connections}, 3, 'a set key overrides the default');
is($cfg->{min}, 120, 'min is overridden');
is($cfg->{list}, 259200, 'an omitted key keeps its default');
is_deeply([account_names()], ['acct'], 'the track section is not connected');

like(load_config(write_conf(<<'EOF')), qr/\[track\] bad min/, 'min below 60 is rejected');
[acct]
type = idle
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = ch
folder0 = INBOX
[track]
type = global
min = 10
EOF

like(load_config(write_conf(<<'EOF')), qr/\[track\] bad max/, 'max below min is rejected');
[acct]
type = idle
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = ch
folder0 = INBOX
[track]
type = global
max = 100
EOF

like(load_config(write_conf(<<'EOF')), qr/\[track\] capability below id/, 'capability shorter than id is rejected');
[acct]
type = idle
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = ch
folder0 = INBOX
[track]
type = global
capability = 3600
EOF

like(load_config(write_conf(<<'EOF')), qr/\[track\] bad messages/, 'messages must be at least 1');
[acct]
type = idle
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = ch
folder0 = INBOX
[track]
type = global
messages = 0
EOF

is(load_config($plain), '', 'a good file loads again');
apply_folder_list('ch', ['Archive'], {}, 1, 1000);
is(list_next_for_test('ch'), 1000 + 259200, 'a successful list waits the list interval');
is(reload_config_now($plain), '', 'reload accepts the same file');
is(list_next_for_test('ch'), 0, 'reload asks for a fresh folder list');

# --- ID and capability schedule ---

my $learned = "$dir/learned";
set_learned_for_test($learned);
open my $fh, '>', $learned or die "write learned: $!";
print $fh "mail.example:993\trejected\tdovecot-2.2\n";
close $fh;

is(id_command(), 'ID ("name" "imapidle" "version" "0.2")', 'the ID command is two string pairs');

my $old = SeqIMAP->new(
    ['* ID ("name" "Dovecot" "version" "2.2.36")', 'A1 OK ID completed'],
    [qw(IMAP4rev1 IDLE)],
);
$old->{die_cap} = 1;
my $t0 = 1_000_000;
consider_id($old, 'mail.example', 993, $t0);
consider_capability('fdc', $old, 'mail.example', 993, [], $t0);
is_deeply($old->{cmds}, [id_command()], 'an old learned line schedules ID and not CAPABILITY');
my $oldrow = learned_row('mail.example', 993);
is($oldrow->{notify}, 'rejected', 'the stored notify value stays');
ok(!$oldrow->{cap_force}, 'the first hash does not force CAPABILITY');
cmp_ok($oldrow->{cap_next}, '>', $t0, 'the capability backstop is armed from now');
ok($oldrow->{id_hash}, 'the first ID stores a hash');
is($oldrow->{id_changes}, undef, 'the first hash does not count as an update');

$old->{cmds} = [];
consider_id($old, 'mail.example', 993, $t0 + 10);
consider_capability('fdc', $old, 'mail.example', 993, [], $t0 + 10);
is_deeply($old->{cmds}, [], 'a second connect inside the gap sends neither command');

my $fresh = SeqIMAP->new(
    ['* ID ("name" "Dovecot" "version" "2.2.36")', 'A1 OK ID completed'],
    [qw(IMAP4rev1 IDLE)],
);
consider_id($fresh, 'fresh.example', 993, $t0);
consider_capability('acct', $fresh, 'fresh.example', 993, [], $t0);
is_deeply($fresh->{cmds}, [id_command(), 'CAPABILITY'], 'a new server sends ID and CAPABILITY once');
my $row = learned_row('fresh.example', 993);
is($row->{id_interval}, 604800, 'the ID interval starts at 7 days');

my $due = $row->{id_next};
consider_id($fresh, 'fresh.example', 993, $due);
$due = learned_row('fresh.example', 993)->{id_next};
consider_id($fresh, 'fresh.example', 993, $due);
$due = learned_row('fresh.example', 993)->{id_next};
consider_id($fresh, 'fresh.example', 993, $due);
$row = learned_row('fresh.example', 993);
is($row->{id_interval}, 604800, 'three unchanged checks stay at the 7 day ceiling');

$fresh->{lines} = ['* ID ("name" "Dovecot" "version" "2.3.1")', 'A1 OK ID completed'];
$fresh->{cmds} = [];
set_foreground_for_test(1);
my $upd = capture(sub { consider_id($fresh, 'fresh.example', 993, $row->{id_next}); });
set_foreground_for_test(0);
like($upd, qr/fresh\.example:993: id updated \(x1 avg \d+\.\d\ds\)/, 'a new hash is logged once');
$row = learned_row('fresh.example', 993);
is($row->{id_changes}, 1, 'one gap is added to the update total');
is($row->{id_interval}, 302400, 'a changed hash halves the ID interval');
ok($row->{cap_force}, 'a changed hash makes CAPABILITY due');
consider_capability('acct', $fresh, 'fresh.example', 993, [], $row->{id_next});
is($fresh->{cmds}[-1], 'CAPABILITY', 'CAPABILITY runs even though its backstop is still ahead');

is(next_id_interval(700, 1), 600, 'halving stops at the 10 minute floor');

# --- folder list ---

set_state_dir_for_test("$dir/state");
reset_track_for_test();
set_foreground_for_test(1);
my @listed = folder_names_from_list([
    { name => 'Archive',        attrs => [] },
    { name => 'INBOX.2026-11',  attrs => [] },
    { name => 'INBOX',          attrs => [] },
    { name => 'inbox',          attrs => [] },
    { name => 'a:b',            attrs => [] },
    { name => 'My Mail',        attrs => [] },
    { name => 'Skip',           attrs => ['\\Noselect'] },
    { name => 'Ghost',          attrs => ['\\NonExistent'] },
]);
is_deeply(
    [sort @listed],
    ['Archive', 'INBOX', 'INBOX.2026-11', 'My Mail', 'a:b', 'inbox'],
    'Noselect and NonExistent names are skipped and dotted names stay',
);
my $saved = capture(sub {
    apply_folder_list('fdc', \@listed, { INBOX => 1 }, 1, 1000);
});
like($saved, qr/fdc     : 6 folders, list saved/, 'the first list does not name each folder');
unlike($saved, qr/folder Archive added/, 'the first list has no added line');
like($saved, qr/fdc     : folder a:b not tracked/, 'a colon in the name is not tracked');
my @boxes = map { $_->{box} } track_rows_for_test();
is_deeply([sort @boxes], ['Archive', 'INBOX.2026-11', 'My Mail'], 'hot INBOX and the colon name are not tracked');
ok(-f "$dir/state/folders/fdc", 'the folder file was written');
is((stat "$dir/state/folders/fdc")[2] & 0777, 0600, 'the folder file is mode 0600');
like(slurp("$dir/state/folders/fdc"), qr/^My Mail$/m, 'a space in a name round-trips');

my ($kept) = grep { $_->{box} eq 'INBOX.2026-11' } track_rows_for_test();
is($kept->{next}, 1000 + 1800, 'a new mailbox starts at initial');

my $diff = capture(sub {
    apply_folder_list('fdc', ['INBOX.2026-11', 'INBOX', 'a:b', 'My Mail'], { INBOX => 1 }, 1, 2000);
});
like($diff, qr/fdc     : folder Archive removed/, 'a missing name is removed');
unlike($diff, qr/folder Archive added/, 'removal is not also an add');
ok((!grep { $_->{box} eq 'Archive' } track_rows_for_test()), 'a removed mailbox has no due time');
($kept) = grep { $_->{box} eq 'INBOX.2026-11' } track_rows_for_test();
is($kept->{next}, 1000 + 1800, 'a name that remains keeps its clock');

my $back = capture(sub {
    apply_folder_list('fdc', ['Archive', 'INBOX.2026-11', 'My Mail'], { INBOX => 1 }, 1, 3000);
});
like($back, qr/fdc     : folder Archive added/, 'a name that returns is added');
($kept) = grep { $_->{box} eq 'Archive' } track_rows_for_test();
is($kept->{next}, 3000 + 1800, 'an added mailbox starts at initial');
($kept) = grep { $_->{box} eq 'My Mail' } track_rows_for_test();
is($kept->{next}, 1000 + 1800, 'a mailbox that stayed does not restart');

capture(sub { apply_folder_list('fdc', [], {}, 0, 4000); });
is_deeply([folder_names_for_test('fdc')], ['Archive', 'INBOX.2026-11', 'My Mail'],
    'a failed list leaves the saved names');
ok((grep { $_->{box} eq 'Archive' } track_rows_for_test()), 'a failed list leaves the track set');
is(list_next_for_test('fdc'), 4000 + 1800, 'a failed list retries at initial');

reset_track_for_test();
load_folder_files();
is_deeply([folder_names_for_test('fdc')], ['Archive', 'INBOX.2026-11', 'My Mail'],
    'folder names load from disk before connect');

set_foreground_for_test(0);
my $src = "$dir/config-learned";
open $fh, '>', $src or die "write src: $!";
print $fh "mail0.example:993\trejected\tdovecot-2.2\n";
close $fh;
my $dest = "$dir/state/learned";
unlink $dest;
ok(adopt_state_file($dest, $src), 'a missing state file is copied once');
is((stat $dest)[2] & 0777, 0600, 'the copied learned file is mode 0600');
is(slurp($dest), slurp($src), 'the copy matches the old file');
is(adopt_state_file($dest, $src), 0, 'a later start does not copy again');
is(slurp($src), "mail0.example:993\trejected\tdovecot-2.2\n", 'the old path is left in place');
set_foreground_for_test(0);

# --- summary and intervals ---

my $summary = join("\n",
    'C: 1/2  B: 1/2  F: +0/1 *0/0 #0/0 N: +0/1 *0/0 #0/0',
    'Channels: 1    Boxes: 1    Far: +2 *0 #0 -0    Near: +3 *1 #0 -0',
    'Channels: 1    Boxes: 1    Far: +1 *0 #0 -0    Near: +0 *0 #0 -0',
);
is(mbsync_new_messages($summary), 1, 'the last Channels line wins and notices are ignored');
is(mbsync_new_messages('no summary'), undef, 'a missing Channels line is not zero');
is(mbsync_new_messages("Channels: 1    Boxes: 1    Far: +0 *0 #0 -0    Near: +0 *0 #0 -0\n"),
    0, 'a real zero is a sample');

set_interval_spread_for_test(sub { 0 });
my $zero = { msgs => 0, dur => 2, span => 1800 };
is(next_mailbox_interval(1800,  [ ($zero) x 3 ]), 3600,  'no mail doubles 1800 to 3600');
is(next_mailbox_interval(3600,  [ ($zero) x 3 ]), 7200,  'the next quiet window doubles again');
is(next_mailbox_interval(7200,  [ ($zero) x 3 ]), 14400, 'quiet continues toward the ceiling');
is(next_mailbox_interval(14400, [ ($zero) x 3 ]), 21600, '14400 doubles to the 6 hour ceiling');
is(next_mailbox_interval(21600, [ ($zero) x 3 ]), 21600, 'the ceiling holds');
set_interval_spread_for_test(sub { $_[0] - 1 });
is(next_mailbox_interval(1800, [ ($zero) x 3 ]), 4049,
    'a quiet 1800 adds one less than a quarter of the 1800s increase');
is(next_mailbox_interval(14400, [ ($zero) x 3 ]), 21600,
    'the ceiling still holds when the spread would pass it');
is(next_mailbox_interval(21600, [ ($zero) x 3 ]), 21600,
    'staying at the ceiling does not grow past max');

set_interval_spread_for_test(sub { 0 });
my $two = { msgs => 2, dur => 2, span => 1800 };
is(next_mailbox_interval(1800, [ ($two) x 3 ]), 4500, 'two new messages target 4500s');
my $many = { msgs => 30, dur => 2, span => 1800 };
is(next_mailbox_interval(1800, [ ($many) x 3 ]), 600, 'thirty new messages stop at 10 minutes');
my $slow = { msgs => 30, dur => 400, span => 1800 };
is(next_mailbox_interval(1800, [ ($slow) x 3 ]), 1200, 'a 400s sync costs 1200s');
my $rare = { msgs => 2, dur => 400, span => 1800 };
is(next_mailbox_interval(1800, [ ($rare) x 3 ]), 4500, 'a quiet slow box follows the mail target');
set_interval_spread_for_test(sub { $_[0] - 1 });
is(next_mailbox_interval(1800, [ ($two) x 3 ]), 5174,
    'a longer mail target adds one less than a quarter of the increase');
is(next_mailbox_interval(1800, [ ($many) x 3 ]), 600,
    'a shorter wait does not gain the spread');
set_interval_spread_for_test(undef);
my (%seen, $outside);
for (1 .. 24) {
    my $n = next_mailbox_interval(1800, [ ($zero) x 3 ]);
    $seen{$n} = 1;
    $outside = $n if $n < 3600 || $n > 4049;
}
ok(!defined $outside, 'rand spread stays inside the added quarter')
    or diag("outside 3600..4049: $outside");
cmp_ok(scalar keys %seen, '>', 1, 'rand draws are not one repeated value');
set_interval_spread_for_test(sub { 0 });

reset_mbsync_real_for_test();
reset_conn_time_for_test();
is(note_conn_time("fdc\0INBOX", 10), '(x1 avg 10.00s)', 'the first connection duration is its own average');
is(note_conn_time("fdc\0INBOX", 20), '(x2 avg 15.00s)', 'connection duration averages in its own table');
is(note_mbsync_real('fdc:Archive', 4), 'x1 4.00|4.00s', 'mbsync real keeps the count and the total');
my ($cn, $ct) = stat_pair_for_test('conn', "fdc\0INBOX");
my ($mn, $mt) = stat_pair_for_test('mbsync', 'fdc:Archive');
is_deeply([$cn, $ct], [2, 30], 'connection totals are count and seconds');
is_deeply([$mn, $mt], [1, 4], 'mbsync totals are a different row');
reset_conn_time_for_test();
reset_mbsync_real_for_test();
load_stat_files();
($cn, $ct) = stat_pair_for_test('conn', "fdc\0INBOX");
($mn, $mt) = stat_pair_for_test('mbsync', 'fdc:Archive');
is_deeply([$cn, $ct], [2, 30], 'connection totals load from conn-time');
is_deeply([$mn, $mt], [1, 4], 'mbsync totals load from mbsync-real');

reset_track_for_test();
my $id = set_track_due_for_test('fdc', 'Quiet', 0);
finish_track_job({ track => $id }, 1, 2, "gave up\n", 100);
my ($quiet) = track_rows_for_test();
is($quiet->{interval}, 1800, 'one missing summary leaves the interval');
is($quiet->{fails}, 1, 'the miss is counted');
finish_track_job({ track => $id }, 1, 2, "gave up\n", 200);
finish_track_job({ track => $id }, 1, 2, "gave up\n", 300);
($quiet) = track_rows_for_test();
is($quiet->{interval}, 3600, 'three missing summaries double the interval');
is($quiet->{fails}, 0, 'the failure window clears');

my $sid = set_track_due_for_test('fdc', 'Slow', 0);
my $one = "Channels: 1    Boxes: 1    Far: +2 *0 #0 -0    Near: +0 *0 #0 -0\n";
finish_track_job({ track => $sid }, 256, 400, $one, 500);
my ($slowbox) = grep { $_->{box} eq 'Slow' } track_rows_for_test();
is($slowbox->{samples}, 1, 'a non-zero exit with a summary is a sample');
is($slowbox->{fails}, 0, 'a summary clears the failure streak');
is(list_next_for_test('fdc'), 0, 'a non-zero tracked exit asks for LIST');

reset_track_for_test();
reset_schedule_for_test();
set_next_try_for_test($_, time() + 10000) for account_names();
{
    my $ps = pulse_snapshot_for_test();
    set_pulse_next_for_test($_, time() + 10000) for @{ $ps->{channels} // [] };
}
set_track_due_for_test('fdc', 'Quiet', time() - 1);
is(loop_timeout(), 0, 'a tracked folder that can start wakes the loop');
set_connections_for_test(1);
hold_child_for_test(4242, 'mbsync other:Box');
cmp_ok(loop_timeout(), '>=', 29, 'a due tracked folder with no free slot does not spin');
clear_children_for_test();
set_connections_for_test(4);
hold_child_for_test(4243, 'mbsync fdc:Other');
cmp_ok(loop_timeout(), '>=', 29, 'a due tracked folder waits while its channel is busy');
clear_children_for_test();
set_track_due_for_test('fdc', 'Quiet', time() + 10);
my $track_wait = loop_timeout();
cmp_ok($track_wait, '>', 8, 'the loop wakes for a tracked folder');
cmp_ok($track_wait, '<=', 10, 'the loop does not sleep past that folder');

# --- queue, pause, shutdown ---

is(load_config(write_conf(<<'EOF')), '', 'queue fixture loads');
[acct]
type = idle
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = ch
folder0 = INBOX
[pulse]
type = pulse
channel0 = knf
EOF
my $cap = track_cfg_for_test();
$cap->{connections} = 4;
install_track($cap, 0);
reset_schedule_for_test();
clear_children_for_test();
reset_track_for_test();
$cap = track_cfg_for_test();
$cap->{connections} = 4;
install_track($cap, 0);

my @forked;
set_trigger_hook_for_test(sub {
    my ($wait, $args, $meta) = @_;
    push @forked, { wait => $wait, args => [@$args], track => $meta->{track} };
    my $pid = hold_child_for_test(50000 + @forked, 'mbsync ' . join(' ', @$args));
    tag_child_for_test($pid, 'track', $meta->{track})
        if defined $meta->{track} && $meta->{track} ne '';
    tag_child_for_test($pid, 'pulse', $meta->{pulse})
        if defined $meta->{pulse} && $meta->{pulse} ne '';
    return $pid;
});

my $now = 10_000;
queue_folder('hotc', 'INBOX', $now, $now);
set_track_due_for_test('trkc', 'Archive', $now - 5);
set_pulse_next_for_test('knf', 0);
pump_schedule($now);
is_deeply(
    [map { join(' ', @{ $_->{args} }) } @forked],
    ['hotc:INBOX', 'trkc:Archive', 'knf'],
    'hot runs, then tracked, then pulse in a spare slot',
);
is($forked[1]{args}[0], 'trkc:Archive', 'a tracked job is a single channel:box');
ok($forked[1]{track}, 'the tracked child is marked for the summary');
is($forked[2]{args}[0], 'knf', 'pulse is not held behind the named sync');

clear_children_for_test();
@forked = ();
set_pulse_next_for_test('knf', 0);
my $tracked_pid = hold_child_for_test(61001, 'mbsync trkc:Archive');
tag_child_for_test($tracked_pid, 'track', "trkc\0Archive");
pump_schedule($now);
is_deeply(
    [map { join(' ', @{ $_->{args} }) } @forked],
    ['knf'],
    'a tracked sync does not hold pulse',
);

clear_children_for_test();
@forked = ();
$cap = track_cfg_for_test();
$cap->{connections} = 2;
install_track($cap, 0);
set_track_due_for_test('trkc', 'Archive', $now);
set_track_due_for_test('trkc', 'Later', $now);
pump_schedule($now);
is(scalar(@forked), 1, 'with cap 2 one slot stays free of cold work');

set_pulse_next_for_test('knf', 10**9);
set_track_due_for_test('trkc', 'Archive', 10**9);
set_track_due_for_test('trkc', 'Later', 10**9);
clear_children_for_test();
@forked = ();
reset_schedule_for_test();
$cap->{connections} = 1;
install_track($cap, 0);
queue_folder('hotc', 'INBOX', $now, $now);
set_track_due_for_test('other', 'Box', $now);
pump_schedule($now);
is_deeply([map { $_->[0] } map { $_->{args} } @forked], ['hotc:INBOX'], 'cap 1 gives the only slot to hot');
clear_children_for_test();
@forked = ();
pump_schedule($now);
is_deeply([map { $_->[0] } map { $_->{args} } @forked], ['other:Box'], 'tracked runs once hot is done');

set_track_due_for_test('other', 'Box', 10**9);
clear_children_for_test();
@forked = ();
reset_schedule_for_test();
$cap->{connections} = 2;
install_track($cap, 0);
queue_folder('fdc', 'INBOX', $now, $now + 30);
set_track_due_for_test('fdc', 'Archive', $now);
pump_schedule($now);
is_deeply(\@forked, [], 'a hot combine window defers that channel');

reset_schedule_for_test();
note_mail_event('fdc', 'INBOX', 420, 0, 1000);
due_mbsync_jobs(1005);
note_mail_event('fdc', 'INBOX', 420, 0, 1100);
set_track_due_for_test('fdc', 'Archive', 1100);
reset_mbsync_real_for_test();
@forked = ();
pump_schedule(1100);
is_deeply(\@forked, [], 'the first sync waits while any hot folder is pending');
note_mbsync_real('fdc:Archive', 10);
@forked = ();
pump_schedule(1100);
is($forked[0]{args}[0], 'fdc:Archive', 'a short tracked sync fits before the hot gap ends');
clear_children_for_test();
reset_mbsync_real_for_test();
note_mbsync_real('fdc:Archive', 2000);
@forked = ();
pump_schedule(1100);
is_deeply(\@forked, [], 'a long tracked sync waits out the hot gap');

# pause
clear_children_for_test();
@forked = ();
reset_schedule_for_test();
my $run = "$dir/run";
mkdir $run;
set_runtime_dir_for_test($run);
my $pause = "$run/pause.mail";
open $fh, '>', $pause or die "pause: $!";
print $fh "hold\n";
close $fh;
queue_folder('ch', 'INBOX', $now, $now);
set_foreground_for_test(1);
my $held = capture(sub { pump_schedule($now); });
my $again = capture(sub { pump_schedule($now); });
set_foreground_for_test(0);
like($held, qr/pause file \Q$pause\E detected, idling operations/, 'the pause file is logged once');
is($again, '', 'a second look does not log the pause again');
is_deeply(\@forked, [], 'a due hot job does not fork while paused');
my $paused_pid = fork();
if (!defined $paused_pid) {
    die "fork: $!";
}
if ($paused_pid == 0) {
    exec '/usr/bin/true' or exit 1;
}
hold_child_for_test($paused_pid, 'mbsync ch:INBOX');
select(undef, undef, undef, 0.2);
reap_children();
my ($header) = info_lines($now);
unlike($header, qr/mbsync [1-9]/, 'an already-recorded child still reaps during a pause');
unlink $pause;
set_foreground_for_test(1);
my $resumed = capture(sub { pump_schedule($now); });
set_foreground_for_test(0);
like($resumed, qr/pause cleared, mbsync resuming/, 'clearing the pause file resumes mbsync');
is($forked[0]{args}[0], 'ch:INBOX', 'the due hot job forks after the pause');

# shutdown
clear_children_for_test();
@forked = ();
reset_track_for_test();
set_state_dir_for_test("$dir/state");
clear_conns_for_test();
reset_conn_time_for_test();
my $idle_imap = ByeIMAP->new;
my $dead_imap = ByeIMAP->new(0);
my $notify_imap = ByeIMAP->new;
my $ckey = plant_idle_for_test('fdc', 'INBOX', 420, 'fdc');
my $dkey = plant_idle_for_test('fdc', 'Sent', 420, 'fdc');
my $nkey = plant_bare_notify_for_test('fdc', 'fdc');
set_conn_imap_for_test($ckey, $idle_imap, 41);
set_conn_imap_for_test($dkey, $dead_imap, 42);
set_conn_imap_for_test($nkey, $notify_imap);
hold_child_for_test(88, 'mbsync fdc:INBOX');
my $stop = "$run/shutdown";
open $fh, '>', $stop or die "shutdown: $!";
close $fh;
set_foreground_for_test(1);
my $waiting = capture(sub {
    is(shutdown_step_for_test(), 'wait', 'a live child delays the exit');
});
ok(!conn_exists_for_test($ckey), 'IDLE closes when shutdown is noticed');
ok(!conn_exists_for_test($nkey), 'NOTIFY closes when shutdown is noticed');
ok(!conn_exists_for_test($dkey), 'a dead IDLE session is dropped too');
is_deeply($idle_imap->{calls}, [qw(done logout)], 'IDLE is ended with DONE then LOGOUT');
is_deeply($notify_imap->{calls}, ['logout'], 'NOTIFY is ended with LOGOUT');
is_deeply($dead_imap->{calls}, [], 'a dead session is not sent DONE or LOGOUT');
like($waiting, qr/shutdown file \Q$stop\E detected, finishing mbsync/, 'shutdown names the file');
like($waiting, qr/fdc     : disconnecting INBOX \(x1 avg \d+\.\d\ds\)/, 'disconnect reports connection time');
like($waiting, qr/waiting on 1 mbsync/, 'the wait is logged once');
is_deeply(\@forked, [], 'shutdown does not start mbsync');
clear_children_for_test();
my $done = capture(sub {
    is(shutdown_step_for_test(), 'exit', 'the process finishes when mbsync is gone');
});
set_foreground_for_test(0);
unlike($done, qr/disconnecting/, 'the sessions are not closed twice');
like($done, qr/wrote \Q$dir\/state\E stats/, 'stats are written');
like($done, qr/shutdown complete/, 'shutdown says it is done');
ok(-f "$dir/state/conn-time", 'conn-time is on disk');
ok(-f "$dir/state/mbsync-real", 'mbsync-real is on disk');

unlink $stop;
reset_track_for_test();
request_shutdown_for_test('TERM');
set_foreground_for_test(1);
my $sig = capture(sub { shutdown_step_for_test(); });
set_foreground_for_test(0);
like($sig, qr/signal TERM, finishing mbsync/, 'SIGTERM uses the signal line');

clear_children_for_test();
hold_child_for_test(424242, 'mbsync knf');
reap_children();
like(last_child_exit_for_test(), qr/gone\z/, 'a child this process cannot reap is logged gone');
is(mbsync_running(), 0, 'that child is forgotten');
unlink $stop;
open $fh, '>', $stop or die "shutdown: $!";
close $fh;
set_foreground_for_test(1);
my $ghost = capture(sub {
    is(shutdown_step_for_test(), 'exit', 'shutdown exits once a ghost child is gone');
});
set_foreground_for_test(0);
like($ghost, qr/shutdown complete/, 'a ghost child does not hold the exit');

my $slog = "$dir/startup-stop.log";
my $stopper = fork();
die "fork: $!" unless defined $stopper;
if ($stopper == 0) {
    Test::More->builder->no_ending(1);
    set_foreground_for_test(1);
    reset_track_for_test();
    open STDERR, '>', $slog or _exit(4);
    select STDERR;
    $| = 1;
    select STDOUT;
    # exit would run File::Temp cleanup in this child and remove $dir.
    set_abandon_exit_for_test(sub { _exit(0) });
    connect_account('not-an-account');
    _exit(3);
}
local $SIG{ALRM} = sub { kill 'KILL', $stopper };
alarm 3;
waitpid($stopper, 0);
my $stop_status = $?;
alarm 0;
is($stop_status, 0, 'a shutdown file stops startup before a mailbox is opened');
my $stop_log = slurp($slog);
like($stop_log, qr/shutdown file \Q$stop\E detected, finishing mbsync/, 'startup names the shutdown file');
like($stop_log, qr/shutdown complete/, 'startup says shutdown is done');
unlike($stop_log, qr/IDLE|daemonizing|-> /, 'startup does not open IDLE or daemonize');

set_trigger_hook_for_test(undef);
set_verbose_for_test(0);
set_foreground_for_test(0);
done_testing;

package ByeIMAP;
sub new {
    my ($class, $up) = @_;
    bless { calls => [], up => $up // 1 }, $class;
}
sub IsConnected { $_[0]{up} ? 1 : 0 }
sub done   { push @{ $_[0]{calls} }, 'done';   return 'A1 OK' }
sub logout { push @{ $_[0]{calls} }, 'logout'; return 1 }
sub LastError { '' }

package main;

sub write_conf {
    my ($body) = @_;
    my ($out, $file) = tempfile('imapidle-track-XXXX', SUFFIX => '.conf', TMPDIR => 1);
    print $out $body;
    close $out;
    return $file;
}

sub capture {
    my ($code) = @_;
    my ($tfh, $path) = tempfile('imapidle-cap-XXXX', UNLINK => 1, TMPDIR => 1);
    close $tfh;
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

sub slurp {
    my ($file) = @_;
    open my $in, '<', $file or die "read $file: $!";
    local $/;
    return scalar <$in>;
}

package SeqIMAP;
sub new {
    my ($class, $lines, $caps) = @_;
    return bless { lines => $lines, caps => $caps, cmds => [] }, $class;
}
sub tag_and_run {
    my ($self, $cmd) = @_;
    push @{ $self->{cmds} }, $cmd;
    return @{ $self->{lines} };
}
sub capability {
    my ($self) = @_;
    die "CAPABILITY was not due\n" if $self->{die_cap};
    push @{ $self->{cmds} }, 'CAPABILITY';
    return @{ $self->{caps} };
}
sub folders_hash { return []; }
