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
use Time::HiRes qw(time);

require './imapidle';

my $run = tempdir('imapidle-run-XXXX', CLEANUP => 1, TMPDIR => 1);
my $state = tempdir('imapidle-state-XXXX', CLEANUP => 1, TMPDIR => 1);
set_runtime_dir_for_test($run);
set_state_dir_for_test($state);
set_interval_spread_for_test(sub { 0 });

sub write_conf {
    my ($text) = @_;
    my ($fh, $path) = tempfile('imapidle-XXXX', SUFFIX => '.conf', TMPDIR => 1);
    print $fh $text;
    close $fh;
    return $path;
}

sub row {
    my ($box) = @_;
    my ($found) = grep { $_->{box} eq $box } track_rows_for_test();
    return $found;
}

{
    package StatusIMAP;
    sub new {
        my ($class, $replies) = @_;
        return bless { replies => $replies, cmds => [] }, $class;
    }
    sub IsConnected { 1 }
    sub LastError   { '' }
    sub tag_and_run {
        my ($self, $cmd) = @_;
        push @{ $self->{cmds} }, $cmd;
        my ($box) = $cmd =~ /STATUS "((?:\\.|[^"\\])*)"/;
        $box =~ s/\\"/"/g if defined $box;
        $box =~ s/\\\\/\\/g if defined $box;
        my $lines = $self->{replies}{$box // ''} // [];
        return @$lines;
    }
}

my $bad_sweep = write_conf(<<'EOF');
[pulse]
type = pulse
sweep = soon
channel0 = knf
EOF
like(load_config($bad_sweep), qr/\[pulse\] bad sweep/, 'a non-numeric sweep is rejected');

my $gap = write_conf(<<'EOF');
[pulse]
type = pulse
channel0 = knf
channel2 = other
EOF
like(load_config($gap), qr/\[pulse\] gap before channel1/, 'a missing channel number is an error');

my $empty = write_conf(<<'EOF');
[pulse]
type = pulse
channel0 =
EOF
like(load_config($empty), qr/\[pulse\] empty channel0/, 'an empty channel is rejected');

my $colon = write_conf(<<'EOF');
[pulse]
type = pulse
channel0 = gm:ctf
EOF
like(load_config($colon), qr/\[pulse\] bad channel0/, 'a colon in a channel name is rejected');

my $dash = write_conf(<<'EOF');
[pulse]
type = pulse
channel0 = -V
EOF
like(load_config($dash), qr/\[pulse\] bad channel0/, 'a channel name may not be an mbsync flag');

my $dup = write_conf(<<'EOF');
[knf]
type = account
server = imap.example.com
user = a@example.com
pass = secret

[pulse]
type = pulse
channel0 = knf
channel1 = knf
EOF
like(load_config($dup), qr/\[pulse\] duplicate channel knf/, 'a repeated channel is rejected');

my $held = write_conf(<<'EOF');
[pulse]
type = pulse
disabled = yes
sweep = soon
channel0 =
EOF
is(load_config($held), '', 'disabled = yes does not check the pulse keys');
is(pulse_snapshot_for_test()->{disabled}, 1, 'the section is held');
is_deeply([due_pulse_channels(1000)], [], 'a held section starts nothing');
is_deeply([grep { /^pulse: / } info_lines(1000)], ['pulse: pulse disabled'],
    'state names the held section');

my $unknown = write_conf(<<'EOF');
[pulse]
type = pulse
channel0 = knf
EOF
like(load_config($unknown), qr/\[pulse\] unknown account knf/, 'a pulse name must be an account');

my $folded = write_conf(<<'EOF');
[knf]
type = account
server = imap.example.com
user = a@example.com
pass = secret

[pulse]
type = pulse
folder0 = INBOX
channel0 = knf
EOF
like(load_config($folded), qr/\[pulse\] folder/, 'a pulse section cannot name a folder');

my $bare = write_conf(<<'EOF');
[knf]
type = account
server = imap.example.com
user = a@example.com
pass = secret

[pulse]
type = pulse
channel = knf
EOF
like(load_config($bare), qr/\[pulse\] channel/, 'a pulse section uses channelN');

my $on_login = write_conf(<<'EOF');
[knf]
type = account
server = imap.example.com
user = a@example.com
pass = secret
folder0 = INBOX
EOF
like(load_config($on_login), qr/\[knf\] folder/, 'a folder belongs on the idle section');

my $both = write_conf(<<'EOF');
[knf]
type = account
server = imap.example.com
user = a@example.com
pass = secret

[main]
type = idle
channel = knf
server = other.example.com
folder0 = INBOX
EOF
like(load_config($both), qr/\[main\] sets both channel and server/, 'an idle section is a schedule or a login');

my $same = write_conf(<<'EOF');
[knf]
type = account
server = imap.example.com
user = a@example.com
pass = secret

[main]
type = idle
channel = knf
folder0 = INBOX

[pulse]
type = pulse
channel0 = knf
EOF
like(load_config($same), qr/\[pulse\] duplicate account knf/, 'one account is idle or pulse');

my $twice = write_conf(<<'EOF');
[knf]
type = account
server = imap.example.com
user = a@example.com
pass = secret

[a]
type = pulse
channel0 = knf

[b]
type = pulse
channel0 = knf
EOF
like(load_config($twice), qr/\[b\] duplicate account knf/, 'one account is on one pulse section');

my $clash = write_conf(<<'EOF');
[one]
type = account
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = same

[two]
type = account
server = imap.example.com
user = b@example.com
pass = secret
mbsync_channel = same

[main]
type = idle
channel = one
folder0 = INBOX

[pulse]
type = pulse
channel0 = two
EOF
like(load_config($clash), qr/duplicate mbsync channel same/, 'two logins cannot share an mbsync channel');

my $servers = write_conf(<<'EOF');
[fdh]
type = server
host = mail.example.com
port = 993
proto = tls

[plain]
type = server
host = localhost
proto = notls

[start]
type = server
host = mail.example.com
proto = starttls

[kept]
type = account
server = fdh
user = a@example.com
pass = secret
proto = starttls

[moved]
type = account
server = start
user = a@example.com
pass = secret
port = 1993

[clear]
type = account
server = plain
user = a@example.com
pass = secret

[host]
type = account
server = imap.example.com
user = a@example.com
pass = secret
EOF
is(load_config($servers), '', 'server sections load') or diag(load_config($servers));
is(loaded_account('kept')->{server}, 'mail.example.com', 'a server name becomes the host');
is(loaded_account('kept')->{port}, 993, 'an explicit server port is kept when proto changes');
is(loaded_account('kept')->{proto}, 'starttls', 'the account proto replaces the server proto');
is(loaded_account('moved')->{port}, 1993, 'an account port replaces the server port');
is(loaded_account('moved')->{proto}, 'starttls', 'starttls is the server proto');
is(loaded_account('clear')->{proto}, 'notls', 'notls is a clear connection');
is(loaded_account('clear')->{port}, 143, 'notls defaults to port 143');
is(loaded_account('host')->{proto}, 'tls', 'a hostname is implicit TLS');
is(loaded_account('host')->{port}, 993, 'a hostname uses port 993');
my $nodes = ctl_nodes(1000);
is($nodes->{'server.fdh.host'}, 'mail.example.com', 'the control socket shows the server host');
is($nodes->{'server.fdh.port'}, 993, 'the control socket shows the server port');
is($nodes->{'server.fdh.proto'}, 'tls', 'the control socket shows the server proto');
is($nodes->{'account.kept.proto'}, 'starttls', 'the control socket shows the account proto');

my $bad_proto = write_conf(<<'EOF');
[fdh]
type = server
host = mail.example.com
proto = maybe
EOF
like(load_config($bad_proto), qr/\[fdh\] bad proto/, 'a server proto must be tls, starttls, or notls');

my $no_host = write_conf(<<'EOF');
[fdh]
type = server
proto = tls
EOF
like(load_config($no_host), qr/\[fdh\] missing host/, 'a server section needs a host');

my $ok = write_conf(<<'EOF');
[knf]
type = account
server = imap.example.com
user = a@example.com
pass = secret

[other]
type = account
server = imap.example.com
user = b@example.com
pass = secret
mbsync_channel = otherbox

[main]
type = idle
channel = knf
folder0 = INBOX;priority=1
folder1 = Archive

[fast]
type = pulse
sweep = 100
channel0 = other
EOF
is(load_config($ok), '', 'idle and pulse sections load') or diag(load_config($ok));
ok(!loaded_account('main'), 'the idle section name is only a label');
is(loaded_account('knf')->{role}, 'idle', 'channel= selects the idle account');
is(loaded_account('knf')->{mbsync_channel}, 'knf', 'the mbsync channel stays on the account');
is(loaded_account('knf')->{folders}[0]{name}, 'INBOX', 'folderN is watched');
is(loaded_account('knf')->{folders}[0]{debounce}, 7, 'the idle folder keeps its priority');
is(loaded_account('knf')->{folders}[1]{name}, 'Archive', 'a second folder is watched');
is(loaded_account('other')->{role}, 'pulse', 'the pulse account does not idle');
is_deeply(loaded_account('other')->{folders}, [], 'a pulse account has no IDLE folders');
is(loaded_account('other')->{sweep}, 100, 'the pulse sweep is stored on the account');
is(loaded_account('other')->{mbsync_channel}, 'otherbox', 'pulse runs that mbsync channel');
my @info = info_lines(1000);
ok((grep { $_ eq 'other: down server imap.example.com channel otherbox retry 0s' } @info),
    'a pulse login with no socket is down');
ok((grep { /^fast: pulse sweep 100s 1$/ } @info), 'state names the pulse section');

my $legacy = write_conf(<<'EOF'); # keep-inline
[acct]
type = idle
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = personal
folder0 = INBOX
EOF
my $legacy_err = load_config($legacy);
like($legacy_err, qr/\[acct\] server/, 'an inline idle section rejects server');
like($legacy_err, qr/\[acct\] user/, 'an inline idle section rejects user');
like($legacy_err, qr/\[acct\] pass/, 'an inline idle section rejects pass');
like($legacy_err, qr/\[acct\] mbsync_channel/, 'an inline idle section rejects mbsync_channel');
like($legacy_err, qr/\[acct\] missing channel/, 'an inline idle section needs channel');
is_deeply([account_names()], [], 'an inline idle section loads no account');

my $pair = write_conf(<<'EOF');
[knf]
type = account
server = imap.example.com
user = a@example.com
pass = secret

[other]
type = account
server = imap.example.com
user = b@example.com
pass = secret

[fast]
type = pulse
sweep = 100
channel0 = other

[slow]
type = pulse
sweep = 3600
channel0 = knf
hook = echo slow
EOF
is(load_config($pair), '', 'two pulse sections load') or diag(load_config($pair));
is(loaded_account('knf')->{sweep}, 3600, 'slow sweep belongs to knf');
is(loaded_account('other')->{sweep}, 100, 'fast sweep belongs to other');
is(loaded_account('knf')->{pulse_hook}, 'echo slow', 'the section hook is stored on the account');
is(ctl_nodes(1000)->{'pulse.slow.sweep'}, 3600, 'the control socket shows each sweep');
is(ctl_nodes(1000)->{'pulse.fast.sweep'}, 100, 'the other sweep is its own node');

reset_track_for_test();
set_state_dir_for_test($state);
set_interval_spread_for_test(sub { 0 });
my $now = 10_000;
apply_folder_list('knf', ['INBOX'], {}, 1, $now);
my $inbox = row('INBOX');
is($inbox->{pulse}, 1, 'a listed pulse mailbox is marked');
is($inbox->{sweep}, 3600, 'the mailbox keeps its section sweep');
is($inbox->{classified}, 0, 'a new mailbox waits for STATUS');
is($inbox->{next}, $now, 'STATUS is due immediately');
is(ctl_nodes($now)->{'track.box.knf.INBOX.pulse'}, 1, 'the control socket marks a pulse mailbox');

set_track_due_for_test('knf', 'INBOX', 5000);
apply_folder_list('knf', ['INBOX', 'Later'], {}, 1, $now);
is(row('INBOX')->{next}, 5000, 'a later list keeps the mailbox clock');
is(row('Later')->{next}, $now, 'a mailbox that appears later is due for STATUS');
is(row('Later')->{classified}, 0, 'a new name is not classified yet');

my @forked;
set_trigger_hook_for_test(sub {
    my ($wait, $args, $meta) = @_;
    push @forked, { args => [@$args], meta => $meta };
    return hold_child_for_test(80000 + @forked, 'mbsync ' . join(' ', @$args));
});

reset_track_for_test();
set_state_dir_for_test($state);
apply_folder_list('knf', ['INBOX'], {}, 1, $now);
my $empty_imap = StatusIMAP->new({
    INBOX => [qq{* STATUS "INBOX" (MESSAGES 0 UIDNEXT 4)\n}, 'A OK'],
});
set_primary_for_test('knf', 'knf', $empty_imap, 'PULSE');
set_next_try_for_test($_, time() + 10000) for account_names();
set_connections_for_test(1);
hold_child_for_test(42, 'mbsync hot:INBOX');
is(loop_timeout(), 0, 'a due pulse STATUS wakes while every mbsync slot is taken');
@forked = ();
pump_tracked($now);
is_deeply(\@forked, [], 'STATUS does not start mbsync');
ok(scalar @{ $empty_imap->{cmds} }, 'STATUS ran without a free slot');
$inbox = row('INBOX');
is($inbox->{classified}, 1, 'the first empty look is classified');
is($inbox->{empty}, 1, 'no messages keeps the empty class');
is($inbox->{next}, $now + 86400, 'an empty pulse mailbox waits a day, not the sweep');
is($inbox->{confirm}, $now + 604800, 'the first empty look confirms in seven days');
my $held_confirm = $inbox->{confirm};
clear_children_for_test();

set_track_due_for_test('knf', 'INBOX', $now - 1);
@forked = ();
pump_tracked($now);
is_deeply(\@forked, [], 'a later empty look still skips mbsync');
is(row('INBOX')->{confirm}, $held_confirm, 'a later empty look keeps the confirmation');

$empty_imap->{replies}{INBOX} = [qq{* STATUS "INBOX" (MESSAGES 2 UIDNEXT 9)\n}, 'A OK'];
set_track_due_for_test('knf', 'INBOX', $now - 1);
@forked = ();
pump_tracked($now);
is($forked[0]{args}[0], 'knf:INBOX', 'mail in an empty pulse mailbox syncs now');
is($forked[0]{meta}{pulse}, 'knf', 'the child is a pulse mailbox');
clear_children_for_test();
my $gain_id = $forked[0]{meta}{track};
my $summary = "Channels: 1    Boxes: 1    Far: +1 *0 #0 -0    Near: +0 *0 #0 -0\n";
finish_track_job({ track => $gain_id }, 0, 3, $summary, $now + 20);
is(row('INBOX')->{next}, $now + 20 + 3600, 'the sweep starts when that mbsync exits');
is(row('INBOX')->{empty}, 0, 'mail leaves the empty class');
ok(-f "$state/pulse-last", 'the exit is stored for a later mailbox');
my $saved_exit = $now + 20;
like(do { local $/; open my $fh, '<', "$state/pulse-last" or die $!; <$fh> },
    qr/^knf\t$saved_exit$/m, 'pulse-last records that exit');

unlink "$state/pulse-last";
set_state_dir_for_test($state);
reset_track_for_test();
clear_conns_for_test();
clear_children_for_test();
apply_folder_list('knf', ['Fresh'], {}, 1, $now + 30);
my $mail_imap = StatusIMAP->new({
    Fresh => [qq{* STATUS "Fresh" (MESSAGES 4 UIDNEXT 11)\n}, 'A OK'],
});
set_primary_for_test('knf', 'knf', $mail_imap, 'PULSE');
@forked = ();
pump_tracked($now + 30);
is_deeply(\@forked, [], 'the first look at a mailbox with mail does not sync yet');
my $fresh = row('Fresh');
is($fresh->{classified}, 1, 'the first look classifies the mailbox');
is($fresh->{await_sync}, 0, 'the first wait is not a sync');
is($fresh->{next}, $now + 30 + 3600, 'the first wait is one sweep, spread by nothing here');

reset_track_for_test();
clear_conns_for_test();
my $seed_at = $now + 20;
open my $oldf, '>', "$state/pulse-last" or die $!;
print $oldf "knf\t$seed_at\n";
close $oldf;
set_state_dir_for_test($state);
my $late = $seed_at + 3600;
apply_folder_list('knf', ['Seeded'], {}, 1, $late);
my $seed_imap = StatusIMAP->new({
    Seeded => [qq{* STATUS "Seeded" (MESSAGES 1 UIDNEXT 3)\n}, 'A OK'],
});
set_primary_for_test('knf', 'knf', $seed_imap, 'PULSE');
@forked = ();
pump_tracked($late);
is($forked[0]{args}[0], 'knf:Seeded', 'a saved exit that is already a sweep old syncs now');
clear_children_for_test();

reset_track_for_test();
clear_conns_for_test();
my $future_exit = $now + 5000;
open my $pf, '>', "$state/pulse-last" or die $!;
print $pf "knf\t$future_exit\n";
close $pf;
set_state_dir_for_test($state);
apply_folder_list('knf', ['Wait'], {}, 1, $future_exit + 10);
my $wait_imap = StatusIMAP->new({
    Wait => [qq{* STATUS "Wait" (MESSAGES 1 UIDNEXT 3)\n}, 'A OK'],
});
set_primary_for_test('knf', 'knf', $wait_imap, 'PULSE');
@forked = ();
pump_tracked($future_exit + 10);
is_deeply(\@forked, [], 'a recent saved exit does not sync again');
is(row('Wait')->{next}, $future_exit + 3600, 'the saved exit plus one sweep is the clock');

my @spread_add;
set_interval_spread_for_test(sub { shift @spread_add });
my $herd_exit = $now + 8000;
open my $hf, '>', "$state/pulse-last" or die $!;
print $hf "knf\t$herd_exit\n";
close $hf;
set_state_dir_for_test($state);
reset_track_for_test();
clear_conns_for_test();
clear_children_for_test();
my $seen_at = $herd_exit + 100;
@spread_add = (10, 400);
apply_folder_list('knf', ['Academy', 'Archives'], {}, 1, $seen_at);
my $herd_imap = StatusIMAP->new({
    Academy  => [qq{* STATUS "Academy" (MESSAGES 3 UIDNEXT 8)\n}, 'A OK'],
    Archives => [qq{* STATUS "Archives" (MESSAGES 2 UIDNEXT 5)\n}, 'A OK'],
});
set_primary_for_test('knf', 'knf', $herd_imap, 'PULSE');
@forked = ();
pump_tracked($seen_at);
is_deeply(\@forked, [], 'a shared exit does not sync the herd on the first look');
is(row('Academy')->{next}, $herd_exit + 3610, 'the first mailbox adds its own spread');
is(row('Archives')->{next}, $herd_exit + 4000, 'the next mailbox draws a different spread');
isnt(row('Academy')->{next}, row('Archives')->{next}, 'two mailboxes do not share one due time');

unlink "$state/pulse-last";
set_state_dir_for_test($state);
reset_track_for_test();
clear_conns_for_test();
my $open_at = $now + 9000;
@spread_add = (10, 400);
apply_folder_list('knf', ['Academy', 'Archives'], {}, 1, $open_at);
set_primary_for_test('knf', 'knf', $herd_imap, 'PULSE');
@forked = ();
pump_tracked($open_at);
is_deeply(\@forked, [], 'a herd with no saved exit waits out its first sweep');
is(row('Academy')->{next}, $open_at + 3610, 'with no saved exit the first mailbox still spreads');
is(row('Archives')->{next}, $open_at + 4000, 'with no saved exit the next mailbox spreads apart');

my $old_exit = $now + 12000;
open my $of, '>', "$state/pulse-last" or die $!;
print $of "knf\t$old_exit\n";
close $of;
set_state_dir_for_test($state);
reset_track_for_test();
clear_conns_for_test();
my $bare_past = $old_exit + 3600 + 50;
@spread_add = (400);
apply_folder_list('knf', ['Late'], {}, 1, $bare_past);
my $late_imap = StatusIMAP->new({
    Late => [qq{* STATUS "Late" (MESSAGES 1 UIDNEXT 2)\n}, 'A OK'],
});
set_primary_for_test('knf', 'knf', $late_imap, 'PULSE');
@forked = ();
pump_tracked($bare_past);
is_deeply(\@forked, [], 'a spread that is still ahead does not sync yet');
is(row('Late')->{next}, $old_exit + 4000, 'the mailbox waits out its own spread');

reset_track_for_test();
clear_conns_for_test();
clear_children_for_test();
my $elapsed = $old_exit + 3610;
@spread_add = (10);
apply_folder_list('knf', ['Due'], {}, 1, $elapsed);
my $due_imap = StatusIMAP->new({
    Due => [qq{* STATUS "Due" (MESSAGES 1 UIDNEXT 2)\n}, 'A OK'],
});
set_primary_for_test('knf', 'knf', $due_imap, 'PULSE');
@forked = ();
pump_tracked($elapsed);
is($forked[0]{args}[0], 'knf:Due', 'a spread that has already elapsed syncs now');
set_interval_spread_for_test(sub { 0 });

set_pulse_box_for_test('knf', 'INBOX', $now, 3600);
set_pulse_box_for_test('knf', 'Other', $now, 3600);
clear_children_for_test();
@forked = ();
set_connections_for_test(4);
pump_schedule($now);
is(scalar(@forked), 1, 'one mailbox of a channel syncs at a time');
like($forked[0]{args}[0] // '', qr/^knf:/, 'the job names the mailbox');

clear_children_for_test();
@forked = ();
set_trigger_hook_for_test(sub { 0 });
set_pulse_box_for_test('knf', 'INBOX', $now, 3600);
pump_schedule($now);
is(row('INBOX')->{next}, $now + 3600, 'a failed start still waits out the sweep');
ok(!-f "$state/pulse-last" || do {
    open my $fh, '<', "$state/pulse-last";
    local $/;
    my $body = <$fh>;
    $body !~ /^knf\t$now$/m;
}, 'a failed start does not record an exit');

set_trigger_hook_for_test(sub {
    my ($wait, $args, $meta) = @_;
    push @forked, { args => [@$args], meta => $meta };
    return hold_child_for_test(81000 + @forked, 'mbsync ' . join(' ', @$args));
});
clear_children_for_test();
@forked = ();
reset_schedule_for_test();
set_connections_for_test(1);
claim_channel_for_test('otherbox');
set_pulse_box_for_test('otherbox', 'INBOX', $now, 100);
queue_folder('hot', 'INBOX', $now, $now);
pump_schedule($now);
is_deeply([map { $_->{args}[0] } @forked], ['hot:INBOX'], 'cap 1 gives the only slot to the named folder');
is_deeply([due_pulse_channels($now)], ['otherbox'], 'the pulse mailbox stays due');
ok(!defined next_pulse_delay($now), 'a full slot does not spin the pulse clock');

clear_children_for_test();
@forked = ();
reset_schedule_for_test();
set_connections_for_test(2);
set_pulse_box_for_test('otherbox', 'INBOX', $now, 100);
queue_folder('hot', 'INBOX', $now, $now);
queue_folder('hot2', 'INBOX', $now, $now);
pump_schedule($now);
is(scalar(grep { $_->{args}[0] =~ /^hot/ } @forked), 1, 'cap 2 keeps one slot for the named folder');
ok((grep { $_->{args}[0] eq 'otherbox:INBOX' } @forked), 'the other slot syncs the due pulse mailbox');

clear_children_for_test();
@forked = ();
reset_schedule_for_test();
set_connections_for_test(16);
set_pulse_next_for_test('otherbox', 10**12);
queue_folder('h1', 'INBOX', $now, $now);
queue_folder('h2', 'INBOX', $now, $now);
queue_folder('h3', 'INBOX', $now, $now);
pump_schedule($now);
is(scalar(@forked), 3, 'named folders use every slot while pulse is inside its sweep');

clear_children_for_test();
@forked = ();
reset_schedule_for_test();
set_pulse_box_for_test('otherbox', 'INBOX', $now, 100);
set_pulse_box_for_test('knf', 'INBOX', $now, 3600);
queue_folder('h1', 'INBOX', $now, $now);
queue_folder('h2', 'INBOX', $now, $now);
queue_folder('h3', 'INBOX', $now, $now);
pump_schedule($now);
is(scalar(grep { $_->{args}[0] =~ /^h\d:INBOX$/ } @forked), 1,
    'cap 16 still keeps the other slots for pulse mailboxes');
is(scalar(grep { $_->{meta}{pulse} } @forked), 2, 'two pulse channels sync beside that one named folder');

my $edited = write_conf(<<'EOF');
[knf]
type = account
server = imap.example.com
user = a@example.com
pass = secret

[other]
type = account
server = imap.example.com
user = b@example.com
pass = secret

[slow]
type = pulse
sweep = 50
channel0 = knf
EOF
my $before = row('INBOX') ? row('INBOX')->{next} : $now;
is(reload_config_now($edited), '', 'reload accepts a new sweep');
my ($kept) = grep { $_->{channel} eq 'knf' && $_->{box} eq 'INBOX' } track_rows_for_test();
is($kept->{sweep}, 50, 'a reload stores the new sweep on the mailbox');
is($kept->{next}, $before, 'a reload keeps the mailbox clock');
ok(!(grep { $_->{channel} eq 'otherbox' } track_rows_for_test()),
    'a channel that leaves pulse drops its mailboxes');

done_testing;
