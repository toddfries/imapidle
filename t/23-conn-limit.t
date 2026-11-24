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
use Time::HiRes qw(time);
use Test::More;

require './imapidle';

my $LIMIT = 'IMAP login: 1 NO [UNAVAILABLE] Maximum number of connections '
    . 'from user+IP exceeded (mail_max_userip_connections=5) '
    . 'at ./imapidle line 2849';

package ImapidleLimitFake;
sub new { return bless { tag => 'T1' }, $_[0]; }
sub IsConnected { 1 }
sub IsAuthenticated { 1 }
sub select { 1 }
sub idle { 'T1' }
sub LastError { '' }
sub Results { return; }
sub logout { }
package main;

my $dir = tempdir('imapidle-limit-XXXX', CLEANUP => 1, TMPDIR => 1);
set_state_dir_for_test($dir);
set_runtime_dir_for_test($dir);
set_interval_spread_for_test(sub { 0 });
set_foreground_for_test(1);
clear_conns_for_test();
clear_conn_limit_for_test();
reset_schedule_for_test();

my ($fh, $path) = tempfile('imapidle-XXXX', SUFFIX => '.conf', TMPDIR => 1);
print $fh <<'EOF';
[acct]
type = account
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = ch

[acct-watch]
type = idle
channel = acct
folder0 = INBOX
folder1 = Junk
folder2 = More

[acct2]
type = account
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = ch2

[acct2-watch]
type = idle
channel = acct2
folder0 = INBOX

[other]
type = account
server = imap.example.com
user = b@example.com
pass = secret
mbsync_channel = ch3

[other-watch]
type = idle
channel = other
folder0 = INBOX
folder1 = Junk

EOF
close $fh;

sub stderr_of {
    my ($code) = @_;
    my ($out, $file) = tempfile('imapidle-err-XXXX', TMPDIR => 1);
    close $out;
    open my $old, '>&', STDERR or die "dup stderr: $!";
    open STDERR, '>', $file or die "redirect stderr: $!";
    my $ok = eval { $code->(); 1 };
    my $err = $@;
    open STDERR, '>&', $old or die "restore stderr: $!";
    open my $in, '<', $file or die "read stderr: $!";
    local $/;
    my $buf = <$in> // '';
    close $in;
    unlink $file;
    die $err unless $ok;
    return $buf;
}

my $calls = 0;
my $mode = 'limit';
my $nested_ok = 0;
my @kept;

set_login_hook_for_test(sub {
    $calls++;
    die "nested login\n" if $mode eq 'ok' && $calls > 1;
    if ($mode eq 'auth') {
        die "1 NO authentication failed\n";
    }
    if ($mode eq 'down') {
        die "connection timed out\n";
    }
    if ($mode eq 'simultaneous') {
        die "Too many simultaneous connections\n";
    }
    if ($mode eq 'ok') {
        my $seen = $calls;
        my $again = connect_account('acct');
        my $other = connect_account('acct2');
        $nested_ok = ($calls == $seen && $again && $other) ? 1 : 0;
        pipe(my $r, my $w) or die "pipe: $!\n";
        push @kept, $r, $w;
        return ($r, ImapidleLimitFake->new);
    }
    die "$LIMIT\n";
});

ok(conn_limit_error($LIMIT), 'the syslog refusal is a connection limit');
ok(conn_limit_error('IMAP login: Maximum number of connections exceeded'),
    'a maximum-connections refusal matches');
ok(conn_limit_error('too many simultaneous connections'),
    'a simultaneous-connection refusal matches');
ok(conn_limit_error('Too many connections'),
    'a too-many-connections refusal matches');
ok(!conn_limit_error('1 NO authentication failed'),
    'an authentication failure is not a connection limit');
ok(!conn_limit_error(''), 'an empty error is not a connection limit');

is(load_config($path), '', 'config loads');

$mode = 'auth';
$calls = 0;
my $auth = stderr_of(sub {
    is(connect_account('acct'), 0, 'an authentication failure is a failure');
});
is($calls, 1, 'an authentication failure logs in once');
like($auth, qr/authentication failed/, 'the authentication failure is logged');
like($auth, qr/retry in 5s/, 'an authentication failure is retried');
ok(!conn_limit_row_for_test('acct'), 'an authentication failure sets no cap');
is(loaded_account('acct')->{fails}, 1, 'an authentication failure counts');
ok(account_next_try('acct') > time(), 'an authentication failure waits');
ok(!loaded_account('acct')->{disabled}, 'one authentication failure does not disable');
is(loaded_account('acct')->{auth_fails}, 1, 'the first authentication failure starts the streak');

$calls = 0;
my $second = stderr_of(sub {
    is(connect_account('acct'), 0, 'the second authentication failure still fails');
});
like($second, qr/retry in \d+s/, 'the second authentication failure uses the connect backoff');
unlike($second, qr/retry in 604800s/, 'the second authentication failure is not yet a week');
is(loaded_account('acct')->{auth_fails}, 2, 'two authentication failures are still short');
is(loaded_account('acct')->{fails}, 2, 'the short authentication failures count');

$calls = 0;
my $third = stderr_of(sub {
    is(connect_account('acct'), 0, 'the third authentication failure still fails');
});
like($third, qr/auth failed, retry in 604800s at \d{8} \d{2}:\d{2}:\d{2}\.\d{6}/,
    'the third authentication failure waits one week');
unlike($third, qr/disabled after/, 'three authentication failures do not pause the account');
is(loaded_account('acct')->{auth_fails}, 3, 'the streak is three');
is(loaded_account('acct')->{fails}, 2, 'the week does not add another failure');
is(loaded_account('acct')->{backoff}, 604800, 'the backoff is one week');
ok(!loaded_account('acct')->{disabled}, 'the account stays enabled during the week');
my $week_left = int(account_next_try('acct') - time());
ok($week_left == 604800 || $week_left == 604799, 'the next login is one week out')
    or diag($week_left);

$calls = 0;
my $fourth = stderr_of(sub {
    is(connect_account('acct'), 0, 'a later authentication failure still fails');
});
like($fourth, qr/retry in 604800s/, 'a later authentication failure stays on the week');
is(loaded_account('acct')->{fails}, 2, 'later authentication failures still do not count');

is(ctl_reply('account.acct.auth_fails'), "account.acct.auth_fails=4\n",
    'the control socket shows the streak');
is(ctl_reply('account.acct.next_try=0'), "account.acct.next_try=0\n",
    'the week can be scheduled for the next loop');
is(account_next_try('acct'), 0, 'the held login is due now');
is(loaded_account('acct')->{auth_fails}, 0, 'scheduling clears the streak');
is(loaded_account('acct')->{backoff}, 5, 'scheduling restores the short backoff');

note_success('acct');
set_monitored_for_test('acct', 0);
$calls = 0;
stderr_of(sub { connect_account('acct') for 1 .. 2 });
is(loaded_account('acct')->{auth_fails}, 2, 'a new streak starts after it is scheduled');
$mode = 'down';
my $down = stderr_of(sub {
    is(connect_account('acct'), 0, 'a timeout is a different failure');
});
like($down, qr/retry in \d+s/, 'a timeout uses the connect backoff');
unlike($down, qr/retry in 604800s/, 'a timeout does not keep the week');
is(loaded_account('acct')->{auth_fails}, 0, 'a timeout clears the authentication streak');
$mode = 'auth';

note_success('acct');
set_monitored_for_test('acct', 0);
set_next_try_for_test('acct', 0);

$mode = 'limit';
$calls = 0;
my $t0 = time();
my $none = stderr_of(sub {
    is(connect_account('acct'), 1, 'a limit on the first login returns');
});
my $row0 = conn_limit_row_for_test('acct');
is($calls, 1, 'the first refusal does not try the next folder');
ok($row0, 'the first refusal records a cap');
is($row0->{cap}, 0, 'no open session means a cap of zero');
is($row0->{server_max}, 5, 'the server number is stored');
ok($row0->{probe} >= $t0 + 604800 && $row0->{probe} < $t0 + 604810,
    'the first probe is one week out');
is(loaded_account('acct')->{fails}, 0, 'a limit does not count as a failure');
is(account_next_try('acct') + 0, 0, 'a limit does not set a retry time');
ok(!loaded_account('acct')->{disabled}, 'a limit does not disable the account');
like($none, qr/connection limit 0, server 5, probe in \d+s/,
    'the limit log names our count, the server number, and the probe');
unlike($none, qr/at \.\/imapidle line/, 'the limit log has no Perl location');
unlike($none, qr/UNAVAILABLE/, 'the limit log is not the raw server text');
unlike($none, qr/mail_max_userip_connections/, 'the raw limit phrase is not logged');

$calls = 0;
my $quiet = stderr_of(sub {
    is(connect_account('acct'), 1, 'a later login is not attempted');
});
is($calls, 0, 'a capped account does not log in again');
unlike($quiet, qr/connection limit/, 'a quiet skip is not logged again');
is(loaded_account('acct')->{fails}, 0, 'quiet skips do not count failures');

my $limit_file = "$dir/conn-limit";
ok(-f $limit_file, 'the cap is written to conn-limit');
is((stat($limit_file))[2] & 0777, 0600, 'conn-limit is mode 0600');
open my $in, '<', $limit_file or die "read conn-limit: $!";
my $body = do { local $/; <$in> };
close $in;
like($body, qr/\A# server\tport\tuser\tcap\tprobe\tserver_max\n/,
    'conn-limit starts with its header');
like($body, qr/^imap\.example\.com\t993\ta\@example\.com\t0\t\d+(?:\.\d+)?\t5$/m,
    'conn-limit stores server, port, user, cap, probe, and server max');

clear_conn_limit_for_test();
ok(!conn_limit_row_for_test('acct'), 'the in-memory cap can be cleared');
_conn_limit_load();
is(conn_limit_row_for_test('acct')->{cap}, 0, 'the cap loads again from the file');
is(conn_limit_row_for_test('acct')->{server_max}, 5, 'the server number loads again');

open my $bad, '>>', $limit_file or die "append conn-limit: $!";
print $bad "imap.example.com\t993\tbad\tuser\t9\t9\t9\n";
close $bad;
clear_conn_limit_for_test();
_conn_limit_load();
is(conn_limit_row_for_test('acct')->{cap}, 0, 'a good row still loads');
my @only = grep { /^limit:/ } info_lines(time());
is(scalar @only, 1, 'a user field that contains a tab is rejected');

my $now = time();
my $nodes = ctl_nodes($now);
is($nodes->{'limit.imap..example..com.993.a@example..com.cap'}, 0,
    'the control socket shows the cap');
is($nodes->{'limit.imap..example..com.993.a@example..com.server_max'}, 5,
    'the control socket shows the server number');
is($nodes->{'limit.imap..example..com.993.a@example..com.probe'},
    int(conn_limit_row_for_test('acct')->{probe}),
    'the control socket shows when the probe is due');
my $dump = join("\n", map { "$_=$nodes->{$_}" } sort keys %$nodes);
unlike($dump, qr/secret/, 'the limit nodes do not include the password');
unlike($dump, qr/pass_cmd/, 'the limit nodes do not include a password command');
ok(conn_limit_blocked(loaded_account('acct'), time()),
    'cap 0 with a future probe blocks');
my $lim = 'limit.imap..example..com.993.a@example..com';
is(ctl_reply("$lim.cap=3"), "$lim.cap=3\n", 'the cap can be set');
is(conn_limit_row_for_test('acct')->{cap}, 3, 'the running cap follows the write');
ok(!conn_limit_blocked(loaded_account('acct'), time()),
    'a cap above the open count allows a login');
is(ctl_reply("$lim.cap=0"), "$lim.cap=0\n", 'the cap can be cleared');
ok(conn_limit_blocked(loaded_account('acct'), time()),
    'a zero cap waits for its probe');
is(ctl_reply("$lim.probe=0"), "$lim.probe=0\n", 'the probe time can be set');
is(conn_limit_row_for_test('acct')->{probe}, 0, 'the next extra try is due');
ok(!conn_limit_blocked(loaded_account('acct'), time()),
    'a due probe allows one extra login');
is(conn_limit_row_for_test('acct')->{server_max}, 5,
    'setting the cap leaves the server number');
open my $wrote, '<', $limit_file or die "reread conn-limit: $!";
my $saved = do { local $/; <$wrote> };
close $wrote;
like($saved, qr/^imap\.example\.com\t993\ta\@example\.com\t0\t0\t5$/m,
    'a control write is stored in conn-limit');
is(ctl_reply("$lim.cap=no"), "error bad value\n", 'the cap rejects a word');
is(ctl_reply("$lim.probe=1.5"), "error bad value\n", 'the probe rejects a fraction');
is(conn_limit_row_for_test('acct')->{cap}, 0, 'a rejected cap write stays');
is(conn_limit_row_for_test('acct')->{probe}, 0, 'a rejected probe write stays');
is(ctl_reply('limit.no..such.993.nobody.cap=1'),
    "error unknown oid limit.no..such.993.nobody.cap\n",
    'an unknown limit cannot be created');
is(ctl_reply("$lim.server_max=9"), "error read-only\n",
    'the server number is not applied');
is(conn_limit_row_for_test('acct')->{server_max}, 5, 'the server number stays');
my $restored = int(time() + 604800);
is(ctl_reply("$lim.probe=$restored"), "$lim.probe=$restored\n",
    'the probe can be set ahead again');
ok(conn_limit_blocked(loaded_account('acct'), time()),
    'the restored probe blocks again');

my @info = info_lines($now);
my ($line) = grep { /^limit:/ } @info;
like($line, qr/^limit: imap\.example\.com:993 a\@example\.com cap 0 probe \d+s server 5$/,
    'SIGINFO shows host, port, user, cap, probe, and server number');

set_foreground_for_test(0);
is(reload_config_now($path), '', 'reload accepts the same file');
is(conn_limit_row_for_test('acct')->{cap}, 0, 'a reload keeps the learned cap');
set_foreground_for_test(1);
set_monitored_for_test('acct', 0);
set_next_try_for_test('acct', 0);

set_next_try_for_test('acct2', time() + 100000);
set_next_try_for_test('other', time() + 100000);
$calls = 0;
stderr_of(sub { housekeeping(); });
is($calls, 0, 'housekeeping does not log in while the cap blocks');
is(loaded_account('acct')->{fails}, 0, 'housekeeping does not retry a limit');
ok(!loaded_account('acct')->{disabled}, 'housekeeping does not disable on a limit');
set_next_try_for_test('acct2', 0);
set_next_try_for_test('other', 0);

clear_conn_limit_for_test();
unlink $limit_file;
clear_conns_for_test();

my $inbox = plant_idle_for_test('acct', 'INBOX', 0, 'ch');
ok(set_conn_primary_for_test($inbox), 'the planted session is primary');
$calls = 0;
my $t1 = time();
my $found = stderr_of(sub {
    is(connect_account('acct'), 1, 'a refusal with a session up returns');
});
my $row = conn_limit_row_for_test('acct');
is($calls, 1, 'one refusal stops the rest of the folders');
is($row->{cap}, 1, 'the cap is the number of sessions already open');
is($row->{server_max}, 5, 'the stated maximum does not replace the cap');
ok($row->{probe} >= $t1 + 604800 && $row->{probe} < $t1 + 604810,
    'a refusal with sessions up probes in one week');
ok(conn_exists_for_test('acct:INBOX'), 'the session already open stays up');
ok(!conn_exists_for_test('acct:Junk'), 'the refused folder is not kept');
ok(!conn_exists_for_test('acct:More'), 'a later folder is not opened');
is(loaded_account('acct')->{fails}, 0, 'the partial refusal does not count');
is(account_next_try('acct') + 0, 0, 'the partial refusal does not back off');
ok(!loaded_account('acct')->{disabled}, 'the partial refusal does not disable');
like($found, qr/connection limit 1, server 5, probe in \d+s/,
    'the partial refusal logs the open count');
unlike($found, qr/at \.\/imapidle line/, 'the partial refusal has no Perl location');

$calls = 0;
is(connect_account('acct2'), 1, 'the same user shares the cap');
is($calls, 0, 'the same user does not log in while the cap is full');

$calls = 0;
clear_conns_for_test();
my $hold = conn_limit_begin('acct', loaded_account('acct'));
is(connect_account('acct2'), 1, 'a hold returns without a login');
is($calls, 0, 'a same-user account is blocked while a login is in flight');
conn_limit_success($hold);
$inbox = plant_idle_for_test('acct', 'INBOX', 0, 'ch');
ok(set_conn_primary_for_test($inbox), 'the primary session is planted again');

my $stamp = time() - 5;
ok(set_conn_limit_probe_for_test('acct', $stamp), 'the probe is due');
$mode = 'auth';
$calls = 0;
my $mid = stderr_of(sub {
    is(connect_account('acct'), 0, 'a probe that is not a limit still fails');
});
like($mid, qr/authentication failed/, 'the probe authentication failure is logged');
like($mid, qr/retry in /, 'the probe authentication failure is retried');
is(conn_limit_row_for_test('acct')->{cap}, 1, 'a non-limit probe keeps the cap');
is(conn_limit_row_for_test('acct')->{probe}, $stamp, 'a non-limit probe does not spend the week');
ok(!conn_limit_blocked(loaded_account('acct')), 'the probe stays due after a non-limit failure');
ok(loaded_account('acct')->{fails} >= 1, 'a non-limit probe counts as a failure');
note_success('acct');
set_monitored_for_test('acct', 0);
set_next_try_for_test('acct', 0);

$mode = 'limit';
$calls = 0;
ok(set_conn_limit_probe_for_test('acct', time() - 1), 'the limit probe is due');
my $t2 = time();
my $denied = stderr_of(sub {
    is(connect_account('acct'), 1, 'a refused probe returns');
});
is($calls, 1, 'a refused probe is one login');
is(conn_limit_row_for_test('acct')->{cap}, 1, 'a refused probe keeps the cap');
ok(conn_limit_row_for_test('acct')->{probe} >= $t2 + 604800, 'a refused probe waits another week');
ok(conn_exists_for_test('acct:INBOX'), 'a refused probe leaves the open session');
is(loaded_account('acct')->{fails}, 0, 'a refused probe does not count');
is(account_next_try('acct') + 0, 0, 'a refused probe does not back off');
like($denied, qr/connection limit 1, server 5/, 'a refused probe logs the same cap');
unlike($denied, qr/at \.\/imapidle line/, 'a refused probe has no Perl location');

$mode = 'ok';
$calls = 0;
$nested_ok = 0;
ok(set_conn_limit_probe_for_test('acct', time() - 1), 'the successful probe is due');
my $t3 = time();
my $raised = stderr_of(sub {
    is(connect_account('acct'), 1, 'a successful probe returns');
});
is($calls, 1, 'a successful probe is one login');
is($nested_ok, 1, 'a second login is blocked while that probe is in flight');
is(conn_limit_row_for_test('acct')->{cap}, 2, 'a successful probe raises the cap by one');
ok(conn_limit_row_for_test('acct')->{probe} >= $t3 + 604800,
    'a successful probe waits another week');
ok(conn_exists_for_test('acct:INBOX'), 'the older session stays up');
ok(conn_exists_for_test('acct:Junk'), 'the probe session stays up');
ok(!conn_exists_for_test('acct:More'), 'the folder after the probe stays closed');
is(loaded_account('acct')->{fails}, 0, 'a successful probe does not count a failure');
unlike($raised, qr/at \.\/imapidle line/, 'a successful probe has no Perl location');

$calls = 0;
$mode = 'simultaneous';
my $plain = stderr_of(sub {
    is(connect_account('other'), 1, 'a different user is its own cap');
});
is($calls, 1, 'a different user is allowed to log in');
is(conn_limit_row_for_test('other')->{cap}, 0, 'the other user learns its own cap');
ok(!defined conn_limit_row_for_test('other')->{server_max},
    'a refusal without a number stores no server max');
is(conn_limit_row_for_test('acct')->{cap}, 2, 'the other user does not change this cap');
like($plain, qr/connection limit 0, probe in \d+s/,
    'a refusal without a server number omits it');
unlike($plain, qr/connection limit 0, server/,
    'the omitted server number is not a blank field');

for my $name (account_names()) {
    set_next_try_for_test($name, 0);
}
my $week = loop_timeout();
is($week, 30, 'a probe a week away leaves the 30s sleep');
ok(set_conn_limit_probe_for_test('acct', time() + 10), 'the probe is ten seconds out');
ok(set_conn_limit_probe_for_test('acct2', time() + 10), 'the shared user has the same probe');
my $soon = loop_timeout();
ok($soon >= 8 && $soon <= 10, 'a probe inside 30s wakes the loop') or diag($soon);
set_next_try_for_test('acct', time() + 20);
set_next_try_for_test('acct2', time() + 20);
my $later = loop_timeout();
ok($later >= 18 && $later <= 20, 'a backoff longer than the probe waits for the backoff')
    or diag($later);

set_monitored_for_test('other', 0);
set_next_try_for_test('other', 0);
stderr_of(sub { mark_retry('other') for 1 .. start_give_up() });
ok(loaded_account('other')->{disabled}, 'the other account is paused');
is(ctl_reply('account.other.next_try=0'), "account.other.next_try=0\n",
    'a paused account can be scheduled now');
ok(!loaded_account('other')->{disabled}, 'scheduling now ends the pause');
is(account_next_try('other'), 0, 'the paused account is due');

{
    package AuthList;
    sub new { bless { caps => $_[1] }, $_[0] }
    sub IsConnected { 1 }
    sub capability { return @{ $_[0]->{caps} } }
}
set_verbose_for_test(1);
reset_auth_seen_for_test();
my $mechs = stderr_of(sub {
    _note_server_auth('mech.example', 993,
        AuthList->new([qw(IMAP4rev1 AUTH=PLAIN AUTH=XOAUTH2)]));
});
like($mechs, qr/\[tls\] +: \d+\.auth mech\.example:993 PLAIN XOAUTH2/,
    'verbose mode logs the server authentication mechanisms once');
my $repeat = stderr_of(sub {
    _note_server_auth('mech.example', 993,
        AuthList->new([qw(AUTH=LOGIN)]));
});
unlike($repeat, qr/\.auth /, 'the mechanisms are not logged again');
set_verbose_for_test(0);
reset_auth_seen_for_test();
my $silent = stderr_of(sub {
    _note_server_auth('quiet.example', 993, AuthList->new([qw(AUTH=PLAIN)]));
});
unlike($silent, qr/\.auth /, 'without verbose the mechanisms stay quiet');

clear_conn_limit_for_test();
my $none_open = stderr_of(sub {
    is(note_imsg_conn_limit('acct', $LIMIT, 0), 0,
        'no armed sibling records no cap');
});
ok(!conn_limit_row_for_test('acct'), 'a zero open count writes no row');
unlike($none_open, qr/connection limit/, 'a zero open count is not logged');

my $plain_cap = stderr_of(sub {
    ok(note_imsg_conn_limit('acct', 'Too many connections', 5) > time(),
        'five armed siblings record a week probe');
});
is(imsg_conn_limit_cap('acct'), 5, 'without a server number the cap is the open count');
like($plain_cap, qr/connection limit 5, probe in \d+s/,
    'the imsg cap is logged');
unlike($plain_cap, qr/connection limit 5, server/,
    'a missing server number is left off the imsg line');

my $lowered = stderr_of(sub {
    ok(note_imsg_conn_limit('acct', $LIMIT, 5) > time(),
        'a numbered refusal schedules the probe again');
});
is(imsg_conn_limit_cap('acct'), 4,
    'the cap stays one below the server number so mbsync can log in');
is(conn_limit_row_for_test('acct')->{server_max}, 5,
    'the server number is stored beside the imsg cap');
like($lowered, qr/connection limit 4, server 5, probe in \d+s/,
    'the lowered cap is logged with the server number');

my $kept = stderr_of(sub {
    note_imsg_conn_limit('acct', $LIMIT, 5);
});
is(imsg_conn_limit_cap('acct'), 4, 'a later refusal does not raise the cap');
like($kept, qr/connection limit 4, server 5/,
    'the same cap is logged again');

clear_conn_limit_for_test();
stderr_of(sub { note_imsg_conn_limit('acct', 'Too many connections', 2) });
stderr_of(sub { note_imsg_conn_limit('acct', $LIMIT, 5) });
is(imsg_conn_limit_cap('acct'), 2,
    'a smaller learned cap is not replaced by the server number');

clear_conn_limit_for_test();
my $held = stderr_of(sub {
    ok(note_imsg_conn_limit('acct', $LIMIT, 4) > time(),
        'four armed sessions learn a cap');
});
is(imsg_conn_limit_cap('acct'), 4, 'four open sessions stay at 4 under a server max of 5');
my $held_probe = conn_limit_row_for_test('acct')->{probe};
my $soon_at = time();
my $soon_log = stderr_of(sub {
    my $when = note_imsg_conn_limit('acct', $LIMIT, 1, 3);
    ok($when > $soon_at + 8 && $when < $soon_at + 12,
        'a refusal while others are still logging in retries in about ten seconds');
});
is(imsg_conn_limit_cap('acct'), 4,
    'that refusal does not shrink the cap');
is(conn_limit_row_for_test('acct')->{probe}, $held_probe,
    'the week probe is left alone while sessions are still opening');
unlike($soon_log, qr/connection limit/,
    'the short retry is not logged as a new cap');
my $ceiling = note_imsg_conn_limit('acct', $LIMIT, 4, 2);
ok($ceiling > time() + 1000,
    'at the ceiling a refusal still waits out the week');
is(imsg_conn_limit_cap('acct'), 4, 'the ceiling refusal keeps the cap');

reset_schedule_for_test();
my $qnow = time();
my $requeued = stderr_of(sub {
    requeue_after_conn_limit({
        args => [ 'ch:INBOX', 'ch:Junk', 'nocolon' ],
    });
});
my $qdl = schedule_deadline('ch');
ok(defined $qdl && $qdl >= $qnow + 9 && $qdl <= $qnow + 12,
    'a refused sync is tried again in about ten seconds') or diag($qdl);
like($requeued, qr/mbsync hit the connection limit, retry in 10s/,
    'the retry is logged once');
my $quiet_q = stderr_of(sub {
    requeue_after_conn_limit({ args => ['nocolon'] });
});
unlike($quiet_q, qr/connection limit/, 'an unrelated argument is not a retry');

clear_conn_limit_for_test();
my $probe = 0;
my $shed_log = stderr_of(sub {
    $probe = note_imsg_conn_limit('acct', $LIMIT, 5);
});
ok($probe > time(), 'the shed probe is in the future');
like($shed_log, qr/connection limit 4, server 5/,
    'five open sessions and a server max of 5 store 4');

my $built = system('make', '-C', 'ext/imsg');
is($built, 0, 'the imsg wrapper builds') or BAIL_OUT('imsg build failed');
unshift @INC, 'lib', 'blib';
require IMAPIDLE::Split;

{
    package ShedIb;
    sub new { return bless { n => 0, type => 0 }, $_[0]; }
    sub send {
        my ($self, $type) = @_;
        $self->{n}++;
        $self->{type} = $type;
        return 1;
    }
}

sub shed_job {
    my ($id, $account, $folder, $kind, $debounce) = @_;
    return {
        id         => $id,
        account    => $account,
        folder     => $folder,
        channel    => (loaded_account($account) || {})->{mbsync_channel} // $account,
        kind       => $kind,
        debounce   => $debounce,
        armed      => 1,
        ib         => ShedIb->new,
        restart_at => 0,
    };
}

my $failed = shed_job('fail', 'acct', 'More', 'idle', 420);
$failed->{armed} = 0;
my %jobs = (
    fail => $failed,
    a    => shed_job('a', 'acct', 'A', 'idle', 7),
    b    => shed_job('b', 'acct', 'B', 'idle', 20),
    c    => shed_job('c', 'acct', 'C', 'idle', 100),
    d    => shed_job('d', 'acct', 'D', 'idle', 420),
    e    => shed_job('e', 'acct2', 'INBOX', 'account', 0),
    f    => shed_job('f', 'other', 'INBOX', 'idle', 999),
);
my $paused = stderr_of(sub {
    IMAPIDLE::Split::_shed_login(\%jobs, $failed, $probe);
});
is($jobs{d}{ib}{n}, 1, 'the lowest priority folder is told to exit');
is($jobs{d}{ib}{type}, IMAPIDLE::IMSG_SHUTDOWN(), 'that exit is a shutdown');
is($jobs{d}{restart_at}, $probe, 'the paused folder waits for the probe');
ok($jobs{d}{limit_hold}, 'the paused folder is not asked twice');
is($jobs{a}{ib}{n}, 0, 'a short gap stays up');
is($jobs{b}{ib}{n}, 0, 'the next short gap stays up');
is($jobs{c}{ib}{n}, 0, 'a middle gap stays up on the first pass');
is($jobs{e}{ib}{n}, 0, 'a pulse speaker stays while an idle folder can leave');
is($jobs{f}{ib}{n}, 0, 'a different user is not paused');
like($paused, qr/acct +: idle D paused for the connection limit/,
    'the paused folder is logged');
unlike($paused, qr/other +: idle/, 'the other user is not in that log');

$jobs{h} = shed_job('h', 'acct', 'H', 'idle', 50);
stderr_of(sub {
    IMAPIDLE::Split::_shed_login(\%jobs, $failed, $probe);
});
is($jobs{d}{ib}{n}, 1, 'the folder already leaving is not shut down again');
is($jobs{c}{ib}{n}, 1, 'the next lowest priority leaves when another arms');
is($jobs{h}{ib}{n}, 0, 'a hotter folder than that one stays');
is($jobs{e}{ib}{n}, 0, 'the pulse speaker still stays');
is($jobs{c}{restart_at}, $probe, 'the second pause waits for the same probe');

done_testing;
