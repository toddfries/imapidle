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
use Test::More;

require './imapidle';

my $dir  = tempdir('imapidle-XXXX', CLEANUP => 1, TMPDIR => 1);
my $path = "$dir/known_hosts";
set_known_hosts_for_test($path);

sub stderr_of {
    my ($code) = @_;
    my ($fh, $path) = tempfile('imapidle-err-XXXX', TMPDIR => 1);
    close $fh;
    open my $old, '>&', STDERR or die "dup stderr: $!";
    open STDERR, '>', $path or die "redirect stderr: $!";
    my $ok = eval { $code->(); 1 };
    my $err = $@;
    open STDERR, '>&', $old or die "restore stderr: $!";
    open my $in, '<', $path or die "read stderr: $!";
    local $/;
    my $buf = <$in> // '';
    close $in;
    unlink $path;
    die $err unless $ok;
    return $buf;
}

open my $no, '<', \"n\n" or die "stdin: $!";
local *STDIN = $no;

set_foreground_for_test(1);
my $stored = stderr_of(sub {
    ok(approve_fingerprint('mail.example', 993, 'SHA256$aaa'), 'unknown cert is accepted');
});
like($stored, qr/Certificate stored for mail\.example:993 SHA256\$aaa/, 'first fingerprint is logged');
unlike($stored, qr/Accept this certificate/, 'first fingerprint does not prompt');
ok(-f $path, 'known_hosts was created');
is((stat $path)[2] & 0777, 0600, 'known_hosts mode is 0600');
like(do { local $/; open my $fh, '<', $path or die $!; <$fh> },
    qr/^mail\.example:993\tSHA256\$aaa$/m, 'first fingerprint is stored');

my $same = stderr_of(sub {
    ok(approve_fingerprint('mail.example', 993, 'SHA256$aaa'), 'matching cert is accepted');
});
is($same, '', 'a matching fingerprint adds no log line');

my $changed = stderr_of(sub {
    ok(approve_fingerprint('mail.example', 993, 'SHA256$bbb'), 'changed cert is accepted');
});
like($changed, qr/Certificate changed for mail\.example:993 old SHA256\$aaa new SHA256\$bbb/,
    'a changed fingerprint is a warning');
unlike($changed, qr/Accept this certificate/, 'a changed fingerprint does not prompt');
like(do { local $/; open my $fh, '<', $path or die $!; <$fh> },
    qr/^mail\.example:993\tSHA256\$bbb$/m, 'the new fingerprint replaces the stored one');
unlike(do { local $/; open my $fh, '<', $path or die $!; <$fh> },
    qr/SHA256\$aaa/, 'the old fingerprint is not kept');

set_foreground_for_test(0);
my $quiet = stderr_of(sub {
    ok(approve_fingerprint('mail.example', 993, 'SHA256$ccc'), 'daemon accepts a change without a tty');
});
is($quiet, '', 'a daemonized process does not prompt or print the warning');
like(do { local $/; open my $fh, '<', $path or die $!; <$fh> },
    qr/^mail\.example:993\tSHA256\$ccc$/m, 'the daemon stores the new fingerprint');

set_foreground_for_test(1);
my $missing = stderr_of(sub {
    ok(!approve_fingerprint('mail.example', 993, ''), 'a missing fingerprint is refused');
});
like($missing, qr/Certificate fingerprint missing for mail\.example:993/, 'the refusal is logged');
unlike($missing, qr/Accept this certificate/, 'the refusal is not a prompt');
like(do { local $/; open my $fh, '<', $path or die $!; <$fh> },
    qr/^mail\.example:993\tSHA256\$ccc$/m, 'a missing fingerprint leaves the stored value');

done_testing;
