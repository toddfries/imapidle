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

is(calculate_debounce(1), 8,    'priority 1 is 8s');
is(calculate_debounce(2), 8,    'priority 2 is 8s');
is(calculate_debounce(3), 180,  'priority 3 is 180s');
is(calculate_debounce(5), 420,  'priority 5 is 420s');
is(calculate_debounce(8), 780,  'priority 8 is 780s');
is(calculate_debounce(9), 3600, 'priority 9 is 3600s');

my ($fh, $path) = tempfile('imapidle-XXXX', SUFFIX => '.conf', TMPDIR => 1);
print $fh <<'EOF';
[good]
server = imap.example.com
user = a@example.com
password = secret
mbsync_channel = personal
folder0 = INBOX;priority=1
folder1 = Archive

[cmd]
server = imap.example.com
user = b@example.com
password_cmd = printf '%s\n' tok
mbsync_channel = work
folder = INBOX
priority = 9

[both]
server = imap.example.com
user = c@example.com
password = x
password_cmd = true
mbsync_channel = no
folder = INBOX

[incomplete]
server = imap.example.com

[emptybox]
server = imap.example.com
user = d@example.com
password = x
mbsync_channel = d
folder0 =
EOF
close $fh;

my $err = load_config($path);
is($err, '', 'mixed file still loads') or diag($err);
is_deeply([account_names()], [qw(cmd good)], 'bad sections are skipped');

my $good = loaded_account('good');
is($good->{password}, 'secret', 'password kept');
ok(!defined $good->{password_cmd}, 'password account has no command');
is($good->{folders}[0]{name}, 'INBOX', 'folder0 name');
is($good->{folders}[0]{debounce}, 8, 'folder0 debounce');
is($good->{folders}[1]{name}, 'Archive', 'folder1 name');
is($good->{folders}[1]{priority}, 5, 'folder1 default priority');
is($good->{folders}[1]{debounce}, 420, 'folder1 debounce');

my $cmd = loaded_account('cmd');
is($cmd->{password_cmd}, "printf '%s\\n' tok", 'password_cmd kept');
ok(!defined $cmd->{password}, 'command account has no stored password');
is($cmd->{folders}[0]{debounce}, 3600, 'legacy priority 9');

my $tok = capture_password_cmd($cmd->{password_cmd});
is($tok, 'tok', 'password_cmd stdout is the password');
ok(!defined capture_password_cmd('exit 1'), 'failing command yields no password');
ok(!defined capture_password_cmd('true'), 'empty stdout yields no password');
ok(!defined capture_password_cmd('sleep 3', 1), 'hung command yields no password');

unlink $path;
done_testing;
