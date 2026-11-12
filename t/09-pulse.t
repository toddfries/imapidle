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
use Test::More;

require './imapidle';

my $run = tempdir('imapidle-run-XXXX', CLEANUP => 1, TMPDIR => 1);
set_runtime_dir_for_test($run);

sub write_conf {
    my ($text) = @_;
    my ($fh, $path) = tempfile('imapidle-XXXX', SUFFIX => '.conf', TMPDIR => 1);
    print $fh $text;
    close $fh;
    return $path;
}

sub jobs {
    my ($now) = @_;
    return map { join(' ', @{ $_->{args} }) . ' wait=' . $_->{wait} } due_mbsync_jobs($now);
}

my $bad_sweep = write_conf(<<'EOF');
[pulse]
sweep = soon
channel0 = gm-ctf
EOF
like(load_config($bad_sweep), qr/\[pulse\] bad sweep/, 'a non-numeric sweep is rejected');
unlink $bad_sweep;

my $gap = write_conf(<<'EOF');
[pulse]
channel0 = gm-ctf
channel2 = knf
EOF
like(load_config($gap), qr/\[pulse\] gap before channel1/, 'a missing channel number is an error');
unlink $gap;

my $empty = write_conf(<<'EOF');
[pulse]
channel0 =
EOF
like(load_config($empty), qr/\[pulse\] empty channel0/, 'an empty channel is rejected');
unlink $empty;

my $colon = write_conf(<<'EOF');
[pulse]
channel0 = gm:ctf
EOF
like(load_config($colon), qr/\[pulse\] bad channel0/, 'a colon in a channel name is rejected');
unlink $colon;

my $dash = write_conf(<<'EOF');
[pulse]
channel0 = -a
EOF
like(load_config($dash), qr/\[pulse\] bad channel0/, 'a channel name may not be an mbsync flag');
unlink $dash;

my $dup = write_conf(<<'EOF');
[pulse]
channel0 = gm-ctf
channel1 = gm-ctf
EOF
like(load_config($dup), qr/\[pulse\] duplicate channel gm-ctf/, 'a repeated channel is rejected');
unlink $dup;

my $held = write_conf(<<'EOF');
[pulse]
disabled = yes
sweep = no
EOF
is(load_config($held), '', 'disabled = yes does not check the pulse keys');
is(pulse_snapshot_for_test()->{disabled}, 1, 'the section is held');
is_deeply([due_pulse_channels(1000)], [], 'a held section starts nothing');
is_deeply([grep { /^pulse: / } info_lines(1000)], ['pulse: disabled'], 'state names the held section');
unlink $held;

my $only = write_conf(<<'EOF');
[pulse]
channel0 = gm-ctf
channel1 = knf
EOF
is(load_config($only), '', 'a file with only pulse channels loads');
is_deeply([account_names()], [], 'no IMAP account is required');
is(pulse_snapshot_for_test()->{sweep}, 3600, 'an omitted sweep is 3600');
is_deeply(pulse_snapshot_for_test()->{channels}, [qw(gm-ctf knf)], 'channels stay in order');
is_deeply([due_pulse_channels(1000)], [qw(gm-ctf knf)], 'the first load is due together');

my $now = time();
set_pulse_next_for_test('gm-ctf', $now + 10);
set_pulse_next_for_test('knf', $now + 100);
my $wait = loop_timeout();
cmp_ok($wait, '>', 8, 'the loop wakes for the nearer pulse channel');
cmp_ok($wait, '<=', 10, 'the loop does not sleep past that channel');
note_child_for_test(1, 'mbsync gm-ctf');
note_child_for_test(2, 'mbsync knf');
set_pulse_next_for_test('gm-ctf', $now - 5);
set_pulse_next_for_test('knf', $now - 5);
my $busy_wait = loop_timeout();
cmp_ok($busy_wait, '>=', 29, 'a channel that is already running does not spin the loop');
clear_children_for_test();
unlink $only;

my $path = write_conf(<<'EOF');
[acct]
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = fdc-main
folder0 = INBOX

[pulse]
sweep = 3600
channel0 = gm-ctf
channel1 = knf
channel2 = knfmobile
EOF
is(load_config($path), '', 'accounts and pulse channels load together');
is(loaded_account('acct')->{mbsync_channel}, 'fdc-main', 'the account is unchanged');
is_deeply(
    [due_pulse_channels(1000)],
    [qw(gm-ctf knf knfmobile)],
    'every pulse channel is due on the first load',
);
is_deeply(
    [grep { /: pulse sweep / } info_lines(1000)],
    [
        'gm-ctf: pulse sweep 3600s due',
        'knf: pulse sweep 3600s due',
        'knfmobile: pulse sweep 3600s due',
    ],
    'state shows each channel due',
);

clear_children_for_test();
reset_schedule_for_test();
note_child_for_test(9, 'mbsync gm-ctf');
is_deeply(
    [due_pulse_channels(1000)],
    [qw(knf knfmobile)],
    'a running channel does not start a second copy',
);
is_deeply(
    [grep { /^gm-ctf: pulse / } info_lines(1000)],
    ['gm-ctf: pulse sweep 3600s running'],
    'state shows the running channel',
);
note_mail_event('gm-ctf', 'INBOX', 420, 0, 1000);
is_deeply([jobs(1005)], [], 'a folder sync waits while the bare channel runs');
ok(!defined next_schedule_delay(1005), 'that wait does not spin the loop');
clear_children_for_test();
is_deeply([jobs(1005)], ['gm-ctf:INBOX wait=0'], 'the folder sync runs once the channel is free');

reset_schedule_for_test();
clear_children_for_test();
note_child_for_test(4, 'mbsync gm-ctf:INBOX');
is_deeply(
    [due_pulse_channels(1000)],
    [qw(knf knfmobile)],
    'the bare channel waits while a folder of that channel is syncing',
);
note_mail_event('fdc-main', 'INBOX', 420, 0, 1000);
is_deeply(
    [jobs(1005)],
    ['fdc-main:INBOX wait=0'],
    'a different channel is not delayed',
);
clear_children_for_test();
is_deeply(
    [due_pulse_channels(1000)],
    [qw(gm-ctf knf knfmobile)],
    'the bare channel starts once its folder sync is gone',
);

finish_pulse_channel('gm-ctf', 1009);
finish_pulse_channel('knf', 1018);
finish_pulse_channel('knfmobile', 1040);
is(pulse_snapshot_for_test()->{next}{'gm-ctf'}, 4609, 'gm-ctf waits 3600s from its own exit');
is(pulse_snapshot_for_test()->{next}{knf}, 4618, 'knf waits 3600s from its own exit');
is(pulse_snapshot_for_test()->{next}{knfmobile}, 4640, 'knfmobile waits 3600s from its own exit');
is_deeply([due_pulse_channels(4608)], [], 'nothing is due one second early');
is_deeply([due_pulse_channels(4609)], ['gm-ctf'], 'only the channel whose wait ended is due');
is_deeply([due_pulse_channels(4618)], [qw(gm-ctf knf)], 'each clock stays independent');
is_deeply([due_pulse_channels(4640)], [qw(gm-ctf knf knfmobile)], 'a later exit is due later');
is_deeply(
    [grep { /^gm-ctf: pulse / } info_lines(1109)],
    ['gm-ctf: pulse sweep 3600s next 3500s'],
    'state shows the remaining wait',
);

my $edited = write_conf(<<'EOF');
[acct]
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = fdc-main
folder0 = INBOX

[pulse]
sweep = 60
channel0 = gm-ctf
channel1 = archive
EOF
is(reload_config_now($edited), '', 'reload accepts a new pulse list');
my $snap = pulse_snapshot_for_test();
is($snap->{sweep}, 60, 'reload stores the new sweep');
is_deeply($snap->{channels}, [qw(gm-ctf archive)], 'channel order follows the file');
is($snap->{next}{'gm-ctf'}, 4609, 'a channel that remains keeps its clock');
is($snap->{next}{archive}, 0, 'a new channel is due immediately');
ok(!exists $snap->{next}{knf}, 'a removed channel is not scheduled');
finish_pulse_channel('gm-ctf', 5000);
is(pulse_snapshot_for_test()->{next}{'gm-ctf'}, 5060, 'the new sweep applies when the run exits');

my $bad = write_conf(<<'EOF');
[acct]
server = imap.example.com
EOF
isnt(reload_config_now($bad), '', 'a bad file is rejected');
is(pulse_snapshot_for_test()->{next}{'gm-ctf'}, 5060, 'a rejected file keeps the pulse clock');
is_deeply(
    pulse_snapshot_for_test()->{channels},
    [qw(gm-ctf archive)],
    'a rejected file keeps the pulse channels',
);
unlink $bad;

my $off = write_conf(<<'EOF');
[acct]
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = fdc-main
folder0 = INBOX

[pulse]
disabled = YES
channel0 = gm-ctf
EOF
is(reload_config_now($off), '', 'reload accepts disabled = yes');
is(pulse_snapshot_for_test()->{disabled}, 1, 'reload holds the section');
is_deeply([due_pulse_channels(9000)], [], 'a held section stays idle');
unlink $off;

is(reload_config_now($path), '', 'removing yes enables the section');
is(pulse_snapshot_for_test()->{disabled}, 0, 'the section is active again');
is(pulse_snapshot_for_test()->{sweep}, 3600, 'the saved sweep returns');
is_deeply(
    [due_pulse_channels(9000)],
    [qw(gm-ctf knf knfmobile)],
    'enabling the section makes every channel due',
);

my $gone = write_conf(<<'EOF');
[acct]
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = fdc-main
folder0 = INBOX
EOF
is(reload_config_now($gone), '', 'reload accepts a file with no pulse section');
is_deeply(pulse_snapshot_for_test()->{channels}, [], 'dropping the section drops the channels');
is_deeply([due_pulse_channels(9000)], [], 'nothing in pulse is due');
unlink $gone;
unlink $edited;
unlink $path;

my $boot = write_conf(<<'EOF');
[acct]
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = fdc-main
folder0 = INBOX
folder1 = Archive

[held]
disabled = yes

[pulse]
channel0 = knf
channel1 = other
EOF
is(load_config($boot), '', 'startup order fixture loads');
reset_schedule_for_test();
clear_children_for_test();
my $cap = track_cfg_for_test();
$cap->{connections} = 2;
install_track($cap, 0);
set_foreground_for_test(1);
my $primed = capture(sub { prime_named_folders(2000); });
my $again  = capture(sub { prime_named_folders(2001); });
set_foreground_for_test(0);
like($primed, qr/acct    : startup sync INBOX Archive/, 'startup names the account folders');
unlike($primed, qr/held: startup/, 'a disabled account is not synced at startup');
is($again, '', 'startup sync is queued once');

my @forked;
set_trigger_hook_for_test(sub {
    my ($wait, $args, $meta) = @_;
    push @forked, { wait => $wait, args => [@$args], pulse => $meta->{pulse} };
    return hold_child_for_test(70000 + @forked, 'mbsync ' . join(' ', @$args));
});
queue_folder('hotb', 'INBOX', 2000, 2000);
pump_schedule(2000);
is_deeply(
    [map { join(' ', @{ $_->{args} }) } @forked],
    ['fdc-main:Archive fdc-main:INBOX', 'knf'],
    'one slot stays with the named folders and pulse uses the other',
);
is($forked[0]{wait}, 0, 'startup sync does not wait out the event delay');
ok(!defined $forked[0]{pulse}, 'the named sync is not a pulse job');
is($forked[1]{pulse}, 'knf', 'the spare slot is a pulse channel');
ok(defined schedule_deadline('hotb'), 'the next named channel stays queued');
is_deeply([due_pulse_channels(2000)], ['other'], 'a pulse channel with no free slot stays due');
@forked = ();
pump_schedule(2000);
is_deeply(\@forked, [], 'a full pair does not start another mbsync');

clear_children_for_test();
@forked = ();
reset_schedule_for_test();
set_pulse_next_for_test('knf', 10**12);
set_pulse_next_for_test('other', 10**12);
queue_folder('fdc-main', 'INBOX', 2000, 2000);
queue_folder('hotb', 'INBOX', 2000, 2000);
pump_schedule(2000);
is_deeply(
    [map { join(' ', @{ $_->{args} }) } @forked],
    ['fdc-main:INBOX', 'hotb:INBOX'],
    'named folders use every slot when pulse is not due',
);

clear_children_for_test();
@forked = ();
reset_schedule_for_test();
$cap = track_cfg_for_test();
$cap->{connections} = 1;
install_track($cap, 0);
set_pulse_next_for_test('knf', 0);
set_pulse_next_for_test('other', 0);
prime_named_folders(2000);
pump_schedule(2000);
is_deeply(
    [map { join(' ', @{ $_->{args} }) } @forked],
    ['fdc-main:Archive fdc-main:INBOX'],
    'with one slot the named sync holds pulse',
);
is_deeply([due_pulse_channels(2000)], [qw(knf other)], 'pulse stays due on the only slot');
clear_children_for_test();
@forked = ();
pump_schedule(2000);
is_deeply(
    [map { join(' ', @{ $_->{args} }) } @forked],
    ['knf'],
    'pulse starts once the only slot is free',
);

clear_children_for_test();
@forked = ();
reset_schedule_for_test();
$cap = track_cfg_for_test();
$cap->{connections} = 2;
install_track($cap, 0);
set_pulse_next_for_test('knf', 0);
set_pulse_next_for_test('other', 0);
queue_folder('fdc-main', 'INBOX', 2100, 2130);
pump_schedule(2100);
is_deeply(
    [map { join(' ', @{ $_->{args} }) } @forked],
    ['knf'],
    'pulse uses the spare slot during a named-folder combine window',
);
is(next_schedule_delay(2100), 30, 'the named folder wakes the loop at its deadline');
ok(!defined next_pulse_delay(2100), 'the held slot does not make the loop spin');
is_deeply([due_pulse_channels(2100)], ['other'], 'the second pulse channel waits for a slot');

reset_schedule_for_test();
clear_children_for_test();
$cap = track_cfg_for_test();
$cap->{connections} = 1;
install_track($cap, 0);
queue_folder('fdc-main', 'INBOX', 3000, 3000);
note_child_for_test(3, 'mbsync other:INBOX');
ok(!defined next_schedule_delay(3000), 'a due named folder does not spin while every slot is taken');

set_trigger_hook_for_test(undef);
set_foreground_for_test(0);
unlink $boot;

my $saved = write_conf(<<'EOF');
[acct]
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = fdc-main
folder0 = INBOX

[pulse]
sweep = 3600
channel0 = gm-ctf
channel1 = knf
channel2 = knfmobile
EOF
my $pdir = tempdir('imapidle-pulse-XXXX', CLEANUP => 1, TMPDIR => 1);
open my $pf, '>', "$pdir/pulse-last" or die "pulse-last: $!";
print $pf "# channel\tlast\nknf\t1000\nknfmobile\t2000\n";
close $pf;
set_state_dir_for_test($pdir);
is(load_config($saved), '', 'a fresh load reads pulse-last');
is(pulse_snapshot_for_test()->{next}{knf}, 4600, 'knf waits sweep seconds after its saved exit');
is(pulse_snapshot_for_test()->{next}{knfmobile}, 5600, 'knfmobile waits from its own saved exit');
is(pulse_snapshot_for_test()->{next}{'gm-ctf'}, 0, 'a channel with no saved exit is due');
is_deeply([due_pulse_channels(4500)], ['gm-ctf'], 'a recent exit is not due again after restart');
is_deeply([due_pulse_channels(4600)], [qw(gm-ctf knf)], 'knf is due once its sweep has passed');
clear_children_for_test();
reset_schedule_for_test();
set_trigger_hook_for_test(sub { return 0 });
pump_pulse(4500);
is(pulse_snapshot_for_test()->{next}{'gm-ctf'}, 8100, 'a failed start still waits out the sweep');
unlike(slurp("$pdir/pulse-last"), qr/^gm-ctf\t/m, 'a failed start is not a saved exit');
set_trigger_hook_for_test(undef);
finish_pulse_channel('gm-ctf', 4500);
is(pulse_snapshot_for_test()->{next}{'gm-ctf'}, 8100, 'an exit still starts the sweep wait');
like(slurp("$pdir/pulse-last"), qr/^gm-ctf\t4500$/m, 'the exit is stored for the next start');
like(slurp("$pdir/pulse-last"), qr/^knf\t1000$/m, 'another channel keeps its saved exit');
set_state_dir_for_test($pdir);
is(load_config($saved), '', 'a second start reads the exit just saved');
is(pulse_snapshot_for_test()->{next}{'gm-ctf'}, 8100, 'restart does not run a channel still inside sweep');
is_deeply([due_pulse_channels(8000)], [qw(knf knfmobile)], 'only channels past their sweep are due');
open my $rew, '>', "$pdir/pulse-last" or die "rewrite pulse-last: $!";
print $rew "# channel\tlast\nknf\t1\n";
close $rew;
is(reload_config_now($saved), '', 'reload does not reread pulse-last');
is(pulse_snapshot_for_test()->{next}{knf}, 4600, 'reload keeps the clock already in memory');
unlink $saved;

done_testing;

sub slurp {
    my ($file) = @_;
    open my $in, '<', $file or die "read $file: $!";
    local $/;
    return scalar <$in>;
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
