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
use Time::HiRes qw(sleep);

require './imapidle';

my $dir = tempdir('imapidle-hook-XXXX', CLEANUP => 1, TMPDIR => 1);
set_foreground_for_test(0);
clear_hooks_for_test();

my $acct = "$dir/acct";
my $pulse = "$dir/pulse";
my $glob = "$dir/glob";
my $same = "$dir/same";
my $slow = "$dir/slow";
my $go = "$dir/go";

my $path = write_conf(<<"EOF");
[good]
type = idle
server = imap.example.com
user = a\@example.com
pass = secret
mbsync_channel = personal
hook = printf a >> $acct

[bare]
type = idle
server = imap.example.com
user = b\@example.com
pass = secret
mbsync_channel = quiet

[pulse]
type = pulse
channel0 = knf
hook = printf p >> $pulse

[track]
type = global
hook = printf g >> $glob
EOF

my $err = load_config($path);
is($err, '', 'hook config loads') or diag($err);
is(loaded_account('good')->{hook}, "printf a >> $acct", 'account hook is kept');
is(loaded_account('bare')->{hook}, '', 'a missing hook is empty');
is(pulse_snapshot_for_test()->{hook}, "printf p >> $pulse", 'pulse hook is kept');
is(track_cfg_for_test()->{hook}, "printf g >> $glob", 'global hook is kept');

my $log = capture(sub {
    maybe_arm_sync_hooks({ args => ['personal:INBOX'] }, 0);
});
unlike($log, qr/\Qprintf a\E/, 'the command text is not logged');
like($log, qr/personal: hook/, 'a start is logged under the channel');
wait_hooks();
ok(-s $acct, 'an account hook runs after exit 0');
ok(-s $glob, 'the global hook runs for that exit');
ok(!-e $pulse, 'a named sync does not run the pulse hook');
is(mbsync_running(), 0, 'a hook is not an mbsync slot');

unlink $acct, $glob;
maybe_arm_sync_hooks({ args => ['personal:INBOX'] }, 256);
wait_hooks();
ok(!-e $acct, 'a non-zero mbsync exit does not run the hook');
ok(!-e $glob, 'the global hook also waits for exit 0');

maybe_arm_sync_hooks({ args => ['knf'], pulse => 'knf' }, 0);
wait_hooks();
ok(-s $pulse, 'a pulse channel runs the pulse hook');
ok(-s $glob, 'a pulse channel also runs the global hook');
ok(!-e $acct, 'a pulse channel does not run another account hook');

unlink $pulse, $glob;
maybe_arm_sync_hooks({ args => ['personal'], pulse => 'personal' }, 0);
wait_hooks();
ok(-s $acct, 'an account hook wins for its own channel');
ok(!-e $pulse, 'the pulse hook does not also run for that channel');

unlink $acct, $glob;
my $same_cmd = "printf s >> $same";
my $both = write_conf(<<"EOF");
[good]
type = idle
server = imap.example.com
user = a\@example.com
pass = secret
mbsync_channel = personal
hook = $same_cmd

[track]
type = global
hook = $same_cmd
EOF
is(load_config($both), '', 'the same command on two sections loads');
my $once = capture(sub {
    maybe_arm_sync_hooks({ args => ['personal:INBOX', 'personal:Archive'] }, 0);
});
wait_hooks();
is(slurp($same), 's', 'one exit runs one copy of the same command');
is(scalar(() = $once =~ /: hook\n/g), 1, 'that copy is logged once');

unlink $same;
my $block = "i=0; while [ ! -f $go ] && [ \$i -lt 100 ]; do sleep 0.05; i=\$((i+1)); done; printf z >> $slow";
my $held = write_conf(<<"EOF");
[good]
type = idle
server = imap.example.com
user = a\@example.com
pass = secret
mbsync_channel = personal
hook = $block

[track]
type = global
EOF
is(load_config($held), '', 'a slow hook loads');
maybe_arm_sync_hooks({ args => ['personal:INBOX'] }, 0);
maybe_arm_sync_hooks({ args => ['personal:Archive'] }, 0);
is(hook_running_for_test(), 1, 'a second success does not start a second copy');
is(mbsync_running(), 0, 'the running hook still uses no mbsync slot');
open my $go_fh, '>', $go or die "go: $!";
close $go_fh;
wait_hooks();
is(slurp($slow), 'zz', 'the waiting success runs once after the first exits');

clear_hooks_for_test();
set_foreground_for_test(0);
done_testing;

sub write_conf {
    my ($body) = @_;
    my ($out, $file) = tempfile('imapidle-hook-XXXX', SUFFIX => '.conf', TMPDIR => 1);
    print $out $body;
    close $out;
    return $file;
}

sub capture {
    my ($code) = @_;
    my ($tfh, $file) = tempfile('imapidle-hook-cap-XXXX', UNLINK => 1, TMPDIR => 1);
    close $tfh;
    set_foreground_for_test(1);
    open my $old, '>&', \*STDERR or die "dup stderr: $!";
    open STDERR, '>', $file or die "redirect stderr: $!";
    my $err;
    eval { $code->(); 1 } or $err = $@;
    open STDERR, '>&', $old or die "restore stderr: $!";
    close $old;
    set_foreground_for_test(0);
    die $err if $err;
    open my $in, '<', $file or die "read stderr: $!";
    local $/;
    my $buf = <$in> // '';
    close $in;
    return $buf;
}

sub slurp {
    my ($file) = @_;
    return '' unless -f $file;
    open my $in, '<', $file or return '';
    local $/;
    my $buf = <$in> // '';
    close $in;
    return $buf;
}

sub wait_hooks {
    my $deadline = time() + 5;
    while (time() < $deadline) {
        reap_children();
        return if hook_running_for_test() == 0;
        sleep(0.05);
    }
    reap_children();
    diag('hook still running');
}
