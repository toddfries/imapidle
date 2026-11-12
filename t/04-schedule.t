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
ok(mail_event_line('* 12 FETCH (FLAGS (\Seen))'), 'FETCH is mail');
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

done_testing;

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
