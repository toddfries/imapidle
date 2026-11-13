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
use File::Temp qw(tempdir tempfile);
use Test::More;

require './imapidle';

my $dir  = tempdir('imapidle-secret-XXXX', CLEANUP => 1, TMPDIR => 1);
my $flag = "$dir/ready";
my $path = write_conf(<<"EOF");
[acct]
type = idle
server = imap.example.com
user = a\@example.com
pass_cmd = if [ -f $flag ]; then printf '%s\\n' tok; else exit 1; fi; : NOT-IN-THE-LOG
mbsync_channel = ch
folder0 = INBOX
EOF

set_foreground_for_test(0);
is(load_config($path), '', 'config loads');
set_foreground_for_test(1);

my $t0 = time();
my $first = capture(sub { account_pass('acct') });
like($first, qr/acct    : pass_cmd failed/, 'the first failure is logged');
unlike($first, qr/retry in/, 'a pass_cmd failure does not log a retry');
unlike($first, qr/NOT-IN-THE-LOG/, 'the command text is not logged');
my $due = account_next_try('acct');
ok($due >= $t0 + secret_floor() && $due < time() + secret_floor() + 2,
    'the first wait is one minute');
is(secret_wait_for_test('acct'), secret_floor() * 2, 'the next wait doubles');

set_foreground_for_test(0);
is(reload_config_now($path), '', 'reload accepts the same command');
is(secret_wait_for_test('acct'), secret_floor() * 2, 'reload keeps the doubled wait');
ok(secret_said_for_test('acct') >= $t0, 'reload keeps when the failure was said');
set_foreground_for_test(1);

my $t1 = time();
my $second = capture(sub { account_pass('acct') });
is($second, '', 'a retry the same day is silent');
my $due2 = account_next_try('acct');
ok($due2 >= $t1 + secret_floor() * 2 && $due2 < time() + secret_floor() * 2 + 2,
    'the second wait is two minutes');

secret_said_for_test('acct', time() - secret_quiet() + 30);
my $inside = capture(sub { account_pass('acct') });
is($inside, '', 'a failure just inside the day stays quiet');

secret_said_for_test('acct', time() - secret_quiet());
my $day = capture(sub { account_pass('acct') });
like($day, qr/acct    : pass_cmd failed/, 'a failure a day later is logged');
unlike($day, qr/retry in/, 'the daily line has no retry');
unlike($day, qr/NOT-IN-THE-LOG/, 'the command stays out of the daily line');

account_pass('acct') for 1 .. 3;
ok(!loaded_account('acct')->{disabled}, 'repeated pass_cmd failures stay enabled');
is(loaded_account('acct')->{fails}, 0, 'those failures are not the five-strike count');

my $capped = 0;
for (1 .. 12) {
    my $t = time();
    account_pass('acct');
    my $next = account_next_try('acct');
    $capped = 1 if $next >= $t + secret_ceiling() && $next < time() + secret_ceiling() + 2;
}
ok($capped, 'the wait reaches six hours');
is(secret_wait_for_test('acct'), secret_ceiling(), 'the stored wait stays at six hours');

open my $fh, '>', $flag or die "flag: $!";
close $fh;
my $got;
my $back = capture(sub { $got = account_pass('acct') });
is($got, 'tok', 'the helper returns the secret');
like($back, qr/acct    : pass_cmd recovered/, 'recovery is logged once');
unlike($back, qr/pass_cmd failed/, 'recovery is not another failure');
is(secret_wait_for_test('acct'), 0, 'recovery clears the wait');
is(secret_said_for_test('acct'), 0, 'recovery clears the announcement');

my $again;
my $healthy = capture(sub { $again = account_pass('acct') });
is($again, 'tok', 'a second success still returns the secret');
is($healthy, '', 'a healthy helper does not log recovery again');

unlink $flag;
my $t2 = time();
my $fresh = capture(sub { account_pass('acct') });
like($fresh, qr/acct    : pass_cmd failed/, 'a new failure after recovery is logged');
my $due3 = account_next_try('acct');
ok($due3 >= $t2 + secret_floor() && $due3 < time() + secret_floor() + 2,
    'the wait starts again at one minute');

set_foreground_for_test(0);
done_testing;

sub write_conf {
    my ($body) = @_;
    my ($out, $file) = tempfile('imapidle-secret-XXXX', SUFFIX => '.conf', TMPDIR => 1);
    print $out $body;
    close $out;
    return $file;
}

sub capture {
    my ($code) = @_;
    my ($tfh, $file) = tempfile('imapidle-cap-XXXX', UNLINK => 1, TMPDIR => 1);
    close $tfh;
    open my $old, '>&', \*STDERR or die "dup stderr: $!";
    open STDERR, '>', $file or die "redirect stderr: $!";
    my $err;
    eval { $code->(); 1 } or $err = $@;
    open STDERR, '>&', $old or die "restore stderr: $!";
    close $old;
    open my $in, '<', $file or die "read stderr: $!";
    local $/;
    my $buf = <$in> // '';
    close $in;
    die $err if $err;
    return $buf;
}
