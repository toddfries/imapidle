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
[offline]
sweep = soon
channel0 = gm-ctf
EOF
like(load_config($bad_sweep), qr/\[offline\] bad sweep/, 'a non-numeric sweep is rejected');
unlink $bad_sweep;

my $gap = write_conf(<<'EOF');
[offline]
channel0 = gm-ctf
channel2 = knf
EOF
like(load_config($gap), qr/\[offline\] gap before channel1/, 'a missing channel number is an error');
unlink $gap;

my $empty = write_conf(<<'EOF');
[offline]
channel0 =
EOF
like(load_config($empty), qr/\[offline\] empty channel0/, 'an empty channel is rejected');
unlink $empty;

my $colon = write_conf(<<'EOF');
[offline]
channel0 = gm:ctf
EOF
like(load_config($colon), qr/\[offline\] bad channel0/, 'a colon in a channel name is rejected');
unlink $colon;

my $dash = write_conf(<<'EOF');
[offline]
channel0 = -a
EOF
like(load_config($dash), qr/\[offline\] bad channel0/, 'a channel name may not be an mbsync flag');
unlink $dash;

my $dup = write_conf(<<'EOF');
[offline]
channel0 = gm-ctf
channel1 = gm-ctf
EOF
like(load_config($dup), qr/\[offline\] duplicate channel gm-ctf/, 'a repeated channel is rejected');
unlink $dup;

my $held = write_conf(<<'EOF');
[offline]
disabled = yes
sweep = no
EOF
is(load_config($held), '', 'disabled = yes does not check the offline keys');
is(offline_snapshot_for_test()->{disabled}, 1, 'the section is held');
is_deeply([due_offline_channels(1000)], [], 'a held section starts nothing');
is_deeply([grep { /^offline: / } info_lines(1000)], ['offline: disabled'], 'state names the held section');
unlink $held;

my $only = write_conf(<<'EOF');
[offline]
channel0 = gm-ctf
channel1 = knf
EOF
is(load_config($only), '', 'a file with only offline channels loads');
is_deeply([account_names()], [], 'no IMAP account is required');
is(offline_snapshot_for_test()->{sweep}, 3600, 'an omitted sweep is 3600');
is_deeply(offline_snapshot_for_test()->{channels}, [qw(gm-ctf knf)], 'channels stay in order');
is_deeply([due_offline_channels(1000)], [qw(gm-ctf knf)], 'the first load is due together');

my $now = time();
set_offline_next_for_test('gm-ctf', $now + 10);
set_offline_next_for_test('knf', $now + 100);
my $wait = loop_timeout();
cmp_ok($wait, '>', 8, 'the loop wakes for the nearer offline channel');
cmp_ok($wait, '<=', 10, 'the loop does not sleep past that channel');
note_child_for_test(1, 'mbsync gm-ctf');
note_child_for_test(2, 'mbsync knf');
set_offline_next_for_test('gm-ctf', $now - 5);
set_offline_next_for_test('knf', $now - 5);
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

[offline]
sweep = 3600
channel0 = gm-ctf
channel1 = knf
channel2 = knfmobile
EOF
is(load_config($path), '', 'accounts and offline channels load together');
is(loaded_account('acct')->{mbsync_channel}, 'fdc-main', 'the account is unchanged');
is_deeply(
    [due_offline_channels(1000)],
    [qw(gm-ctf knf knfmobile)],
    'every offline channel is due on the first load',
);
is_deeply(
    [grep { /: offline sweep / } info_lines(1000)],
    [
        'gm-ctf: offline sweep 3600s due',
        'knf: offline sweep 3600s due',
        'knfmobile: offline sweep 3600s due',
    ],
    'state shows each channel due',
);

clear_children_for_test();
reset_schedule_for_test();
note_child_for_test(9, 'mbsync gm-ctf');
is_deeply(
    [due_offline_channels(1000)],
    [qw(knf knfmobile)],
    'a running channel does not start a second copy',
);
is_deeply(
    [grep { /^gm-ctf: offline / } info_lines(1000)],
    ['gm-ctf: offline sweep 3600s running'],
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
    [due_offline_channels(1000)],
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
    [due_offline_channels(1000)],
    [qw(gm-ctf knf knfmobile)],
    'the bare channel starts once its folder sync is gone',
);

finish_offline_channel('gm-ctf', 1009);
finish_offline_channel('knf', 1018);
finish_offline_channel('knfmobile', 1040);
is(offline_snapshot_for_test()->{next}{'gm-ctf'}, 4609, 'gm-ctf waits 3600s from its own exit');
is(offline_snapshot_for_test()->{next}{knf}, 4618, 'knf waits 3600s from its own exit');
is(offline_snapshot_for_test()->{next}{knfmobile}, 4640, 'knfmobile waits 3600s from its own exit');
is_deeply([due_offline_channels(4608)], [], 'nothing is due one second early');
is_deeply([due_offline_channels(4609)], ['gm-ctf'], 'only the channel whose wait ended is due');
is_deeply([due_offline_channels(4618)], [qw(gm-ctf knf)], 'each clock stays independent');
is_deeply([due_offline_channels(4640)], [qw(gm-ctf knf knfmobile)], 'a later exit is due later');
is_deeply(
    [grep { /^gm-ctf: offline / } info_lines(1109)],
    ['gm-ctf: offline sweep 3600s next 3500s'],
    'state shows the remaining wait',
);

my $edited = write_conf(<<'EOF');
[acct]
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = fdc-main
folder0 = INBOX

[offline]
sweep = 60
channel0 = gm-ctf
channel1 = archive
EOF
is(reload_config_now($edited), '', 'reload accepts a new offline list');
my $snap = offline_snapshot_for_test();
is($snap->{sweep}, 60, 'reload stores the new sweep');
is_deeply($snap->{channels}, [qw(gm-ctf archive)], 'channel order follows the file');
is($snap->{next}{'gm-ctf'}, 4609, 'a channel that remains keeps its clock');
is($snap->{next}{archive}, 0, 'a new channel is due immediately');
ok(!exists $snap->{next}{knf}, 'a removed channel is not scheduled');
finish_offline_channel('gm-ctf', 5000);
is(offline_snapshot_for_test()->{next}{'gm-ctf'}, 5060, 'the new sweep applies when the run exits');

my $bad = write_conf(<<'EOF');
[acct]
server = imap.example.com
EOF
isnt(reload_config_now($bad), '', 'a bad file is rejected');
is(offline_snapshot_for_test()->{next}{'gm-ctf'}, 5060, 'a rejected file keeps the offline clock');
is_deeply(
    offline_snapshot_for_test()->{channels},
    [qw(gm-ctf archive)],
    'a rejected file keeps the offline channels',
);
unlink $bad;

my $off = write_conf(<<'EOF');
[acct]
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = fdc-main
folder0 = INBOX

[offline]
disabled = YES
channel0 = gm-ctf
EOF
is(reload_config_now($off), '', 'reload accepts disabled = yes');
is(offline_snapshot_for_test()->{disabled}, 1, 'reload holds the section');
is_deeply([due_offline_channels(9000)], [], 'a held section stays idle');
unlink $off;

is(reload_config_now($path), '', 'removing yes enables the section');
is(offline_snapshot_for_test()->{disabled}, 0, 'the section is active again');
is(offline_snapshot_for_test()->{sweep}, 3600, 'the saved sweep returns');
is_deeply(
    [due_offline_channels(9000)],
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
is(reload_config_now($gone), '', 'reload accepts a file with no offline section');
is_deeply(offline_snapshot_for_test()->{channels}, [], 'dropping the section drops the channels');
is_deeply([due_offline_channels(9000)], [], 'nothing offline is due');
unlink $gone;
unlink $edited;
unlink $path;

done_testing;
