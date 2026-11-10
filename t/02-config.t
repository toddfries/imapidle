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

is(calculate_debounce(0), 7,    'priority 0 uses the priority 1 gap');
is(calculate_debounce(1), 7,    'priority 1 is 7s');
is(calculate_debounce(2), 42,   'priority 2 is 42s');
is(calculate_debounce(3), 128,  'priority 3 is 128s');
is(calculate_debounce(4), 256,  'priority 4 is 256s');
is(calculate_debounce(5), 420,  'priority 5 is 420s');
is(calculate_debounce(6), 540,  'priority 6 is 540s');
is(calculate_debounce(8), 780,  'priority 8 is 780s');
is(calculate_debounce(9), 3600, 'priority 9 is 3600s');

my ($fh, $path) = tempfile('imapidle-XXXX', SUFFIX => '.conf', TMPDIR => 1);
print $fh <<'EOF';
[good]
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = personal
folder0 = INBOX;priority=1
folder1 = Archive

[cmd]
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
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = personal

[broken]
server = imap.example.com
user = b@example.com
pass = x
pass_cmd = true
mbsync_channel = no

[short]
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

done_testing;
