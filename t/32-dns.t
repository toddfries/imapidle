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
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use JSON::PP ();
use Socket qw(AF_INET6 inet_pton);

use lib 'lib', 'blib';

my $asr = system('make', '-C', "$Bin/../ext/asr");
is($asr, 0, 'the asr wrapper builds') or BAIL_OUT('asr build failed');
my $imsg = system('make', '-C', "$Bin/../ext/imsg");
is($imsg, 0, 'the imsg wrapper builds') or BAIL_OUT('imsg build failed');

require IMAPIDLE::Asr;
ok(IMAPIDLE::Asr->can('search'), 'asr search is loaded');
ok(IMAPIDLE::Asr->can('run'), 'asr run is loaded');

require IMAPIDLE::DnsPkt;
require IMAPIDLE::DnsCache;
require IMAPIDLE::Dns;

my $pos = dns_pkt(
    qname => 'example.com',
    a     => [
        { ip => '192.0.2.1', ttl => 300 },
        { ip => '192.0.2.2', ttl => 120 },
    ],
);
my $sum = IMAPIDLE::DnsPkt::summarize($pos, 'A');
is($sum->{rcode}, 0, 'a positive reply is NOERROR');
is_deeply($sum->{addrs}, ['192.0.2.1', '192.0.2.2'], 'both A addresses are kept');
is($sum->{ttl}, 120, 'the stored TTL is the smaller address TTL');

my $aaaa = dns_pkt(
    qname => 'example.com',
    aaaa  => [{ ip => '2001:db8::1', ttl => 90 }],
);
my $v6 = IMAPIDLE::DnsPkt::summarize($aaaa, 'AAAA');
is($v6->{addrs}[0], '2001:db8::1', 'an AAAA address is read');
is($v6->{ttl}, 90, 'the AAAA TTL is read');

my $nx = dns_pkt(
    qname => 'missing.example',
    rcode => 3,
    soa   => { ttl => 100, minimum => 40 },
);
my $nxsum = IMAPIDLE::DnsPkt::summarize($nx, 'A');
is($nxsum->{rcode}, 3, 'NXDOMAIN is rcode 3');
is($nxsum->{negative_ttl}, 40, 'negative TTL is the smaller of SOA TTL and MINIMUM');
ok(!@{ $nxsum->{addrs} }, 'NXDOMAIN has no addresses');

my $bare = dns_pkt(qname => 'missing.example', rcode => 3);
my $baresum = IMAPIDLE::DnsPkt::summarize($bare, 'A');
is($baresum->{rcode}, 3, 'NXDOMAIN without an SOA is still NXDOMAIN');
ok(!defined $baresum->{negative_ttl}, 'a reply with no SOA has no negative TTL');

my $nodata = dns_pkt(
    qname => 'example.com',
    rcode => 0,
    soa   => { ttl => 80, minimum => 200 },
);
my $nd = IMAPIDLE::DnsPkt::summarize($nodata, 'AAAA');
is($nd->{rcode}, 0, 'NODATA is NOERROR');
ok(!@{ $nd->{addrs} }, 'NODATA has no addresses');
is($nd->{negative_ttl}, 80, 'NODATA uses the SOA negative TTL');

my $ptr = dns_pkt_pointer();
my $psum = IMAPIDLE::DnsPkt::summarize($ptr, 'A');
is_deeply($psum->{addrs}, ['192.0.2.10'], 'a compressed name still yields the address');

ok(!defined IMAPIDLE::DnsPkt::summarize('short', 'A'), 'a short packet is rejected');

my $dir = tempdir('imapidle-dns-XXXX', CLEANUP => 1, TMPDIR => 1);
my $db = "$dir/dnscache.db";
tie my %cache, 'IMAPIDLE::DnsCache', $db;
$cache{'Example.COM.'} = { v4 => ['192.0.2.9'], v4_expires => 5 };
ok(exists $cache{'example.com'}, 'the key is lowercased and the trailing dot is dropped');
is($cache{'example.com'}{v4}[0], '192.0.2.9', 'a stored row is fetched');
is((stat($db))[2] & 0777, 0600, 'the cache file is mode 0600');
$cache{'example.com'} = undef;
ok(!exists $cache{'example.com'}, 'assigning undef deletes the row');
$cache{'example.com'} = { v4 => ['192.0.2.8'], v4_expires => 9 };
delete $cache{'example.com'};
ok(!exists $cache{'example.com'}, 'delete removes the row');
$cache{'example.com'} = { v4 => ['192.0.2.7'], v4_expires => 11 };
untie %cache;
tie my %again, 'IMAPIDLE::DnsCache', $db;
is($again{'example.com'}{v4}[0], '192.0.2.7', 'a row is still there after the file is reopened');
$again{'example.com'} = undef;
untie %again;
tie my %gone, 'IMAPIDLE::DnsCache', $db;
ok(!exists $gone{'example.com'}, 'a deleted row stays deleted');
untie %gone;

IMAPIDLE::Dns::reset_for_test();
IMAPIDLE::Dns::configure(86400, undef);
IMAPIDLE::Dns::open_cache("$dir/logic.db");
my $now = 1_700_000_000;
my $calls = 0;
IMAPIDLE::Dns::resolver(SeqDns->new(sub {
    my ($host, $type) = @_;
    $calls++ if $host eq 'example.com' && $type eq 'A';
    if ($host eq 'example.com' && $type eq 'A') {
        if ($calls == 1) {
            return [{ done => 1, rcode => 0, packet => dns_pkt(
                qname => 'example.com',
                a     => [{ ip => '192.0.2.1', ttl => 300 }],
            ) }];
        }
        return [{ done => 1, timeout => 1, rcode => -1 }];
    }
    return [{ done => 0, cond => 'read', fd => 6, timeout_ms => 9000 }];
}));
# min_ttl is 86400 here, so a 300s answer is kept for a day.
my $day = IMAPIDLE::Dns::addresses('example.com', $now);
is_deeply($day, ['192.0.2.1'], 'a positive answer is usable at once');
is(IMAPIDLE::Dns::row('example.com')->{v4_expires}, $now + 86400,
    'a short TTL is raised to min_ttl');
is(IMAPIDLE::Dns::row('example.com')->{v4_ttl}, 300, 'the remote TTL is kept beside the floor');

IMAPIDLE::Dns::reset_for_test();
IMAPIDLE::Dns::configure(100, undef);
IMAPIDLE::Dns::open_cache(':memory:');
IMAPIDLE::Dns::resolver(SeqDns->new(sub {
    my ($host, $type) = @_;
    return [{ done => 0, cond => 'read', fd => 6, timeout_ms => 9000 }]
        unless $type eq 'A';
    return [{ done => 1, rcode => 0, packet => dns_pkt(
        qname => $host,
        a     => [{ ip => '192.0.2.50', ttl => 7 * 86400 }],
    ) }];
}));
IMAPIDLE::Dns::addresses('long.example', $now);
is(IMAPIDLE::Dns::row('long.example')->{v4_expires}, $now + 7 * 86400,
    'a TTL above min_ttl is kept for the remote TTL');

IMAPIDLE::Dns::reset_for_test();
IMAPIDLE::Dns::configure(100, 200);
IMAPIDLE::Dns::open_cache(':memory:');
IMAPIDLE::Dns::resolver(SeqDns->new(sub {
    my ($host, $type) = @_;
    return [{ done => 0, cond => 'read', fd => 6, timeout_ms => 9000 }]
        unless $type eq 'A';
    return [{ done => 1, rcode => 0, packet => dns_pkt(
        qname => $host,
        a     => [{ ip => '192.0.2.51', ttl => 1000 }],
    ) }];
}));
IMAPIDLE::Dns::addresses('capped.example', $now);
is(IMAPIDLE::Dns::row('capped.example')->{v4_expires}, $now + 200,
    'max_ttl caps a longer remote TTL');

IMAPIDLE::Dns::reset_for_test();
IMAPIDLE::Dns::configure(86400, undef);
IMAPIDLE::Dns::open_cache(':memory:');
my $fast_pkt = dns_pkt(
    qname => 'fast.example',
    a     => [{ ip => '192.0.2.1', ttl => 300 }],
);
my $slow_pkt = dns_pkt(
    qname => 'slow.example',
    a     => [{ ip => '192.0.2.2', ttl => 300 }],
);
IMAPIDLE::Dns::resolver(SeqDns->new(sub {
    my ($host, $type) = @_;
    if ($host eq 'fast.example' && $type eq 'A') {
        return [{ done => 1, rcode => 0, packet => $fast_pkt }];
    }
    if ($host eq 'slow.example' && $type eq 'A') {
        return [
            { done => 0, cond => 'read', fd => 9, timeout_ms => 5000 },
            { done => 1, rcode => 0, packet => $slow_pkt },
        ];
    }
    if ($host eq 'slow.example') {
        return [{ done => 0, cond => 'write', fd => 11, timeout_ms => 1500 }];
    }
    return [{ done => 0, cond => 'read', fd => 8, timeout_ms => 8000 }];
}));
my $fast = IMAPIDLE::Dns::addresses('fast.example', $now);
my $slow = IMAPIDLE::Dns::addresses('slow.example', $now);
is_deeply($fast, ['192.0.2.1'], 'a name that has answered is usable');
ok(!defined $slow, 'a name that has not answered does not block the other');
my $watch = IMAPIDLE::Dns::watch();
ok((grep { $_ == 11 } @{ $watch->{write} }), 'a query that wants to write is watched');
ok((grep { $_ == 9 } @{ $watch->{read} }), 'a query that wants to read is watched');
ok(defined $watch->{timeout} && $watch->{timeout} <= 1.5,
    'the soonest resolver timeout shortens the wait');
my $rin = '';
vec($rin, 9, 1) = 1;
IMAPIDLE::Dns::ready($rin, '', 1);
is_deeply(IMAPIDLE::Dns::addresses('slow.example', $now), ['192.0.2.2'],
    'the slow name is usable once its reply arrives');
ok(!defined IMAPIDLE::Dns::addresses('still.example', $now),
    'a third name can still be waiting');

IMAPIDLE::Dns::reset_for_test();
IMAPIDLE::Dns::configure(86400, undef);
IMAPIDLE::Dns::open_cache(':memory:');
my $nxpkt = dns_pkt(
    qname => 'gone.example',
    rcode => 3,
    soa   => { ttl => 100, minimum => 40 },
);
my $nxbare = dns_pkt(qname => 'bare.example', rcode => 3);
my $shortsoa = dns_pkt(
    qname => 'tiny.example',
    rcode => 3,
    soa   => { ttl => 10, minimum => 10 },
);
IMAPIDLE::Dns::resolver(SeqDns->new(sub {
    my ($host, $type) = @_;
    my $pkt = $host eq 'bare.example' ? $nxbare
            : $host eq 'tiny.example' ? $shortsoa
            : $nxpkt;
    return [{ done => 1, rcode => 3, packet => $pkt }];
}));
ok(!defined IMAPIDLE::Dns::addresses('gone.example', $now), 'NXDOMAIN does not spawn');
my $gone = IMAPIDLE::Dns::row('gone.example');
is($gone->{negative}, 1, 'NXDOMAIN is stored');
is($gone->{negative_ttl}, 40, 'the SOA negative TTL is stored');
is($gone->{retry_at}, $now + 30, 'the first negative wait is 30 seconds');
ok(!defined IMAPIDLE::Dns::addresses('gone.example', $now + 10),
    'the name stays negative during the wait');
ok(!defined IMAPIDLE::Dns::addresses('gone.example', $now + 30),
    'the retry is another NXDOMAIN');
is(IMAPIDLE::Dns::row('gone.example')->{retry_at}, $now + 30 + 40,
    'the second wait stops at the SOA negative TTL');

ok(!defined IMAPIDLE::Dns::addresses('bare.example', $now), 'NXDOMAIN without SOA does not spawn');
is(IMAPIDLE::Dns::row('bare.example')->{retry_at}, $now + 30,
    'no SOA still waits 30 seconds first');
ok(!defined IMAPIDLE::Dns::row('bare.example')->{negative_ttl},
    'no SOA stores no negative TTL');

ok(!defined IMAPIDLE::Dns::addresses('tiny.example', $now));
is(IMAPIDLE::Dns::row('tiny.example')->{negative_ttl}, 10,
    'a short SOA negative TTL is recorded');
is(IMAPIDLE::Dns::row('tiny.example')->{retry_at}, $now + 30,
    'a negative TTL under 30 seconds still waits 30');

IMAPIDLE::Dns::reset_for_test();
IMAPIDLE::Dns::configure(86400, undef);
IMAPIDLE::Dns::open_cache(':memory:');
my $only4 = dns_pkt(
    qname => 'v4.example',
    a     => [{ ip => '192.0.2.4', ttl => 300 }],
);
my $nd6 = dns_pkt(
    qname => 'v4.example',
    rcode => 0,
    soa   => { ttl => 500, minimum => 500 },
);
IMAPIDLE::Dns::resolver(SeqDns->new(sub {
    my ($host, $type) = @_;
    if ($type eq 'A') {
        return [{ done => 1, rcode => 0, packet => $only4 }];
    }
    return [{ done => 1, rcode => 0, packet => $nd6 }];
}));
is_deeply(IMAPIDLE::Dns::addresses('v4.example', $now), ['192.0.2.4'],
    'NODATA for AAAA leaves the A addresses in use');
ok(!IMAPIDLE::Dns::row('v4.example')->{negative}, 'one empty family is not a negative name');
ok(IMAPIDLE::Dns::row('v4.example')->{v6_empty}, 'the empty family is recorded');
is(IMAPIDLE::Dns::row('v4.example')->{v6_retry}, $now + 30,
    'the empty family waits 30 seconds before another query');

IMAPIDLE::Dns::reset_for_test();
IMAPIDLE::Dns::configure(0, undef);
IMAPIDLE::Dns::open_cache(':memory:');
my $hold_n = 0;
IMAPIDLE::Dns::resolver(SeqDns->new(sub {
    my ($host, $type) = @_;
    if ($type eq 'A') {
        $hold_n++;
        if ($hold_n == 1) {
            return [{ done => 1, rcode => 0, packet => dns_pkt(
                qname => 'hold.example',
                a     => [{ ip => '192.0.2.6', ttl => 10 }],
            ) }];
        }
        return [{ done => 1, timeout => 1, rcode => -1 }];
    }
    return [{ done => 0, cond => 'read', fd => 4, timeout_ms => 9000 }];
}));
is_deeply(IMAPIDLE::Dns::addresses('hold.example', 1000), ['192.0.2.6'],
    'the first answer is stored');
is(IMAPIDLE::Dns::row('hold.example')->{v4_expires}, 1010, 'min_ttl 0 keeps the remote TTL');
is_deeply(IMAPIDLE::Dns::addresses('hold.example', 1011), ['192.0.2.6'],
    'a timeout leaves the previous answer in place');
is($hold_n, 2, 'the refresh was attempted once');
is_deeply(IMAPIDLE::Dns::addresses('hold.example', 1012), ['192.0.2.6'],
    'the failed refresh is not repeated immediately');
is($hold_n, 2, 'the backoff holds the next query');

require './imapidle';

my $confdir = tempdir('imapidle-dnsconf-XXXX', CLEANUP => 1, TMPDIR => 1);
my $conf_n = 0;
sub conf {
    my ($extra) = @_;
    $conf_n++;
    my $path = "$confdir/$conf_n.conf";
    open my $fh, '>', $path or die $!;
    print $fh <<'EOF';
[srv]
type = server
host = mail.example.com

[box]
type = account
server = srv
user = a@example.com
pass = secret

[watch]
type = idle
channel = box
folder0 = INBOX
EOF
    print $fh $extra if defined $extra && $extra ne '';
    close $fh;
    return $path;
}

is(load_config(conf('')), '', 'a config without dns loads');
is(dns_limits_for_test()->{min_ttl}, 86400, 'min_ttl defaults to a day');
ok(!defined dns_limits_for_test()->{max_ttl}, 'max_ttl is unset unless configured');

is(load_config(conf("[dns]\ntype = dns\nmin_ttl =\nmax_ttl =\n")), '',
    'empty dns values load');
is(dns_limits_for_test()->{min_ttl}, 86400, 'an empty min_ttl keeps the default');
ok(!defined dns_limits_for_test()->{max_ttl}, 'an empty max_ttl stays unset');

is(load_config(conf("[dns]\ntype = dns\nmin_ttl = 100\nmax_ttl = 200\n")), '',
    'dns limits load');
is(dns_limits_for_test()->{min_ttl}, 100, 'min_ttl is stored');
is(dns_limits_for_test()->{max_ttl}, 200, 'max_ttl is stored');

like(load_config(conf("[dns]\ntype = dns\nmin_ttl = no\n")), qr/bad min_ttl/,
    'a min_ttl that is not an integer is rejected');
like(load_config(conf("[dns]\ntype = dns\nmin_ttl = 20\nmax_ttl = 10\n")),
    qr/max_ttl below min_ttl/, 'max_ttl below min_ttl is rejected');
like(load_config(conf("[dns]\ntype = dns\n\n[more]\ntype = dns\n")),
    qr/second dns section/, 'a second dns section is rejected');

require IMAPIDLE::Split;
IMAPIDLE::Dns::reset_for_test();
IMAPIDLE::Dns::configure(86400, undef);
IMAPIDLE::Dns::open_cache(':memory:');
IMAPIDLE::Dns::resolver(SeqDns->new(sub {
    my ($host, $type) = @_;
    if ($host eq 'slow.example' && $type eq 'A') {
        return [
            { done => 0, cond => 'read', fd => 9, timeout_ms => 5000 },
            { done => 1, rcode => 0, packet => dns_pkt(
                qname => 'slow.example',
                a     => [{ ip => '192.0.2.2', ttl => 300 }],
            ) },
        ];
    }
    return [{ done => 0, cond => 'read', fd => 8, timeout_ms => 8000 }];
}));
my $up = FakeUp->new;
my %jobs = (
    a => {
        kind => 'idle', id => 'a', account => 'box', folder => 'INBOX',
        host => 'slow.example', up => 0, restart_at => 0,
    },
    b => {
        kind => 'idle', id => 'b', account => 'box', folder => 'Other',
        host => '127.0.0.1', up => 0, restart_at => 0,
    },
);
IMAPIDLE::Split::_dry_spawn($up, time(), \%jobs);
is(scalar @{ $up->{sent} }, 1, 'a literal address is spawned while a name waits');
my $sent = JSON::PP::decode_json($up->{sent}[0]);
is($sent->{id}, 'b', 'the spawned job is the literal host');
is_deeply($jobs{b}{addrs}, ['127.0.0.1'], 'the literal host is its own address');
ok(!defined $jobs{a}{addrs}, 'the waiting name has no addresses yet');
my $rin2 = '';
vec($rin2, 9, 1) = 1;
IMAPIDLE::Dns::ready($rin2, '', 1);
IMAPIDLE::Split::_dry_spawn($up, time(), \%jobs);
is(scalar @{ $up->{sent} }, 2, 'the name is spawned once it has an address');
is_deeply($jobs{a}{addrs}, ['192.0.2.2'], 'the worker is given the resolved address');

done_testing;

sub name_wire {
    my ($name) = @_;
    my $wire = '';
    for my $lab (split /\./, $name) {
        $wire .= pack('C/a*', $lab);
    }
    return $wire . "\0";
}

sub dns_pkt {
    my (%o) = @_;
    my $qname = $o{qname} // 'example.com';
    my $flags = 0x8400 | ($o{rcode} // 0);
    my $q = name_wire($qname) . pack('nn', $o{qtype} // 1, 1);
    my $an = '';
    my $anc = 0;
    for my $a (@{ $o{a} // [] }) {
        $anc++;
        $an .= name_wire($qname)
            . pack('nnNn', 1, 1, $a->{ttl} // 300, 4)
            . pack('C4', split /\./, $a->{ip});
    }
    for my $a (@{ $o{aaaa} // [] }) {
        $anc++;
        my $bin = inet_pton(AF_INET6, $a->{ip}) or die "aaaa $a->{ip}";
        $an .= name_wire($qname)
            . pack('nnNn', 28, 1, $a->{ttl} // 300, 16)
            . $bin;
    }
    my $ns = '';
    my $nsc = 0;
    if ($o{soa}) {
        $nsc = 1;
        my $rdata = name_wire('ns.example.com')
            . name_wire('hostmaster.example.com')
            . pack('N5', 1, 1000, 1000, 1000, $o{soa}{minimum});
        $ns = name_wire($qname)
            . pack('nnNn', 6, 1, $o{soa}{ttl}, length($rdata))
            . $rdata;
    }
    return pack('nnnnnn', 1, $flags, 1, $anc, $nsc, 0) . $q . $an . $ns;
}

# Question name at offset 12, answer name is a pointer back to it.
sub dns_pkt_pointer {
    my $qname = name_wire('example.com');
    my $q = $qname . pack('nn', 1, 1);
    my $an = pack('n', 0xC00C)
        . pack('nnNn', 1, 1, 60, 4)
        . pack('C4', split /\./, '192.0.2.10');
    return pack('nnnnnn', 1, 0x8400, 1, 1, 0, 0) . $q . $an;
}

package SeqDns;

sub new {
    my ($class, $cb) = @_;
    return bless { cb => $cb }, $class;
}

sub search {
    my ($self, $host, $type) = @_;
    my $steps = $self->{cb}->($host, $type);
    return SeqQuery->new($steps);
}

package SeqQuery;

sub new {
    my ($class, $steps) = @_;
    return bless { steps => [@$steps] }, $class;
}

sub run {
    my ($self) = @_;
    my $step = shift @{ $self->{steps} };
    $step = { done => 1, timeout => 1, rcode => -1 } unless $step;
    return $step;
}

package FakeUp;

sub new {
    return bless { sent => [] }, $_[0];
}

sub send {
    my ($self, $type, $payload) = @_;
    push @{ $self->{sent} }, $payload;
    return;
}
