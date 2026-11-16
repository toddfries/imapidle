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
use MIME::Base64 qw(decode_base64);
use Test::More;

require './imapidle';

my $rundir = tempdir('imapidle-cfg-XXXX', CLEANUP => 1, TMPDIR => 1);
set_runtime_dir_for_test($rundir);

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
is($good->{folders}[1]{resync}, default_resync(), 'a folder resync defaults to 12h');
is($good->{hyperdelete}, 0, 'hyperdelete defaults off');

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

[zbox]
type = idle
folder0 = INBOX
EOF
$err = load_config($bad);
like($err, qr/\[broken\] set only one of pass or pass_cmd/, 'both forms are an error');
like($err, qr/\[short\] missing channel/, 'an idle section needs channel');
unlike($err, qr/\[short\] missing user/, 'the idle error does not ask for user');
unlike($err, qr/\[short\] missing pass/, 'the idle error does not ask for pass');
like($err, qr/\[zbox\] missing channel/, 'folders without channel need channel');
unlike($err, qr/\[zbox\] missing user/, 'a folder list does not ask for user');
unlike($err, qr/\[zbox\] missing pass/, 'a folder list does not ask for pass');
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
like(load_config($no), qr/\[nope\] missing channel/, 'no does not skip the channel');
unlike(load_config($no), qr/missing user/, 'disabled=no does not ask for user');
unlike(load_config($no), qr/missing pass/, 'disabled=no does not ask for pass');
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
[one]
type = account
server = imap.example.com
user = a@example.com
pass = secret

[two]
type = account
server = imap.example.com
user = b@example.com
pass = secret

[a]
type = pulse
sweep = 100
channel0 = one

[b]
type = pulse
sweep = 200
channel0 = two
EOF
is(load_config($two_pulse), '', 'two pulse sections load');
is(scalar @{ pulse_snapshot_for_test()->{sections} }, 2, 'both pulse sections are kept');
is(loaded_account('one')->{role}, 'pulse', 'the first account is a pulse login');
is(loaded_account('one')->{sweep}, 100, 'each section keeps its sweep');
is(loaded_account('two')->{sweep}, 200, 'the second sweep is independent');
unlink $two_pulse;

my $unknown_pulse = write_conf(<<'EOF');
[a]
type = pulse
channel0 = missing
EOF
like(load_config($unknown_pulse), qr/\[a\] unknown account missing/, 'a pulse channel must name an account');
unlink $unknown_pulse;

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

my $old_login = write_conf(<<'EOF');
[box]
type = passonly
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = lists
EOF
like(load_config($old_login), qr/\[box\] bad type/, 'an unknown section type is rejected');
unlink $old_login;

my $acct_only = write_conf(<<'EOF');
[box]
type = account
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = lists
EOF
is(load_config($acct_only), '', 'an account with no schedule loads');
is(loaded_account('box')->{role}, 'account', 'the login stays unbound');
is(connect_account('box'), 1, 'an unbound account does not connect');
is(conn_count(), 0, 'an unbound account opens no socket');
my @po = info_lines(time());
ok((grep { $_ eq 'box: account server imap.example.com channel lists' } @po),
    'state names an unbound account');
ok(!grep(/box: down/, @po), 'an unbound account is not down');
unlink $acct_only;

my $held_acct = write_conf(<<'EOF');
[box]
type = account
disabled = yes
mbsync_channel = lists
EOF
is(load_config($held_acct), '', 'a disabled account loads');
like((grep { /^box: / } info_lines(time()))[0], qr/^box: disabled/, 'a disabled account stays disabled');
unlink $held_acct;

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

my $aged = write_conf(<<'EOF');
[track]
type = global
hyperdelete = yes

[acct]
type = idle
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = ch
hyperdelete = no
folder0 = INBOX.2026-11;1;3600
folder1 = Archive;priority=9;7200
EOF
is(load_config($aged), '', 'a positional folder age loads');
is(loaded_account('acct')->{hyperdelete}, 0, 'the account hyperdelete wins');
is(loaded_account('acct')->{folders}[0]{priority}, 1, 'the middle field is the priority');
is(loaded_account('acct')->{folders}[0]{debounce}, 7, 'priority 1 is still 7s');
is(loaded_account('acct')->{folders}[0]{resync}, 3600, 'the third field is the resync ceiling');
is(loaded_account('acct')->{folders}[1]{resync}, 7200, 'priority=N accepts a following age');
unlink $aged;

my $legacy = write_conf(<<'EOF');
[acct]
type = idle
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = ch
folder0 = INBOX;1
EOF
is(load_config($legacy), '', 'a two-field bare number loads');
is(loaded_account('acct')->{folders}[0]{priority}, 5, 'a bare number without a resync time stays priority 5');
is(loaded_account('acct')->{folders}[0]{resync}, default_resync(), 'that folder keeps the 12h resync');
unlink $legacy;

my $global_hyper = write_conf(<<'EOF');
[track]
type = global
hyperdelete = yes

[acct]
type = idle
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = ch
folder0 = INBOX
EOF
is(load_config($global_hyper), '', 'a global hyperdelete loads');
is(loaded_account('acct')->{hyperdelete}, 1, 'an account inherits global hyperdelete');
unlink $global_hyper;

my $bad_age = write_conf(<<'EOF');
[acct]
type = idle
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = ch
folder0 = INBOX;5;10
EOF
like(load_config($bad_age), qr/bad resync/, 'a resync below 60 seconds is rejected');
unlink $bad_age;

done_testing;
