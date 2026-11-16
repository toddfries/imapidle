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

is(load_config($path), '', 'config loads');
clear_conns_for_test();
clear_children_for_test();
reset_schedule_for_test();
set_next_try_for_test('acct', 5000);

my @down = info_lines(4900);
like($down[0], qr/^imapidle: info \d+ accounts 1 connections 0 mbsync 0$/, 'header counts a down account');
is($down[1], 'acct: down server imap.example.com channel ch retry 100s', 'a down account reports the retry');
is($down[2], 'acct: INBOX priority 5 gap 420s resync 43200s last never', 'a quiet folder has never synced');

plant_idle_for_test('acct', 'INBOX', 420, 'ch');
note_mail_event('ch', 'INBOX', 420, 0, 1000);
my @ready = info_lines(1004);
is($ready[1], 'acct: IDLE INBOX server imap.example.com channel ch', 'an IDLE account is not down');
is($ready[2], 'acct: INBOX priority 5 gap 420s resync 43200s last never pending ready combine 1s',
    'a ready event is inside the combine window');

is_deeply([due_mbsync_jobs(1005)], [ { args => ['ch:INBOX'], wait => 0 } ], 'the window ends');
note_mail_event('ch', 'INBOX', 420, 0, 1100);
my @kept = info_lines(1100);
is($kept[2], 'acct: INBOX priority 5 gap 420s resync 43200s last 95s ago pending 325s',
    'an event inside the gap shows when it will run');

clear_conns_for_test();
plant_notify_for_test('acct');
my @notify = info_lines(1100);
is($notify[1], 'acct: NOTIFY server imap.example.com channel ch', 'NOTIFY is reported');

note_child_for_test(9, 'mbsync ch:INBOX');
my @child = info_lines(1100);
like($child[0], qr/mbsync 1$/, 'a child is counted');
is($child[-1], sprintf('ch: child %s[%5d] INBOX', sha1_b('ch:INBOX'), 9),
    'the child command is shown');
clear_children_for_test();

set_foreground_for_test(1);
my $printed = capture_report(1100);
like($printed, qr/^imapidle: imapidle: info \d+ accounts /m, '-d prints the state to stderr');
like($printed, qr/^imapidle: acct    : NOTIFY /m, 'the account name is left-aligned to the colon');
set_foreground_for_test(0);
my $quiet = capture_report(1100);
is($quiet, '', 'a daemon does not also print the state');

done_testing;

sub capture_report {
    my ($now) = @_;
    open my $old, '>&', \*STDERR or die "dup stderr: $!";
    close STDERR;
    my $buf = '';
    open STDERR, '>', \$buf or die "redirect stderr: $!";
    report_info($now);
    open STDERR, '>&', $old or die "restore stderr: $!";
    close $old;
    return $buf;
}
