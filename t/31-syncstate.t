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
use File::Path qw(make_path);
use File::Temp qw(tempdir tempfile);
use Test::More;

require './imapidle';

my @keep = (
    'Drafts', 'drafts', 'DRAFTS', 'Draft',
    'Sent', 'sent', 'Sent Items', 'Sent Messages', 'Sent Mail',
    '[Gmail]/Sent Mail',
);
my @drop = (
    'Trash', 'Calendar', 'Calendar/United States holidays',
    'INBOX', 'Junk', 'notme.2026-11',
);
ok(state_keep_hit($_), "kept $_") for @keep;
ok(!state_keep_hit($_), "not kept $_") for @drop;
ok(sync_state_issue(
    'Error: incomplete sync state entry at /x/Trash/.mbsyncstate:236'),
    'incomplete state file is a sync-state failure');
ok(sync_state_issue(
    'Error: channel ma-ttf, far side box Calendar: '
    . 'Unable to recover from UIDVALIDITY change.'),
    'UIDVALIDITY recovery failure is a sync-state failure');
ok(!sync_state_issue('Error: connection refused'),
    'a plain mbsync error is not a sync-state failure');

my $root = tempdir('imapidle-state-XXXX', CLEANUP => 1, TMPDIR => 1);
my $store = "$root/mail";
my $rc = <<"RC";
MaildirStore near
Path $store/

Channel demo
Near :near:
Patterns *
Sync Full
SyncState *
RC

sub maildir {
    my ($box) = @_;
    my $dir = "$store/$box";
    make_path("$dir/cur", "$dir/new", "$dir/tmp");
    open my $fh, '>', "$dir/.mbsyncstate" or die $!;
    print $fh "FarUidValidity 1\n";
    close $fh;
    open $fh, '>', "$dir/cur/msg" or die $!;
    print $fh "x\n";
    close $fh;
    return $dir;
}

sub recover {
    my ($err, $args) = @_;
    reset_batch_for_test();
    return recover_sync_state($err, { args => $args }, $rc);
}

my $trash = maildir('Trash');
ok(recover(
    "Error: incomplete sync state entry at $trash/.mbsyncstate:236",
    ['demo']),
    'a broken Trash state removes the mailbox');
ok(!-d $trash, 'Trash is gone');
is_deeply([batch_folders_for_test()], ['demo:Trash'],
    'only Trash is queued again');

my $sent = maildir('Sent Items');
ok(!recover(
    'Error: channel demo, far side box Sent Items: '
    . 'Unable to recover from UIDVALIDITY change.',
    ['demo']),
    'Sent Items is not removed');
ok(-f "$sent/.mbsyncstate", 'Sent Items state file remains');
is_deeply([batch_folders_for_test()], [], 'a kept mailbox is not queued');

my $cal = maildir('Calendar/United States holidays');
ok(recover(
    'Error: channel demo, far side box Calendar/United States holidays: '
    . 'Unable to recover from UIDVALIDITY change.',
    ['demo']),
    'a calendar mailbox is removed');
ok(!-d $cal, 'the holidays mailbox is gone');

my $outside = "$root/outside/Trash";
make_path("$outside/cur");
open my $fh, '>', "$outside/.mbsyncstate" or die $!;
close $fh;
ok(!recover(
    "Error: incomplete sync state entry at $outside/.mbsyncstate:4",
    ['demo:Trash']),
    'a state file outside the store is not removed');
ok(-d $outside, 'the outside directory remains');
maildir('Trash');
ok(-d "$store/Trash", 'store Trash was recreated for the outside test');
ok(!recover(
    "Error: incomplete sync state entry at $outside/.mbsyncstate:4",
    ['demo']),
    'an outside path does not fall through to another mailbox');
ok(-d "$store/Trash", 'store Trash remains when the path is outside');

ok(!recover('Error: connection refused', ['demo:Trash']),
    'a refused connection does not remove the mailbox');
ok(-d "$store/Trash", 'Trash remains after an ordinary error');

my ($cfh, $conf) = tempfile('imapidle-XXXX', SUFFIX => '.conf', TMPDIR => 1);
print $cfh <<'EOF';
[track]
type = global
state_keep = ^Calendar$

[acct]
type = account
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = demo
EOF
close $cfh;
is(load_config($conf), '', 'an override pattern loads');
ok(state_keep_hit('Calendar'), 'the override keeps Calendar');
ok(!state_keep_hit('Trash'), 'the override does not keep Trash');
ok(!state_keep_hit('Drafts'), 'the override replaces the default');
unlink $conf;

my ($bfh, $bad) = tempfile('imapidle-XXXX', SUFFIX => '.conf', TMPDIR => 1);
print $bfh <<'EOF';
[track]
type = global
state_keep = (

[acct]
type = account
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = demo
EOF
close $bfh;
like(load_config($bad), qr/\[track\] bad state_keep/, 'a bad pattern is rejected');
ok(state_keep_hit('Drafts'), 'a rejected pattern leaves the default');
unlink $bad;

my ($pfh, $plan) = tempfile('imapidle-XXXX', SUFFIX => '.conf', TMPDIR => 1);
print $pfh <<'EOF';
[acct]
type = account
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = demo

[watch]
type = idle
channel = acct
folder0 = Drafts
folder1 = Trash
folder2 = INBOX
folder3 = Sent Items
EOF
close $pfh;
is(load_config($plan), '', 'a folder list loads for the verbose plan');
my $shown = state_keep_plan();
like($shown, qr/^state_keep \(\?:/, 'the plan names the pattern');
like($shown, qr/keep Drafts, Sent Items/, 'the plan keeps draft and sent names');
like($shown, qr/remove INBOX, Trash/, 'the plan would remove the other names');
unlink $plan;

done_testing;
