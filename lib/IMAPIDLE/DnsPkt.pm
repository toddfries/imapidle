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

# A DNS reply, enough of it to read address TTLs and the SOA that
# carries a negative TTL. A short or crooked packet is undef.

package IMAPIDLE::DnsPkt;

use strict;
use warnings;

use Socket qw(AF_INET6 inet_ntop);

sub summarize {
	my ($pkt, $type) = @_;
	my $d = decode($pkt);
	return unless $d;
	my $want = (defined $type && $type eq 'AAAA') ? 28 : 1;
	my (@addr, $ttl);
	for my $rr (@{ $d->{answers} }) {
		next if ($rr->{type} // -1) != $want || ($rr->{class} // -1) != 1;
		next unless defined $rr->{addr} && $rr->{addr} ne '';
		push @addr, $rr->{addr};
		my $rt = $rr->{ttl} // 0;
		$ttl = $rt if !defined $ttl || $rt < $ttl;
	}
	my $neg;
	for my $rr (@{ $d->{authority} }) {
		next unless ($rr->{type} // -1) == 6 && defined $rr->{minimum};
		my $n = $rr->{ttl} // 0;
		$n = $rr->{minimum} if $rr->{minimum} < $n;
		$neg = $n if !defined $neg || $n < $neg;
	}
	return {
		rcode        => $d->{rcode},
		truncated    => $d->{truncated} ? 1 : 0,
		addrs        => \@addr,
		ttl          => $ttl,
		negative_ttl => $neg,
	};
}

sub decode {
	my ($pkt) = @_;
	return if !defined $pkt || length($pkt) < 12;
	my ($flags, $qd, $an, $ns) = unpack('x2 n n n n', $pkt);
	my $off = 12;
	for (1 .. $qd) {
		(undef, $off) = _name($pkt, $off);
		return if !defined $off || $off + 4 > length($pkt);
		$off += 4;
	}
	my @answers;
	$off = _rrs($pkt, $off, $an, \@answers);
	return if !defined $off;
	my @auth;
	$off = _rrs($pkt, $off, $ns, \@auth);
	return if !defined $off;
	return {
		rcode     => $flags & 0xf,
		truncated => ($flags & 0x0200) ? 1 : 0,
		answers   => \@answers,
		authority => \@auth,
	};
}

sub _rrs {
	my ($pkt, $off, $count, $out) = @_;
	return $off if $count < 0;
	for (1 .. $count) {
		my ($name, $next) = _name($pkt, $off);
		return if !defined $next || $next + 10 > length($pkt);
		my ($type, $class, $ttl, $rdlen) = unpack('nnNn', substr($pkt, $next, 10));
		my $rd = $next + 10;
		return if $rdlen < 0 || $rd + $rdlen > length($pkt);
		my $rr = {
			name  => $name,
			type  => $type,
			class => $class,
			ttl   => $ttl,
		};
		if ($type == 1 && $rdlen == 4) {
			$rr->{addr} = join('.', unpack('C4', substr($pkt, $rd, 4)));
		} elsif ($type == 28 && $rdlen == 16) {
			my $ip = eval { inet_ntop(AF_INET6, substr($pkt, $rd, 16)) };
			$rr->{addr} = $ip if defined $ip && $ip ne '';
		} elsif ($type == 6) {
			my (undef, $p) = _name($pkt, $rd);
			return if !defined $p;
			(undef, $p) = _name($pkt, $p);
			return if !defined $p;
			if ($p + 20 <= $rd + $rdlen) {
				$rr->{minimum} = (unpack('x16 N', substr($pkt, $p, 20)));
			}
		}
		push @$out, $rr;
		$off = $rd + $rdlen;
	}
	return $off;
}

# $end is the offset just past this name in the packet. A compression
# pointer does not move that cursor to the place it points at.
sub _name {
	my ($pkt, $off, $depth) = @_;
	$depth //= 0;
	return if $depth > 16 || $off < 0 || $off >= length($pkt);
	my @lab;
	my $guard = 0;
	while ($guard++ < 128) {
		return if $off >= length($pkt);
		my $len = ord(substr($pkt, $off, 1));
		if (($len & 0xc0) == 0xc0) {
			return if $off + 1 >= length($pkt);
			my $ptr = (($len & 0x3f) << 8) | ord(substr($pkt, $off + 1, 1));
			return if $ptr < 0 || $ptr >= length($pkt);
			my ($rest) = _name($pkt, $ptr, $depth + 1);
			return if !defined $rest;
			push @lab, $rest if $rest ne '';
			return (join('.', @lab), $off + 2);
		}
		return if $len & 0xc0;
		if ($len == 0) {
			return (join('.', @lab), $off + 1);
		}
		return if $off + 1 + $len > length($pkt);
		push @lab, substr($pkt, $off + 1, $len);
		$off += 1 + $len;
	}
	return;
}

1;
