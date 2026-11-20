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
type = account
server = imap.example.com
user = a\@example.com
pass_cmd = if [ -f $flag ]; then printf '%s\\n' tok; else exit 1; fi; : NOT-IN-THE-LOG
mbsync_channel = ch

[acct-watch]
type = idle
channel = acct
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

my $bad = write_conf(<<'EOF');
[oauth]
type = account
server = imap.example.com
user = a@example.com
pass_cmd = printf '%s\n' 'ERROR Access token unavailable until authorised with URL https://example.invalid/auth'
mbsync_channel = oauthch

[oauth-watch]
type = idle
channel = oauth
folder0 = INBOX

EOF
set_foreground_for_test(0);
is(load_config($bad), '', 'an error-line command still loads');
set_foreground_for_test(1);
set_login_hook_for_test(sub { die "tcp\n" });

reset_schedule_for_test();
my $held = time();
queue_folder('oauthch', 'INBOX', $held, $held);
my @blocked;
my $held_log = capture(sub { @blocked = due_mbsync_jobs($held) });
is(scalar @blocked, 0, 'a bad token does not start mbsync');
like($held_log, qr/oauth\s+: pass_cmd failed/, 'the bad token is a pass_cmd failure');
unlike($held_log, qr/example\.invalid/, 'the authorisation URL is not logged');
unlike($held_log, qr/\btcp\b/, 'scheduling a bad token does not log in');
my $later = schedule_deadline('oauthch');
ok(defined $later && $later > $held, 'the batch waits out the command');

my $conn_rc;
my $conn_log = capture(sub { $conn_rc = connect_account('oauth') });
is($conn_rc, 0, 'a bad token does not connect');
unlike($conn_log, qr/\btcp\b/, 'login is not attempted');
unlike($conn_log, qr/example\.invalid/, 'connect does not log the authorisation URL');
unlike($conn_log, qr/imap\.example\.com/, 'connect does not name the server');

reset_schedule_for_test();
reset_track_for_test();
my $sweep = time();
set_track_due_for_test('oauthch', 'INBOX', $sweep);
my $fired = 0;
set_trigger_hook_for_test(sub { $fired++; return 1 });
my $sweep_log = capture(sub { pump_tracked($sweep) });
is($fired, 0, 'a cold sweep does not start mbsync');
unlike($sweep_log, qr/\btcp\b/, 'a cold sweep does not log in');
unlike($sweep_log, qr/example\.invalid/, 'a cold sweep does not log the URL');
my ($swept) = track_rows_for_test();
ok($swept && $swept->{next} > $sweep, 'the sweep waits out the command');
ok(!$swept->{await_sync}, 'the sweep is not waiting on mbsync');
set_trigger_hook_for_test(undef);

my $good = write_conf(<<'EOF');
[oauth]
type = account
server = imap.example.com
user = a@example.com
pass_cmd = printf '%s\n' 'ya29.a0AfH6SM'
mbsync_channel = oauthch

[oauth-watch]
type = idle
channel = oauth
folder0 = INBOX

EOF
set_foreground_for_test(0);
is(load_config($good), '', 'a token command loads');
set_foreground_for_test(1);
reset_schedule_for_test();
my $ready = time();
queue_folder('oauthch', 'INBOX', $ready, $ready);
my @ready_jobs;
my $ready_log = capture(sub { @ready_jobs = due_mbsync_jobs($ready) });
is(scalar @ready_jobs, 1, 'a token lets the batch run');
is($ready_jobs[0]{args}[0], 'oauthch:INBOX', 'the job names the mailbox');
unlike($ready_log, qr/\btcp\b/, 'taking the batch does not log in');
unlike($ready_log, qr/example\.invalid/, 'a token run has no authorisation URL');

my $stored = write_conf(<<'EOF');
[plain]
type = account
server = imap.example.com
user = a@example.com
pass = ERROR Access token unavailable https://example.invalid/auth
mbsync_channel = plainch

[plain-watch]
type = idle
channel = plain
folder0 = INBOX

EOF
set_foreground_for_test(0);
is(load_config($stored), '', 'a stored password still loads');
set_foreground_for_test(1);
reset_schedule_for_test();
my $plain_at = time();
queue_folder('plainch', 'INBOX', $plain_at, $plain_at);
my @plain;
my $plain_log = capture(sub { @plain = due_mbsync_jobs($plain_at) });
is(scalar @plain, 1, 'a stored password is not gated');
is($plain[0]{args}[0], 'plainch:INBOX', 'the stored-password job names the mailbox');
unlike($plain_log, qr/\btcp\b/, 'a stored password does not log in from the scheduler');
unlike($plain_log, qr/example\.invalid/, 'a stored password is not logged');
set_login_hook_for_test(undef);

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
