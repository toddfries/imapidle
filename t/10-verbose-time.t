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
like($kept, qr/\[acct\] \* 1 EXISTS/, 'EXISTS is still logged');
like($kept, qr/A001 OK IDLE completed/, 'a tagged reply is still logged');

set_verbose_for_test(1);
my $loud = capture(sub {
    trace_imap_line('acct', '* OK Still here');
    note_idle_rearmed('acct');
});
like($loud, qr/\[acct\] \* OK Still here/, '-v logs the server keepalive');
like($loud, qr/\[acct\] IDLE re-armed/, '-v logs the re-arm notice');
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

my $zero = child_exit_summary('mbsync ch', 9, 0, 1.25, $ru);
like($zero, qr/^mbsync ch pid 9 exited 0  1\.25 real /, 'a zero status says exited 0');
my $bad = child_exit_summary('mbsync ch', 9, 3 << 8, 1, $ru);
like($bad, qr/^mbsync ch pid 9 exit 3  /, 'a non-zero status says exit N');
my $sig = child_exit_summary('mbsync ch', 9, 15, 1, $ru);
like($sig, qr/^mbsync ch pid 9 signal 15  /, 'a signal status names the signal');

set_foreground_for_test(0);
clear_children_for_test();
my $true_line = reap_one('/usr/bin/true', 'mbsync true');
like($true_line, qr/^mbsync true pid \d+ exited 0  \d+\.\d\d real \d+\.\d\d user \d+\.\d\d sys rss \d+k minflt \d+ majflt \d+ inblock \d+ oublock \d+ nvcsw \d+ nivcsw \d+$/,
    'wait4 records a successful child on one line');
my ($rss) = $true_line =~ /rss (\d+)k/;
cmp_ok($rss, '>', 0, 'the resident set came from the child');

my $exit_line = reap_one('/usr/bin/perl', 'mbsync bad', '-e', 'exit 3');
like($exit_line, qr/^mbsync bad pid \d+ exit 3  \d+\.\d\d real \d+\.\d\d user \d+\.\d\d sys rss \d+k /,
    'a non-zero child keeps the same stats tail');

done_testing;

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
        last if defined $line && $line =~ /\bpid $pid\b/;
        select(undef, undef, undef, 0.05);
    }
    return $line // '';
}
