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
use IO::Socket::UNIX;
use POSIX qw(WNOHANG _exit);
use Socket qw(SOCK_STREAM);
use Test::More;

require './imapidle';

my $dir = tempdir('imapidle-ctl-XXXX', CLEANUP => 1, TMPDIR => 1);
set_runtime_dir_for_test($dir);
set_state_dir_for_test($dir);
set_learned_for_test("$dir/learned");
set_foreground_for_test(0);
clear_conns_for_test();
reset_schedule_for_test();

my ($fh, $conf) = tempfile('imapidle-ctl-XXXX', SUFFIX => '.conf', TMPDIR => 1);
print $fh <<'EOF';
[acct]
type = account
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = ch
hook = echo hi

[acct-watch]
type = idle
channel = acct
folder0 = INBOX.Sent;priority=5

EOF
close $fh;
is(load_config($conf), '', 'config loads');

my $all = ctl_reply('all');
like($all, qr/^version=0\.4$/m, 'version is a node');
like($all, qr/^account\.acct\.server=imap\.example\.com$/m, 'the server is a node');
like($all, qr/^account\.acct\.user=a\@example\.com$/m, 'the user is a node');
like($all, qr/^account\.acct\.hook=1$/m, 'a hook is present without its text');
like($all, qr/^account\.acct\.folder\.INBOX\.\.Sent\.priority=5$/m,
    'a dotted mailbox doubles the dot');
unlike($all, qr/=secret\b/, 'the password is not listed');
unlike($all, qr/secret_wait/, 'the pass wait is not named like a secret');
unlike($all, qr/pass_cmd/, 'a password command is not listed');
unlike($all, qr/echo hi/, 'the hook command is not listed');

is(ctl_reply('account.acct.server'), "account.acct.server=imap.example.com\n",
    'one node is one line');
my $folder = ctl_reply('account.acct.folder.INBOX..Sent');
like($folder, qr/^account\.acct\.folder\.INBOX\.\.Sent\.priority=5$/m, 'a prefix lists the mailbox');
like($folder, qr/^account\.acct\.folder\.INBOX\.\.Sent\.debounce=/m, 'the prefix includes the gap');
like($all, qr/^account\.acct\.hyperdelete=0$/m, 'hyperdelete is off');
like($all, qr/^track\.confirm=604800$/m, 'an empty mailbox confirms in seven days');
is(ctl_reply('track.confirm=120'), "error read-only\n", 'the confirm interval cannot be written');
like($folder, qr/^account\.acct\.folder\.INBOX\.\.Sent\.resync=43200$/m, 'the resync ceiling is a node');
is(ctl_reply('account.acct.folder.INBOX..Sent.resync=120'),
    "account.acct.folder.INBOX..Sent.resync=120\n", 'resync can be set');
is(loaded_account('acct')->{folders}[0]{resync}, 120, 'the running folder keeps the new ceiling');
is(ctl_reply('account.acct.folder.INBOX..Sent.resync=10'), "error bad value\n",
    'resync rejects a value below 60');
is(loaded_account('acct')->{folders}[0]{resync}, 120, 'the rejected ceiling stays');
is(ctl_reply('account.acct.hyperdelete=1'), "account.acct.hyperdelete=1\n",
    'hyperdelete can be set');
is(loaded_account('acct')->{hyperdelete}, 1, 'the running account syncs removals');
is(ctl_reply('account.acct.hyperdelete=0'), "account.acct.hyperdelete=0\n",
    'hyperdelete can be cleared');
is(loaded_account('acct')->{hyperdelete}, 0, 'the running account leaves removals');
like($all, qr/^account\.acct\.next_try=0$/m, 'the next login is a node');
like($all, qr/^account\.acct\.auth_fails=0$/m, 'authentication failures start at zero');
is(ctl_reply('account.acct.next_try=1700000000'),
    "account.acct.next_try=1700000000\n", 'the next login can be scheduled');
is(account_next_try('acct'), 1700000000, 'the running account keeps that time');
is(ctl_reply('account.acct.next_try=0'), "account.acct.next_try=0\n",
    'zero tries on the next loop');
is(account_next_try('acct'), 0, 'the scheduled login was cleared');
is(ctl_reply('account.acct.next_try=soon'), "error bad value\n",
    'a next login must be a whole number');
is(ctl_reply('account.missing.next_try=0'),
    "error unknown oid account.missing.next_try\n",
    'an unknown account has no login time');
is(ctl_reply('account.acct.auth_fails=0'), "error read-only\n",
    'the authentication streak is not a setting');
is(ctl_reply('account.acct.hyperdelete=yes'), "error bad value\n",
    'hyperdelete is 0 or 1');
is(loaded_account('acct')->{hyperdelete}, 0, 'a rejected hyperdelete write stays');
is(ctl_reply('account.missing.hyperdelete=1'), "error unknown oid account.missing.hyperdelete\n",
    'an unknown account has no hyperdelete node');
unlike($folder, qr/^account\.acct\.server=/m, 'the prefix stops at the component');

is(ctl_reply('no.such'), "error unknown oid no.such\n", 'an unknown name is an error');
is(ctl_reply('pause=2'), "error bad value\n", 'pause rejects a value other than 0 or 1');
is(ctl_reply('account.acct.server=other'), "error read-only\n", 'a readout cannot be written');
is(loaded_account('acct')->{server}, 'imap.example.com', 'the rejected write leaves the server');

is(ctl_reply('pause=1'), "pause=1\n", 'pause=1 is remembered');
ok(operations_paused(), 'a ctl pause pauses without a file');
set_next_try_for_test('acct', 0);
my $held = loop_timeout();
cmp_ok($held, '>=', 1, 'a ctl pause does not busy-poll');
cmp_ok($held, '<=', 1, 'a ctl pause sleeps one second') or diag($held);
is(ctl_reply('pause=0'), "pause=0\n", 'pause=0 clears the latch');
ok(!operations_paused(), 'the latch is clear');

open my $pf, '>', "$dir/pause.imapidle" or die "pause file: $!";
close $pf;
is(ctl_reply('pause'), "pause=1\n", 'a pause file still pauses');
is(ctl_reply('pause=0'), "pause=1\n", 'clearing the latch leaves the file');
unlink "$dir/pause.imapidle";
is(ctl_reply('pause'), "pause=0\n", 'removing the file clears the pause');

plant_idle_for_test('acct', 'INBOX.Sent', 420, 'ch');
like(ctl_reply('conn.acct'), qr/^conn\.acct\.INBOX\.\.Sent\.mode=IDLE$/m,
    'a connection is a node');

is(ctl_reply('shutdown=1'), "shutdown=1\n", 'shutdown=1 is accepted');
ok(_shutdown_wanted(), 'shutdown=1 requests the exit');
reset_track_for_test();
ok(!_shutdown_wanted(), 'the test shutdown flag is cleared');

set_ctl_path_for_test("$dir/imapidle.sock");
ctl_listen();
ok(-S "$dir/imapidle.sock", 'the socket exists');
is(((stat "$dir/imapidle.sock")[2] // 0) & 0777, 0600, 'the socket is mode 0600');

my $cli = IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => "$dir/imapidle.sock");
ok($cli, 'a client connects') or diag($!);
print $cli "version\n";
ctl_pump_for_test();
my $got = '';
while (1) {
    my $n = sysread($cli, my $chunk, 256);
    last if !defined $n || $n == 0;
    $got .= $chunk;
}
close $cli;
is($got, "version=0.4\n", 'the socket returns the node');

my $pid = fork();
die "fork: $!" unless defined $pid;
if ($pid == 0) {
    open STDOUT, '>', "$dir/ctl.out" or _exit(1);
    open STDERR, '>', "$dir/ctl.err" or _exit(1);
    exec $^X, 'imapidlectl', '-s', "$dir/imapidle.sock", 'pid'
        or _exit(1);
}
my $status;
my $deadline = time() + 5;
while (time() < $deadline) {
    my $got = waitpid($pid, WNOHANG);
    if ($got == $pid) {
        $status = $?;
        last;
    }
    ctl_pump_for_test();
    select(undef, undef, undef, 0.01);
}
is(defined $status ? $status >> 8 : -1, 0, 'imapidlectl exits 0')
    or diag(do { local $/; open my $e, '<', "$dir/ctl.err"; <$e> // '' });
open my $out, '<', "$dir/ctl.out" or die "ctl.out: $!";
my $text = do { local $/; <$out> };
close $out;
like($text, qr/^pid=\d+\n\z/, 'imapidlectl prints the node');

ctl_close();
ok(!-e "$dir/imapidle.sock", 'shutdown removes the socket');

set_ctl_path_for_test(undef);
{
    local $ENV{HOME} = $dir;
    is(ctl_socket_path(), "$dir/var/run/imapidle.sock", 'the socket lives in ~/var/run');
    ok(!-d "$dir/var", 'the run directory starts absent');
    ctl_listen();
    ok(-d "$dir/var/run", 'a missing run directory is created');
    is(((stat "$dir/var/run")[2] // 0) & 0777, 0700, 'the new run directory is mode 0700');
    ok(-S "$dir/var/run/imapidle.sock", 'the default socket is opened');
    ctl_close();
    ok(!-e "$dir/var/run/imapidle.sock", 'close removes the default socket');
}

mkdir "$dir/ro" or die "mkdir ro: $!";
chmod 0555, "$dir/ro" or die "chmod ro: $!";
set_ctl_path_for_test("$dir/ro/imapidle.sock");
ctl_listen();
ok(!-e "$dir/ro/imapidle.sock", 'an unwritable directory leaves no socket');
chmod 0755, "$dir/ro";

open my $block, '>', "$dir/notdir" or die "notdir: $!";
close $block;
set_ctl_path_for_test("$dir/notdir/imapidle.sock");
ctl_listen();
ok(!-e "$dir/notdir/imapidle.sock", 'a path that is not a directory leaves no socket');

my ($hfh, $hpath) = tempfile('imapidle-held-XXXX', SUFFIX => '.conf', TMPDIR => 1);
print $hfh <<'EOF';
[held]
type = account
disabled = yes
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = heldch

[watch]
type = idle
channel = held
folder0 = INBOX
EOF
close $hfh;
is(load_config($hpath), '', 'a held idle account loads');
my $held_all = ctl_reply('all');
unlike($held_all, qr/config_disabled/, 'config_disabled is not a socket node');
like($held_all, qr/^account\.held\.disabled=1$/m, 'the file hold is the disabled node');
my $logins = 0;
set_login_hook_for_test(sub { $logins++; die "connection timed out\n" });
is(connect_account('held'), 0, 'a disabled account does not log in');
is($logins, 0, 'a disabled account does not call the login');
is(ctl_reply('account.held.disabled=0'), "account.held.disabled=0\n",
    'disabled=0 is a memory write');
connect_account('held');
is($logins, 1, 'clearing the pause logs in');
is(reload_config_now($hpath), '', 'reload reads the file again');
connect_account('held');
is($logins, 1, 'reload puts the file hold back');
plant_idle_for_test('held', 'INBOX', 420, 'heldch');
ok(conn_exists_for_test('held:INBOX'), 'a connection can be planted');
my $before = do { open my $in, '<', $hpath or die $!; local $/; <$in> };
is(ctl_reply('account.held.disabled=1'), "account.held.disabled=1\n",
    'disabled=1 drops the account');
ok(!conn_exists_for_test('held:INBOX'), 'disabled=1 drops the connection');
my $after = do { open my $in2, '<', $hpath or die $!; local $/; <$in2> };
is($after, $before, 'disabled=1 does not rewrite the config');
is(ctl_reply('account.missing.disabled=1'),
    "error unknown oid account.missing.disabled\n",
    'an unknown account has no disabled node');
set_login_hook_for_test(undef);

done_testing;
