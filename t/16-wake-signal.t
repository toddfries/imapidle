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

my $run = tempdir('imapidle-sig-XXXX', CLEANUP => 1, TMPDIR => 1);
set_runtime_dir_for_test($run);
set_state_dir_for_test($run);
set_foreground_for_test(0);

install_chld_signal();
ok(wake_holds_chld_for_test(), 'SIGCHLD stays blocked outside the wait');

pipe(my $rd, my $wr) or die "pipe: $!";
vec(my $rin = '', fileno($rd), 1) = 1;
my $idle = _pselect($rin, my $win = '', my $ein = '', 0.05);
is($idle, 0, 'pselect times out when nothing is readable');
syswrite($wr, 'x') or die "syswrite: $!";
$rin = '';
vec($rin, fileno($rd), 1) = 1;
my $hit = _pselect($rin, $win, $ein, 0.5);
ok(defined $hit && $hit > 0 && vec($rin, fileno($rd), 1),
    'pselect reports the readable pipe');
close $rd;
close $wr;

my $kid = fork();
die "fork: $!" unless defined $kid;
if ($kid == 0) {
    _restore_wake_mask();
    _exit(wake_holds_chld_for_test() ? 1 : 0);
}
waitpid($kid, 0);
is($? >> 8, 0, 'a child gets the mask from before the block');

my @pids;
for (1 .. 40) {
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        _exit(0);
    }
    push @pids, $pid;
    my $junk = '';
    $junk .= 'x' x 4096 for 1 .. 10;
}
ok(kill(0, $$), 'exits during allocation do not abort');
ok(chld_ready_for_test(2), 'a child exit wakes the pipe');
my $end = time() + 1;
do {
    reap_children();
    select(undef, undef, undef, 0.02);
} while (time() < $end);
my $left = 0;
for my $pid (@pids) {
    my $got = waitpid($pid, POSIX::WNOHANG());
    $left++ unless defined $got && $got == -1;
}
is($left, 0, 'every short child was reaped');

done_testing;
