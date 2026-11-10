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

sub write_conf {
    my ($body) = @_;
    my ($fh, $path) = tempfile('imapidle-XXXX', SUFFIX => '.conf', TMPDIR => 1);
    print $fh $body;
    close $fh;
    return $path;
}

my $one = write_conf(<<'EOF');
[acct]
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = ch
folder0 = INBOX;priority=5
EOF

is(load_config($one), '', 'initial config loads');
clear_conns_for_test();
plant_idle_for_test('acct', 'INBOX', 420, 'ch');
mark_retry('acct');
my $due = account_next_try('acct');
ok($due > time(), 'account is waiting out a retry');

my $more = write_conf(<<'EOF');
[acct]
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = ch
folder0 = INBOX;priority=3
folder1 = Archive;priority=9
EOF

is(reload_config_now($more), '', 'reload accepts another folder');
my $acct = loaded_account('acct');
is($acct->{folders}[0]{name}, 'INBOX', 'INBOX stays first');
is($acct->{folders}[0]{priority}, 3, 'INBOX priority changed');
is($acct->{folders}[0]{debounce}, 180, 'INBOX gap follows the new priority');
is($acct->{folders}[1]{name}, 'Archive', 'Archive was added');
is($acct->{folders}[1]{debounce}, 3600, 'Archive keeps its own gap');
ok(conn_exists_for_test('acct:INBOX'), 'the open IDLE connection stays');
is(conn_debounce_for_test('acct:INBOX'), 180, 'the open connection uses the new gap');
is(account_next_try('acct'), 0, 'a new IDLE folder is due to connect');

my $bad = write_conf(<<'EOF');
[acct]
server = imap.example.com
user = a@example.com
mbsync_channel = ch
folder0 = INBOX
EOF
isnt(reload_config_now($bad), '', 'a bad file is rejected');
is(loaded_account('acct')->{folders}[1]{name}, 'Archive', 'the previous folders stay');
ok(conn_exists_for_test('acct:INBOX'), 'the open connection stays after a bad file');

my $moved = write_conf(<<'EOF');
[acct]
server = other.example.com
user = a@example.com
pass = secret
mbsync_channel = ch
folder0 = INBOX;priority=3
folder1 = Archive;priority=9
EOF
is(reload_config_now($moved), '', 'reload accepts a new server');
ok(!conn_exists_for_test('acct:INBOX'), 'a server change drops the connection');
is(loaded_account('acct')->{server}, 'other.example.com', 'the new server is stored');
is(account_next_try('acct'), 0, 'the changed account connects again');

clear_conns_for_test();
is(load_config($one), '', 'reload the one-folder file for NOTIFY');
plant_notify_for_test('acct');
mark_retry('acct');
my $notify_due = account_next_try('acct');
is(reload_config_now($more), '', 'NOTIFY reload adds a folder');
ok(conn_exists_for_test('acct:NOTIFY'), 'the NOTIFY connection stays');
is(notify_folder_count_for_test('acct'), 2, 'NOTIFY watches the new folder list');
is(account_next_try('acct'), $notify_due, 'NOTIFY does not reconnect for a new folder');

my $gone = write_conf(<<'EOF');
[other]
server = imap.example.com
user = b@example.com
pass = secret
mbsync_channel = ch2
folder = INBOX
EOF
is(reload_config_now($gone), '', 'reload can remove an account');
ok(!loaded_account('acct'), 'the old account is gone');
ok(!conn_exists_for_test('acct:NOTIFY'), 'its connection is gone');
ok(loaded_account('other'), 'the new account is loaded');

done_testing;
