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
use MIME::Base64 qw(decode_base64);
use Test::More;

require './imapidle';

is(calculate_debounce(0), 7,    'priority 0 uses the priority 1 gap');
is(calculate_debounce(1), 7,    'priority 1 is 7s');
is(calculate_debounce(2), 42,   'priority 2 is 42s');
is(calculate_debounce(3), 128,  'priority 3 is 128s');
is(calculate_debounce(4), 256,  'priority 4 is 256s');
is(calculate_debounce(5), 420,  'priority 5 is 420s');
is(calculate_debounce(6), 540,  'priority 6 is 540s');
is(calculate_debounce(8), 780,  'priority 8 is 780s');
is(calculate_debounce(9), 3600, 'priority 9 is 3600s');

my $sasl = xoauth2_initial('user@example.com', 'tok');
is(decode_base64($sasl), "user=user\@example.com\x01auth=Bearer tok\x01\x01",
    'xoauth2 initial response is the bearer string');
unlike($sasl, qr/\n/, 'the initial response is one line');

my ($fh, $path) = tempfile('imapidle-XXXX', SUFFIX => '.conf', TMPDIR => 1);
print $fh <<'EOF';
[good]
type = idle
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = personal
folder0 = INBOX;priority=1
folder1 = Archive

[cmd]
type = idle
server = imap.example.com
user = b@example.com
pass_cmd = printf '%s\n' tok
mbsync_channel = work
folder = INBOX
priority = 9
EOF
close $fh;

my $err = load_config($path);
is($err, '', 'valid file loads') or diag($err);
is(track_cfg_for_test()->{tunnel}, 0, 'tunnel defaults off');
is(track_cfg_for_test()->{tunnel_timeout}, 3600, 'tunnel timeout defaults to 3600');
is_deeply([account_names()], [qw(cmd good)], 'both accounts load');

my $good = loaded_account('good');
is($good->{pass}, 'secret', 'pass kept');
ok(!defined $good->{pass_cmd}, 'pass account has no command');
is($good->{folders}[0]{name}, 'INBOX', 'folder0 name');
is($good->{folders}[0]{debounce}, 7, 'folder0 debounce');
is($good->{folders}[1]{name}, 'Archive', 'folder1 name');
is($good->{folders}[1]{priority}, 5, 'folder1 default priority');
is($good->{folders}[1]{debounce}, 420, 'folder1 debounce');

my $cmd = loaded_account('cmd');
is($cmd->{pass_cmd}, "printf '%s\\n' tok", 'pass_cmd kept');
ok(!defined $cmd->{pass}, 'command account has no stored password');
is($cmd->{folders}[0]{debounce}, 3600, 'priority 9');

my $tok = capture_pass_cmd($cmd->{pass_cmd});
is($tok, 'tok', 'pass_cmd stdout is the password');
ok(!defined capture_pass_cmd('exit 1'), 'failing command yields no password');
ok(!defined capture_pass_cmd('true'), 'empty stdout yields no password');
ok(!defined capture_pass_cmd('sleep 3', 1), 'hung command yields no password');
unlink $path;

sub write_conf {
    my ($body) = @_;
    my ($out, $file) = tempfile('imapidle-XXXX', SUFFIX => '.conf', TMPDIR => 1);
    print $out $body;
    close $out;
    return $file;
}

my $old = write_conf(<<'EOF');
[old]
type = idle
server = imap.example.com
user = a@example.com
password = secret
mbsync_channel = personal
EOF
$err = load_config($old);
like($err, qr/\[old\] missing pass or pass_cmd/, 'password is not accepted');
is_deeply([account_names()], [], 'failed file loads no accounts');
unlink $old;

my $bad = write_conf(<<'EOF');
[good]
type = idle
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = personal

[broken]
type = idle
server = imap.example.com
user = b@example.com
pass = x
pass_cmd = true
mbsync_channel = no

[short]
type = idle
server = imap.example.com
EOF
$err = load_config($bad);
like($err, qr/\[broken\] set only one of pass or pass_cmd/, 'both forms are an error');
like($err, qr/\[short\] missing user, mbsync_channel/, 'missing keys are named');
like($err, qr/\[short\] missing pass or pass_cmd/, 'missing secret is named');
is_deeply([account_names()], [], 'one bad account rejects the file');

my $run = `perl imapidle -c $bad 2>&1`;
my $rc = $? >> 8;
is($rc, 1, 'missing required keys exit 1') or diag($run);
like($run, qr/^imapidle: \[broken\]/m, 'stderr names the bad account');
unlike($run, qr/entering main loop/, 'daemon does not start');
unlink $bad;

my $held = write_conf(<<'EOF');
[live]
type = idle
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = personal
folder = INBOX

[park]
type = idle
disabled = yes

[off]
type = idle
disabled = Yes
server = imap.example.com
user = b@example.com
pass = secret
mbsync_channel = other
EOF
is(load_config($held), '', 'a disabled section does not have to be complete');
is_deeply([account_names()], [qw(live off park)], 'disabled sections stay loaded');
ok(!loaded_account('live')->{disabled}, 'a section without the flag stays active');
ok(loaded_account('park')->{config_disabled}, 'yes holds the section');
ok(loaded_account('off')->{config_disabled}, 'Yes holds the section');
is(connect_account('park'), 0, 'a held section is not connected');
is(connect_account('off'), 0, 'a held section with keys is not connected');
my @held_lines = grep { /: disabled/ } info_lines(time());
is_deeply(
    \@held_lines,
    [
        'off: disabled server imap.example.com channel other',
        'park: disabled',
    ],
    'state names a config-disabled section',
);
unlink $held;

my $no = write_conf(<<'EOF');
[nope]
type = idle
disabled = no
EOF
like(load_config($no), qr/\[nope\] missing server, user, mbsync_channel/, 'no does not skip required keys');
unlink $no;

my $xo = write_conf(<<'EOF');
[ma]
type = idle
server = outlook.example.com
user = a@example.com
pass_cmd = printf '%s\n' tok
auth = XOAUTH2
mbsync_channel = ma-ttf
folder0 = INBOX
EOF
is(load_config($xo), '', 'xoauth2 account loads');
is(loaded_account('ma')->{auth}, 'xoauth2', 'auth XOAUTH2 is stored');
my @xo = info_lines(time());
like($xo[1], qr/^ma: down server outlook\.example\.com channel ma-ttf auth xoauth2 retry /,
    'state names xoauth2');
unlink $xo;

my $bogus = write_conf(<<'EOF');
[bad]
type = idle
server = imap.example.com
user = a@example.com
pass = secret
auth = plain
mbsync_channel = ch
EOF
like(load_config($bogus), qr/\[bad\] auth must be login or xoauth2/, 'unknown auth is rejected');
unlink $bogus;

my $missing_type = write_conf(<<'EOF');
[acct]
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = ch
EOF
like(load_config($missing_type), qr/\[acct\] missing type/, 'a section requires type');
unlink $missing_type;

my $bad_type = write_conf(<<'EOF');
[acct]
type = weird
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = ch
EOF
like(load_config($bad_type), qr/\[acct\] bad type/, 'an unknown type is rejected');
unlink $bad_type;

my $two_global = write_conf(<<'EOF');
[one]
type = global

[two]
type = global

[acct]
type = idle
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = ch
EOF
like(load_config($two_global), qr/\[two\] second global section/, 'a second global section is rejected');
unlink $two_global;

my $two_pulse = write_conf(<<'EOF');
[a]
type = pulse
channel0 = one

[b]
type = pulse
channel0 = two
EOF
like(load_config($two_pulse), qr/\[b\] second pulse section/, 'a second pulse section is rejected');
unlink $two_pulse;

my $idle_case = write_conf(<<'EOF');
[acct]
type = IDLE
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = ch
EOF
is(load_config($idle_case), '', 'type comparison ignores case');
is(loaded_account('acct')->{role}, 'idle', 'IDLE is an idle account');
unlink $idle_case;

my $passonly = write_conf(<<'EOF');
[box]
type = passonly
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = lists
folder0 = INBOX

[slow]
type = pulse
sweep = 10
channel0 = other
EOF
is(load_config($passonly), '', 'a passonly section loads');
is_deeply(loaded_account('box')->{folders}, [], 'passonly ignores folder keys');
is(loaded_account('box')->{role}, 'passonly', 'role is passonly');
is(connect_account('box'), 1, 'passonly does not connect');
is(conn_count(), 0, 'passonly opens no socket');
is_deeply(pulse_snapshot_for_test()->{channels}, [qw(other lists)], 'passonly joins the pulse list');
my @po = info_lines(time());
ok((grep { $_ eq 'box: passonly server imap.example.com channel lists' } @po),
    'state names a passonly account');
ok(!grep(/box: down/, @po), 'passonly is not down');
unlink $passonly;

my $solo = write_conf(<<'EOF');
[box]
type = passonly
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = lists
EOF
is(load_config($solo), '', 'passonly without pulse still loads');
is(pulse_snapshot_for_test()->{disabled}, 0, 'a blank pulse is enabled');
is(pulse_snapshot_for_test()->{sweep}, 3600, 'that pulse waits 3600s');
is_deeply(pulse_snapshot_for_test()->{channels}, ['lists'], 'the channel is scheduled');
unlink $solo;

my $held_po = write_conf(<<'EOF');
[box]
type = passonly
disabled = yes
mbsync_channel = lists

[slow]
type = pulse
channel0 = other
EOF
is(load_config($held_po), '', 'a disabled passonly section loads');
is_deeply(pulse_snapshot_for_test()->{channels}, ['other'], 'a disabled passonly is not scheduled');
like((grep { /^box: / } info_lines(time()))[0], qr/^box: disabled/, 'a disabled passonly stays disabled');
unlink $held_po;

my $bad_tunnel = write_conf(<<'EOF');
[track]
type = global
tunnel = maybe

[acct]
type = idle
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = ch
EOF
like(load_config($bad_tunnel), qr/\[track\] bad tunnel/, 'tunnel must be yes or no');
unlink $bad_tunnel;

my $bad_to = write_conf(<<'EOF');
[track]
type = global
tunnel_timeout = 0

[acct]
type = idle
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = ch
EOF
like(load_config($bad_to), qr/\[track\] bad tunnel_timeout/, 'tunnel timeout must be at least 1');
unlink $bad_to;

done_testing;
