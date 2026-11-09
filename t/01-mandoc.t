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

my $mandoc = '/usr/bin/mandoc';
plan skip_all => 'mandoc not installed' unless -x $mandoc;

for my $page (qw(man/imapidle.1 man/imapidle.conf.5)) {
    ok(-f $page, "$page is present");
    my $out = `$mandoc -Tlint $page 2>&1`;
    my $rc  = $? >> 8;
    is($rc, 0, "mandoc -Tlint $page exits 0") or diag($out);
    is($out, '', "mandoc -Tlint $page is silent") or diag($out);
}

done_testing;
