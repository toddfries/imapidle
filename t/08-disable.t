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

my ($fh, $path) = tempfile('imapidle-XXXX', SUFFIX => '.conf', TMPDIR => 1);
print $fh <<'EOF';
[acct]
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = ch
folder0 = INBOX;priority=5
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

is(load_config($path), '', 'config loads');
clear_conns_for_test();
reset_schedule_for_test();
set_foreground_for_test(1);

my $limit = start_give_up();
my $gave_up = stderr_of(sub {
    mark_retry('acct') for 1 .. $limit;
});
like($gave_up, qr/\[acct\] retry in 5s/, 'the first failure is retried');
like($gave_up, qr/\[acct\] disabled after $limit failures/, 'the limit disables the account');
unlike($gave_up, qr/retry in 27s/, 'the disabling failure does not schedule another retry');
ok(loaded_account('acct')->{disabled}, 'the account is disabled');
is(account_next_try('acct'), 0, 'a disabled account has no retry time');

my @info = info_lines(time());
is($info[1], '[acct] disabled server imap.example.com channel ch', 'state names the account disabled');
is(loop_timeout(), 30, 'a disabled account does not shorten the wait');

my $enabled = stderr_of(sub {
    is(reload_config_now($path), '', 'reload accepts the same file');
});
like($enabled, qr/\[acct\] enabled/, 'SIGHUP enables the account');
ok(!loaded_account('acct')->{disabled}, 'the account is no longer disabled');
is(loaded_account('acct')->{fails}, 0, 'the failure count starts over');

note_success('acct');
stderr_of(sub {
    mark_retry('acct') for 1 .. ($limit + 3);
});
ok(!loaded_account('acct')->{disabled}, 'an account that has monitored keeps retrying');
ok(account_next_try('acct') > time(), 'that account still has a retry time');
my @later = info_lines(time());
like($later[1], qr/^\[acct\] down server imap\.example\.com channel ch retry \d+s$/,
    'a retrying account is down, not disabled');

clear_conns_for_test();
set_foreground_for_test(0);
is(load_config($path), '', 'reload a fresh account for the partial case');
plant_idle_for_test('acct', 'INBOX', 420, 'ch');
stderr_of(sub {
    mark_retry('acct') for 1 .. $limit;
});
ok(conn_exists_for_test('acct:INBOX'), 'a connection already up is left in place');
my @partial = info_lines(time());
is($partial[1], '[acct] IDLE INBOX disabled server imap.example.com channel ch',
    'a partial account shows the open mailbox and disabled');

set_foreground_for_test(0);
done_testing;
