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
use File::Temp qw(tempdir);
use POSIX qw(_exit);
use Test::More;

require './imapidle';

is(_prepare_log('-> 10530'), '-> 10530', 'handoff stays out of the name column');

{
    pipe(my $rd, my $wr) or die "pipe: $!";
    syswrite($wr, "10530\n") or die "syswrite: $!";
    close $wr;
    my ($pid, $why) = _read_handoff($rd);
    is($pid, '10530', 'handoff reads the daemon pid');
    is($why, '', 'a pid is not an error');
}

{
    pipe(my $rd, my $wr) or die "pipe: $!";
    syswrite($wr, "fail setsid failed: no\n") or die "syswrite: $!";
    close $wr;
    my ($pid, $why) = _read_handoff($rd);
    ok(!defined $pid, 'a fail line has no pid');
    is($why, 'setsid failed: no', 'handoff keeps the fail text');
}

{
    pipe(my $rd, my $wr) or die "pipe: $!";
    close $wr;
    my ($pid, $why) = _read_handoff($rd);
    ok(!defined $pid, 'a closed pipe has no pid');
    is($why, 'fork failed', 'a closed pipe is a failed fork');
}

my $dir  = tempdir('imapidle-handoff-XXXX', CLEANUP => 1, TMPDIR => 1);
my $sink = "$dir/log";
set_handoff_sink_for_test($sink);
my $starter = fork();
die "fork: $!" unless defined $starter;
if ($starter == 0) {
    daemonize();
    open my $fh, '>>', $sink or _exit(2);
    print $fh "daemon $$\n";
    close $fh;
    _exit(0);
}
waitpid($starter, 0);
is($? >> 8, 0, 'starting process exits 0');

my $text = '';
my $deadline = time() + 3;
while (time() < $deadline) {
    if (open my $fh, '<', $sink) {
        local $/;
        $text = <$fh> // '';
        close $fh;
    }
    last if $text =~ /^daemon \d+$/m;
    select(undef, undef, undef, 0.05);
}
like($text, qr/^$starter info -> (\d+)$/m, 'starter logs the arrow and the daemon pid');
my ($daemon) = $text =~ /^$starter info -> (\d+)$/m;
like($text, qr/^daemon $daemon$/m, 'the logged pid is the process that remains')
    if defined $daemon;
is(scalar(grep { / info -> / } split /\n/, $text), 1, 'one handoff line');
unlike($text, qr/daemonizing/, 'the old daemonizing line is gone');

done_testing;
