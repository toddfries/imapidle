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
use Digest::SHA qw(sha1);
use File::Temp qw(tempdir tempfile);
use IO::Socket::IP;
use IO::Socket::SSL;
use POSIX qw(_exit);
use Test::More;

require './imapidle';

my $run   = tempdir('imapidle-tls-XXXX', CLEANUP => 1, TMPDIR => 1);
my $state = "$run/state";
mkdir $state or die "mkdir $state: $!";
set_runtime_dir_for_test($run);
set_state_dir_for_test($state);
set_foreground_for_test(0);

my @kids;
END { kill 'KILL', @kids if @kids; }

sub slurp {
    my ($file) = @_;
    open my $fh, '<', $file or die "read $file: $!";
    binmode $fh;
    local $/;
    return scalar <$fh>;
}

sub stderr_of {
    my ($code) = @_;
    my ($fh, $path) = tempfile('imapidle-err-XXXX', TMPDIR => 1);
    close $fh;
    open my $old, '>&', STDERR or die "dup stderr: $!";
    open STDERR, '>', $path or die "redirect stderr: $!";
    set_foreground_for_test(1);
    my $ok = eval { $code->(); 1 };
    my $err = $@;
    set_foreground_for_test(0);
    open STDERR, '>&', $old or die "restore stderr: $!";
    open my $in, '<', $path or die "read stderr: $!";
    local $/;
    my $buf = <$in> // '';
    close $in;
    unlink $path;
    die $err unless $ok;
    return $buf;
}

sub files_under {
    my ($root) = @_;
    my @out;
    return @out unless -d $root;
    opendir my $dh, $root or die "opendir $root: $!";
    my @years = grep { !/^\./ && -d "$root/$_" } readdir $dh;
    closedir $dh;
    for my $year (@years) {
        opendir my $yh, "$root/$year" or die "opendir $year: $!";
        push @out, map { "$root/$year/$_" } grep { !/^\./ } readdir $yh;
        closedir $yh;
    }
    return sort @out;
}

sub u8  { return pack('C', $_[0]); }
sub u16 { return pack('n', $_[0]); }
sub u24 { return substr(pack('N', $_[0]), 1); }

is(_bio_dump('ABCDEFGHIJKLMNOP'),
    "0000 - 41 42 43 44 45 46 47 48-49 4a 4b 4c 4d 4e 4f 50   ABCDEFGHIJKLMNOP\n",
    'a full hex row matches the LibreSSL dump');
is(_bio_dump(''), '', 'an empty dump is empty');
like(_bio_dump("AB \0"), qr/<SPACES\/NULS>/, 'trailing spaces and NULs are marked');

my $share = _tls_ext_record('client', 51, 'SECRETKEYMATERIAL');
like($share, qr/TLS client extension "key share" \(id=51\), len=17\nephemeral\n/,
    'a key share keeps its length and drops the bytes');
unlike($share, qr/53 45 43/, 'a key share is not hex dumped');
my $ticket = _tls_ext_record('server', 35, 'ticket-bytes-change-length');
is($ticket, "TLS server extension \"session ticket\" (id=35)\nephemeral\n",
    'a ticket omits both length and bytes');
my $name = _tls_ext_record('client', 0, "\x00\x05mail0");
like($name, qr/server name/, 'a server name is kept');
like($name, qr/6d 61 69 6c 30/, 'a stable extension is hex dumped');

my $sni_host = 'mail0.fdh.bz';
my $sni = u16(length($sni_host) + 3) . u8(0) . u16(length($sni_host)) . $sni_host;
my $kshare = 'K' x 32;
my $exts = u16(0) . u16(length($sni)) . $sni
    . u16(51) . u16(length($kshare)) . $kshare;
my $ciphers = u16(0x1301);
my $body = u16(0x0303) . ('R' x 32) . u8(0)
    . u16(length($ciphers)) . $ciphers . u8(1) . "\x00"
    . u16(length($exts)) . $exts;
my $hello = u8(1) . u24(length($body)) . $body;
my $parsed = join('', _tls_extension_lines(1, $hello));
like($parsed, qr/server name/, 'a client hello yields the server name');
like($parsed, qr/mail0\.fdh\.b/, 'the server name bytes are in the dump');
like($parsed, qr/key share.*\nephemeral\n/s, 'the client hello key share is ephemeral');
unlike($parsed, qr/4b 4b 4b/, 'the client hello key share bytes are absent');

my $year = (localtime)[5] + 1900;
my $sample = "chain snapshot\n";
my $hash = unpack('H*', sha1($sample));
my $saved = _save_hashed_file('certs', 'mail0.fdh.bz', 993, $sample);
like($saved, qr{/\Q$year\E/\Q$hash\E-mail0\.fdh\.bz:993\z},
    'the name is the year, the SHA1, and host:port');
is(slurp($saved), $sample, 'the file is the body that was hashed');
is((stat $saved)[2] & 0777, 0600, 'a saved file is mode 0600');
is((stat "$state/certs")[2] & 0777, 0700, 'the certs directory is mode 0700');
is((stat "$state/certs/$year")[2] & 0777, 0700, 'the year directory is mode 0700');
my $again = _save_hashed_file('certs', 'mail0.fdh.bz', 993, $sample);
is($again, $saved, 'the same body is not written twice');
my @stored = files_under("$state/certs");
is(scalar @stored, 1, 'one body is one cert file');
my $other = _save_hashed_file('certs', 'mail0.fdh.bz', 993, "other chain\n");
isnt($other, $saved, 'a different body gets its own file');
@stored = files_under("$state/certs");
is(scalar @stored, 2, 'two bodies are two cert files');
my $slashed = _save_hashed_file('tls-negotiations', 'a/b\\c', 993, "neg\n");
like($slashed, qr/-a_b_c:993\z/, 'slashes in the host become underscores');
my $nhash = unpack('H*', sha1("neg\n"));
like($slashed, qr{/\Q$nhash\E-a_b_c:993\z}, 'the negotiation name hashes its body');

sub make_cert {
    my ($dir, $cn) = @_;
    my $key = "$dir/$cn.key";
    my $crt = "$dir/$cn.crt";
    my @tries = (
        [qw(openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1),
            '-keyout', $key, '-out', $crt, '-days', '1', '-nodes',
            '-subj', "/CN=$cn"],
        [qw(openssl req -x509 -newkey rsa:2048),
            '-keyout', $key, '-out', $crt, '-days', '1', '-nodes',
            '-subj', "/CN=$cn"],
    );
    my $err = 'openssl did not run';
    for my $cmd (@tries) {
        my $pid = open my $fh, '-|';
        die "fork openssl: $!" unless defined $pid;
        if ($pid == 0) {
            open STDERR, '>&', STDOUT;
            exec @$cmd or _exit(127);
        }
        local $/;
        $err = <$fh> // '';
        close $fh;
        last if $? == 0 && -s $crt && -s $key;
        unlink $key, $crt;
    }
    die "openssl req: $err" unless -s $crt && -s $key;
    return ($crt, $key);
}

sub serve {
    my ($crt, $key, $n) = @_;
    my $ln = IO::Socket::IP->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Proto     => 'tcp',
        Listen    => 5,
        ReuseAddr => 1,
    ) or die "listen: $!";
    my $port = $ln->sockport;
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        eval {
            local $SIG{PIPE} = 'IGNORE';
            for (1 .. $n) {
                my $cli = $ln->accept() or last;
                my $ssl = IO::Socket::SSL->start_SSL(
                    $cli,
                    SSL_server    => 1,
                    SSL_cert_file => $crt,
                    SSL_key_file  => $key,
                );
                close($ssl || $cli);
            }
        };
        _exit(0);
    }
    push @kids, $pid;
    return ($ln, $port);
}

my ($crt_a, $key_a) = make_cert($run, 'one');
my ($crt_b, $key_b) = make_cert($run, 'two');
my ($ln_a, $port_a) = serve($crt_a, $key_a, 2);
my ($ln_b, $port_b) = serve($crt_b, $key_b, 1);

my @socks;
my $first = stderr_of(sub {
    my $sock = tcp_ssl_connect('127.0.0.1', $port_a);
    push @socks, $sock;
});
like($first, qr/127\.0\.0\.1:$port_a: tls cert [0-9a-f]{40}/, 'a new chain is logged');
like($first, qr/127\.0\.0\.1:$port_a: tls negotiation [0-9a-f]{40}/,
    'a new negotiation is logged');

my $second = stderr_of(sub {
    my $sock = tcp_ssl_connect('127.0.0.1', $port_a);
    push @socks, $sock;
});
unlike($second, qr/tls cert/, 'the same chain is not logged again');
unlike($second, qr/tls negotiation/, 'the same negotiation is not logged again');

my $third = stderr_of(sub {
    my $sock = tcp_ssl_connect('127.0.0.1', $port_b);
    push @socks, $sock;
});
like($third, qr/tls cert [0-9a-f]{40}/, 'a different chain is logged');
close $_ for @socks;
close $ln_a;
close $ln_b;
kill 'TERM', @kids;
waitpid $_, 0 for @kids;
@kids = ();

my @certs = files_under("$state/certs");
my @negs  = files_under("$state/tls-negotiations");
# The unit-test bodies are still in these directories.
my @live_certs = grep { /127\.0\.0\.1:/ } @certs;
my @live_negs  = grep { /127\.0\.0\.1:/ } @negs;
is(scalar @live_certs, 2, 'two servers leave two certificate files');
is(scalar @live_negs, 2, 'two servers leave two negotiation files')
    or diag(join("\n", map { "$_\n" . slurp($_) } @live_negs));

my %cert_body;
for my $path (@live_certs) {
    my $text = slurp($path);
    my ($name) = $path =~ m{/([^/]+)\z};
    like($name, qr/^([0-9a-f]{40})-127\.0\.0\.1:\d+\z/, 'a cert file is hash-host:port');
    my ($got) = $name =~ /^([0-9a-f]{40})-/;
    is($got, unpack('H*', sha1($text)), 'the cert file name is the SHA1 of its bytes');
    like($text, qr/-----BEGIN CERTIFICATE-----/, 'the chain is PEM');
    like($text, qr/^Certificate chain\n/m, 'the chain uses the showcerts heading');
    like($text, qr/^Server certificate\n/m, 'the leaf is labeled');
    $cert_body{$path} = $text;
}
isnt((values %cert_body)[0], (values %cert_body)[1], 'the two chains differ');

for my $path (@live_negs) {
    my $text = slurp($path);
    my ($name) = $path =~ m{/([^/]+)\z};
    like($name, qr/^([0-9a-f]{40})-127\.0\.0\.1:\d+\z/,
        'a negotiation file is hash-host:port');
    my ($got) = $name =~ /^([0-9a-f]{40})-/;
    is($got, unpack('H*', sha1($text)), 'the negotiation name is the SHA1 of its bytes');
    like($text, qr/^offered sha1: [0-9a-f]{40}$/m, 'the client offer is hashed');
    like($text, qr/^version: \S/m, 'the negotiated version is recorded');
    like($text, qr/^cipher: \S/m, 'the negotiated cipher is recorded');
    like($text, qr/^compression: NONE$/m, 'compression is recorded');
    like($text, qr/key share" \(id=51\), len=\d+\nephemeral\n/,
        'the key share length is kept and the bytes are not');
    unlike($text, qr/master secret|verify_data|session id/i,
        'ephemeral session material is absent');
    is((stat $path)[2] & 0777, 0600, 'a negotiation file is mode 0600');
}

done_testing;
