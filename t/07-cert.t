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

sub slurp {
    my ($file) = @_;
    open my $fh, '<', $file or die "read $file: $!";
    local $/;
    return scalar <$fh>;
}

my $stamp = qr/\d{8}T\d{2}:\d{2}:\d{2}Z/;

set_foreground_for_test(1);
my $stored = stderr_of(sub {
    ok(approve_fingerprint('mail.example', 993, 'SHA256$aaa'), 'unknown cert is accepted');
});
is($stored, "imapidle: [tls]   : 01.cert mail.example:993 fp new\n"
    . "imapidle: [tls]   : 01.cert +SHA256\$aaa\n", 'a new fingerprint is logged once');
unlike($stored, qr/Accept this certificate/, 'a new fingerprint does not prompt');
ok(-f $path, 'known_hosts was created');
is((stat $path)[2] & 0777, 0600, 'known_hosts mode is 0600');
like(slurp($path), qr/^mail\.example:993\tSHA256\$aaa$/m, 'first fingerprint is current');

my $same = stderr_of(sub {
    ok(approve_fingerprint('mail.example', 993, 'SHA256$aaa'), 'matching cert is accepted');
});
is($same, '', 'the same host is not logged again');

my $changed = stderr_of(sub {
    ok(approve_fingerprint('mail.example', 993, 'SHA256$bbb'), 'changed cert is accepted');
});
is($changed, "imapidle: [tls]   : 01.cert mail.example:993 fp change\n"
    . "imapidle: [tls]   : 01.cert +SHA256\$bbb\n"
    . "imapidle: [tls]   : 01.cert -SHA256\$aaa\n", 'a change names the new and old fingerprints');
my $after = slurp($path);
like($after, qr/^mail\.example:993\tSHA256\$aaa\t$stamp$/m, 'the old fingerprint is retired');
like($after, qr/^mail\.example:993\tSHA256\$bbb$/m, 'the new fingerprint is current');

set_foreground_for_test(0);
my $quiet = stderr_of(sub {
    ok(approve_fingerprint('mail.example', 993, 'SHA256$ccc'), 'daemon accepts a change without a tty');
});
is($quiet, '', 'a daemonized process does not print the certificate lines');
my $daemon = slurp($path);
like($daemon, qr/^mail\.example:993\tSHA256\$bbb\t$stamp$/m, 'the previous current fingerprint is retired');
like($daemon, qr/^mail\.example:993\tSHA256\$ccc$/m, 'the daemon stores the new fingerprint');
is(scalar(() = $daemon =~ /^mail\.example:993\t\S+$/mg), 1, 'one line for this host has no retired time');

set_foreground_for_test(1);
my $missing = stderr_of(sub {
    ok(!approve_fingerprint('mail.example', 993, ''), 'a missing fingerprint is refused');
});
like($missing, qr/Certificate fingerprint missing for mail\.example:993/, 'the refusal is logged');
unlike($missing, qr/Accept this certificate/, 'the refusal is not a prompt');
like(slurp($path), qr/^mail\.example:993\tSHA256\$ccc$/m, 'a missing fingerprint leaves the current value');

my $other = stderr_of(sub {
    ok(approve_fingerprint('other.example', 993, 'SHA256$ddd'), 'a second host is accepted');
    ok(approve_fingerprint('other.example', 993, 'SHA256$ddd'), 'the second host is seen again');
});
is($other, "imapidle: [tls]   : 02.cert other.example:993 fp new\n"
    . "imapidle: [tls]   : 02.cert +SHA256\$ddd\n", 'each host is numbered once');

my $legacy = "$dir/legacy_hosts";
open my $leg, '>', $legacy or die $!;
print $leg "old.example:993\tSHA256\$eee\n";
close $leg;
set_known_hosts_for_test($legacy);
my $match = stderr_of(sub {
    ok(approve_fingerprint('old.example', 993, 'SHA256$eee'), 'a stored fingerprint matches');
    ok(approve_fingerprint('old.example', 993, 'SHA256$eee'), 'the match is not repeated');
});
is($match, "imapidle: [tls]   : 03.cert old.example:993 fp match\n", 'an existing pin logs match once');
my $swap = stderr_of(sub {
    ok(approve_fingerprint('old.example', 993, 'SHA256$fff'), 'a legacy pin can change');
});
is($swap, "imapidle: [tls]   : 03.cert old.example:993 fp change\n"
    . "imapidle: [tls]   : 03.cert +SHA256\$fff\n"
    . "imapidle: [tls]   : 03.cert -SHA256\$eee\n", 'the same host number is reused');
my $leg_text = slurp($legacy);
like($leg_text, qr/^old\.example:993\tSHA256\$eee\t$stamp$/m, 'the legacy fingerprint is retired');
like($leg_text, qr/^old\.example:993\tSHA256\$fff$/m, 'the replacement has no retired time');

is(_tls_version_label('TLSv1_2'), 'TLSv1.2', 'a LibreSSL version label is dotted');
is(_tls_version_label('TLSv1'), 'TLSv1.0', 'a bare TLS label is 1.0');
is(_tls_version_label('TLSv1_3'), 'TLSv1.3', 'TLS 1.3 stays dotted');

my $full = stderr_of(sub {
    ok(approve_fingerprint('full.example', 993, 'SHA256$ggg', {
        version => 'TLSv1.2',
        cipher  => 'ECDHE-RSA-AES256-GCM-SHA384',
        cbits   => 256,
        skey    => 4096,
        comp    => 0,
    }), 'handshake facts are accepted');
});
is($full, "imapidle: [tls]   : 04.cert full.example:993 TLSv1.2"
    . " ECDHE-RSA-AES256-GCM-SHA384 ci 256b skey 4096b comp 0 fp new\n"
    . "imapidle: [tls]   : 04.cert +SHA256\$ggg\n",
    'handshake facts share the host line');

done_testing;
