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
use Test::More;

require './imapidle';

pipe my $rd, my $wr or die "pipe: $!";
my $key = install_broken_conn_for_test('box', $rd);
is(conn_count(), 1, 'broken session is registered');
handle_ready($rd);
is(conn_count(), 0, 'broken session is dropped');
cmp_ok(account_next_try('box'), '>', time() - 1, 'account is scheduled to retry');
is($key, 'box:INBOX', 'key names the account and folder');
pass('process still running after a dead socket');

close $rd;
close $wr;
done_testing;
