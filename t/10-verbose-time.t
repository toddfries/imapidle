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
use MIME::Base64 qw(encode_base64);
use Test::More;

require './imapidle';

set_foreground_for_test(1);
set_verbose_for_test(0);

my $quiet = capture(sub {
    trace_imap_line('acct', '* OK Still here');
    trace_imap_line('acct', '* OK Still here ');
    note_idle_rearmed('acct');
});
is($quiet, '', 'keepalive lines stay quiet without -v');

my $kept = capture(sub {
    trace_imap_line('acct', '* 1 EXISTS');
    trace_imap_line('acct', 'A001 OK IDLE completed');
});
like($kept, qr/acct    : \* 1 EXISTS/, 'EXISTS is still logged');
like($kept, qr/A001 OK IDLE completed/, 'a tagged reply is still logged');

set_verbose_for_test(1);
my $loud = capture(sub {
    trace_imap_line('acct', '* OK Still here');
    note_idle_rearmed('acct');
});
like($loud, qr/acct    : \* OK Still here/, '-v logs the server keepalive');
like($loud, qr/acct    : IDLE re-armed/, '-v logs the re-arm notice');
set_verbose_for_test(0);

my $ru = pack('q18',
    1, 500000,
    0, 250000,
    12340,
    0, 0, 0,
    50, 2,
    0,
    12, 3,
    0, 0, 0,
    8, 11,
);
is(format_time_stats(10.05, $ru),
    '10.05 real 1.50 user 0.25 sys rss 12340k minflt 50 majflt 2 inblock 12 oublock 3 nvcsw 8 nivcsw 11',
    'packed rusage becomes one time -l line');
like(format_time_stats(-3, undef), qr/^0\.00 real /, 'a negative duration is zero');

is(exit_how(0), 'ret 0', 'a zero status says ret 0');
is(exit_how(3 << 8), 'ret 3', 'a non-zero status says ret N');
is(exit_how(15), 'sig 15', 'a signal status stays a signal');

reset_mbsync_real_for_test();
is(note_mbsync_real("fdc-list:INBOX\0fdc-list:Archive", 2, $ru),
    'x1 2.00|2.00s 12340|12340rss',
    'the first run of a command is its own average');
is(note_mbsync_real("fdc-list:INBOX\0fdc-list:Archive", 4, $ru),
    'x2 4.00|3.00s 12340|12340rss',
    'the average is the total real time divided by the count');
is(note_mbsync_real('knf', 10), 'x1 10.00|10.00s',
    'a run without rusage keeps the real average only');
set_verbose_for_test(1);
is(note_mbsync_real('knf', 12.34, $ru),
    'x2 12.34|11.17s 1.50|1.50user 0.25|0.25sys 12340|12340rss 50|50minflt 2|2majflt 12|12inblock 3|3oublock 8|8nvcsw 11|11nivcsw',
    '-v adds the totaled fields');
set_verbose_for_test(0);
reset_mbsync_real_for_test();

set_foreground_for_test(0);
clear_children_for_test();
my $true_line = reap_one('/usr/bin/true', 'mbsync true');
like($true_line, qr/^true: stop  \S{27}=\[\s*\d+\] ret 0 x1 \d+\.\d\d\|\d+\.\d\ds \d+\|\d+rss\z/,
    'wait4 records a successful child on one line');
unlike($true_line, qr/user/, 'the default stop line omits user time');
my ($rss) = $true_line =~ /(\d+)\|\d+rss/;
cmp_ok($rss, '>', 0, 'the resident set came from the child');

my $exit_line = reap_one('/usr/bin/perl', 'mbsync bad', '-e', 'exit 3');
like($exit_line, qr/^bad: stop  \S{27}=\[\s*\d+\] ret 3 x1 \d+\.\d\d\|\d+\.\d\ds \d+\|\d+rss\z/,
    'a non-zero child keeps the same stats tail');

set_verbose_for_test(1);
my $loud_exit = reap_one('/usr/bin/true', 'mbsync verb');
like($loud_exit, qr/ \d+\.\d\d\|\d+\.\d\duser \d+\.\d\d\|\d+\.\d\dsys \d+\|\d+rss \d+\|\d+minflt \d+\|\d+majflt \d+\|\d+inblock \d+\|\d+oublock \d+\|\d+nvcsw \d+\|\d+nivcsw\z/,
    '-v prints every totaled field on the stop line');
set_verbose_for_test(0);

my $one = sha1_b('fdc-list:INBOX.2026-11');
is(mbsync_job_line('start', 4123, 'fdc-list:INBOX.2026-11'),
    "fdc-list: start ${one}[ 4123] INBOX.2026-11",
    'a start line names the channel once');
my $two = sha1_b("fdc-list:INBOX.2026-11\0fdc-list:openbsd.2026-11");
is(mbsync_job_line('stop', 41230, 'fdc-list:INBOX.2026-11', 'fdc-list:openbsd.2026-11'),
    "fdc-list: stop  ${two}[41230] INBOX.2026-11,openbsd.2026-11",
    'mailboxes follow the hash, comma-separated');
is(mbsync_job_line('start', 99, 'knf'),
    'knf: start ' . sha1_b('knf') . '[   99]',
    'a bare channel has no mailbox');
is(mbsync_phrase('fork mbsync', 'fdc-list:INBOX'),
    'fdc-list: fork mbsync INBOX',
    'a fork failure still names the channel once');

my $dir = tempdir('imapidle-real-XXXX', CLEANUP => 1, TMPDIR => 1);
set_state_dir_for_test($dir);
my $old_cli = 'fdc:Archive';
my $old_b64 = encode_base64($old_cli, '');
my $token   = sha1_b($old_cli);
open my $oldfh, '>', "$dir/mbsync-real" or die "mbsync-real: $!";
print $oldfh "# key\tcount\ttotal\n";
print $oldfh "$old_b64\t2\t10\n";
print $oldfh "$token\t1\t5\n";
close $oldfh;
my $conn_cli = "fdc\0INBOX";
open my $cfh, '>', "$dir/conn-time" or die "conn-time: $!";
print $cfh "# key\tcount\ttotal\n";
print $cfh encode_base64($conn_cli, ''), "\t4\t40\n";
close $cfh;
reset_mbsync_real_for_test();
reset_conn_time_for_test();
load_stat_files();
is_deeply([stat_pair_for_test('mbsync', $old_cli)], [3, 15, 0],
    'an old base64 row merges onto sha1 -b and keeps the real total');
is_deeply([stat_pair_for_test('conn', $conn_cli)], [4, 40, 0],
    'an old conn-time key loads as sha1 -b');
my $up = note_mbsync_real($old_cli, 4, $ru);
is($up, 'x4 4.00|4.75s 12340|12340rss',
    'a new rss average is not divided by the old count');
is_deeply([stat_pair_for_test('mbsync', $old_cli)], [4, 19, 1],
    'the rusage sample count starts at the new run');
my $saved = slurp("$dir/mbsync-real");
like($saved, qr/^\Q$token\E\t4\t19\t/m, 'the next write stores sha1 -b');
unlike($saved, qr/^\Q$old_b64\E\t/m, 'the old base64 key is not written back');
save_stat_files();
my $conn_saved = slurp("$dir/conn-time");
my $conn_token = sha1_b($conn_cli);
like($conn_saved, qr/^\Q$conn_token\E\t4\t40$/m, 'conn-time stays three columns');

chomp(my $bin = `printf '%s' INBOX | /bin/sha1 -q -b`);
is(sha1_b('INBOX'), $bin, 'sha1 -b matches /bin/sha1 -q -b');
is(sha1_b("channel:INBOX\0channel:Archive"), 'nkgNE3Q9Nrkqsym8pREprvJ4Tv8=',
    'the two-mailbox vector is sha1 -b');

done_testing;

sub slurp {
    my ($file) = @_;
    open my $in, '<', $file or die "read $file: $!";
    local $/;
    return scalar <$in>;
}

sub capture {
    my ($code) = @_;
    my ($fh, $path) = tempfile('imapidle-v-XXXX', UNLINK => 1, TMPDIR => 1);
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

sub reap_one {
    my ($prog, $label, @args) = @_;
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        exec $prog, @args;
        exit 1;
    }
    note_child_for_test($pid, $label);
    my $line = '';
    for (1 .. 50) {
        reap_children();
        $line = last_child_exit_for_test();
        last if defined $line && $line =~ /\[\s*\Q$pid\E\]/;
        select(undef, undef, undef, 0.05);
    }
    return $line // '';
}
