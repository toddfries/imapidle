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

# One A query and one AAAA query per name. A name that already has an
# address is usable while the other family is still out. The resolver
# object is replaced in tests; the hub uses IMAPIDLE::Asr.

package IMAPIDLE::Dns;

use strict;
use warnings;

use Socket qw(AF_INET AF_INET6 inet_pton);
use Time::HiRes ();

use IMAPIDLE::DnsCache ();
use IMAPIDLE::DnsPkt ();

my $MIN = 86400;
my $MAX;
my $TIED = 0;
my %MEM;
my $RES;
my %Q;
my %SOFT;
my %SHOWN;

sub configure {
	my ($min, $max) = @_;
	$MIN = defined $min ? $min + 0 : 86400;
	$MIN = 0 if $MIN < 0;
	if (defined $max) {
		$MAX = $max + 0;
		$MAX = 0 if $MAX < 0;
	} else {
		$MAX = undef;
	}
	return;
}

sub open_cache {
	my ($path) = @_;
	if ($TIED) {
		untie %MEM;
		$TIED = 0;
		%MEM = ();
	}
	tie %MEM, 'IMAPIDLE::DnsCache', $path;
	$TIED = 1;
	return;
}

sub resolver {
	my ($obj) = @_;
	$RES = $obj if @_;
	return $RES;
}

sub reset_for_test {
	_drop_flight();
	%SOFT = ();
	%SHOWN = ();
	if ($TIED) {
		untie %MEM;
	}
	%MEM = ();
	$TIED = 0;
	$RES = undef;
	configure(86400, undef);
	return;
}

sub addresses {
	my ($host, $now) = @_;
	$now //= time();
	my $lit = _literal($host);
	return [$lit] if defined $lit;
	return unless $TIED;
	my $key = _key($host);
	return if $key eq '';
	_kick($key, $now);
	return _usable($MEM{$key});
}

sub row {
	my ($host) = @_;
	return unless $TIED;
	my $key = _key($host);
	return if $key eq '';
	return $MEM{$key};
}

sub invalidate {
	my ($host, $now) = @_;
	$now //= time();
	return if defined _literal($host);
	return unless $TIED;
	my $key = _key($host);
	return if $key eq '';
	$MEM{$key} = undef;
	delete $SOFT{$key};
	delete $SHOWN{$key};
	_drop_flight($key);
	_start($key, 'A', $now);
	_start($key, 'AAAA', $now);
	return;
}

# fds for the hub wait, and how soon the next query or retry is due.
sub watch {
	my ($now) = @_;
	$now //= Time::HiRes::time();
	my (@read, @write, $soon);
	for my $slot (values %Q) {
		if (defined $slot->{fd}) {
			if (($slot->{cond} // '') eq 'write') {
				push @write, $slot->{fd};
			} else {
				push @read, $slot->{fd};
			}
		}
		if (defined $slot->{deadline}) {
			my $left = $slot->{deadline} - $now;
			$left = 0 if $left < 0;
			$soon = $left if !defined $soon || $left < $soon;
		}
	}
	if ($TIED) {
		for my $key (keys %MEM) {
			my $row = $MEM{$key};
			next unless ref $row eq 'HASH';
			for my $when (
			    $row->{retry_at}, $row->{v4_retry}, $row->{v6_retry},
			    $row->{v4_refresh}, $row->{v6_refresh},
			) {
				next unless defined $when && $when > $now;
				my $left = $when - $now;
				$soon = $left if !defined $soon || $left < $soon;
			}
		}
	}
	for my $soft (values %SOFT) {
		next unless defined $soft->{retry_at} && $soft->{retry_at} > $now;
		my $left = $soft->{retry_at} - $now;
		$soon = $left if !defined $soon || $left < $soon;
	}
	return { read => \@read, write => \@write, timeout => $soon };
}

# $n is the pselect result. A negative $n is a signal, not a timeout.
sub ready {
	my ($rin, $win, $n, $now) = @_;
	return if !defined $n || $n < 0;
	$now //= Time::HiRes::time();
	my @due;
	for my $id (keys %Q) {
		my $slot = $Q{$id} or next;
		my $fd = $slot->{fd};
		my $bit = 0;
		if (defined $fd && $n > 0) {
			$bit = 1 if defined $rin && vec($rin, $fd, 1);
			$bit = 1 if defined $win && vec($win, $fd, 1);
		}
		my $timed = defined $slot->{deadline} && $slot->{deadline} <= $now + 0.001;
		next unless $bit || $timed;
		push @due, $id;
	}
	_pump($_, $now) for @due;
	return;
}

sub _kick {
	my ($key, $now) = @_;
	my $row = $MEM{$key};
	if (ref $row eq 'HASH' && $row->{negative}) {
		return if ($row->{retry_at} // 0) > $now;
		_start($key, 'A', $now);
		_start($key, 'AAAA', $now);
		return;
	}
	if (!_usable($row)) {
		my $soft = $SOFT{$key};
		if ($soft && ($soft->{retry_at} // 0) > $now) {
			return;
		}
	}
	for my $type (qw(A AAAA)) {
		my $fam = $type eq 'AAAA' ? 'v6' : 'v4';
		my $have = _family($row, $fam);
		if ($have) {
			my $refresh = $row->{"${fam}_refresh"} // 0;
			next if $refresh > $now;
			my $exp = $row->{"${fam}_expires"};
			next if defined $exp && $exp > $now;
			_start($key, $type, $now);
			next;
		}
		if (ref $row eq 'HASH' && $row->{"${fam}_empty"}) {
			next if ($row->{"${fam}_retry"} // 0) > $now;
		}
		_start($key, $type, $now);
	}
	return;
}

sub _start {
	my ($key, $type, $now) = @_;
	my $id = "$key\n$type";
	return if $Q{$id};
	my $res = $RES;
	if (!$res) {
		require IMAPIDLE::Asr;
		$res = 'IMAPIDLE::Asr';
	}
	my $q = eval { $res->search($key, $type) };
	if (!$q) {
		_note_fail($key, $type, $now);
		return;
	}
	$Q{$id} = {
		query    => $q,
		host     => $key,
		type     => $type,
		deadline => $now + 30,
	};
	_pump($id, $now);
	return;
}

sub _pump {
	my ($id, $now) = @_;
	my $slot = $Q{$id} or return;
	$now //= time();
	my $st = eval { $slot->{query}->run };
	if (!$st || $@) {
		my $host = $slot->{host};
		my $type = $slot->{type};
		_drop_one($id);
		_note_fail($host, $type, $now);
		return;
	}
	if (!$st->{done}) {
		$slot->{fd} = $st->{fd};
		$slot->{cond} = ($st->{cond} // '') eq 'write' ? 'write' : 'read';
		my $ms = $st->{timeout_ms};
		$ms = 30000 if !defined $ms || $ms < 0;
		$slot->{deadline} = Time::HiRes::time() + ($ms / 1000);
		return;
	}
	my $host = $slot->{host};
	my $type = $slot->{type};
	_drop_one($id);
	_apply($host, $type, $st, $now);
	return;
}

sub _apply {
	my ($key, $type, $st, $now) = @_;
	if ($st->{timeout} || !defined $st->{packet} || ($st->{rcode} // -1) < 0) {
		_note_fail($key, $type, $now);
		return;
	}
	my $sum = IMAPIDLE::DnsPkt::summarize($st->{packet}, $type);
	if (!$sum || $sum->{truncated}) {
		_note_fail($key, $type, $now);
		return;
	}
	my $rcode = $sum->{rcode};
	if ($rcode != 0 && $rcode != 3 && !@{ $sum->{addrs} }) {
		_note_fail($key, $type, $now);
		return;
	}
	if (@{ $sum->{addrs} }) {
		_note_positive($key, $type, $sum, $now);
		return;
	}
	if ($rcode == 3) {
		_note_nxdomain($key, $type, $sum->{negative_ttl}, $now);
		return;
	}
	if ($rcode == 0 && defined $sum->{negative_ttl}) {
		_note_nodata($key, $type, $sum->{negative_ttl}, $now);
		return;
	}
	_note_fail($key, $type, $now);
	return;
}

sub _note_positive {
	my ($key, $type, $sum, $now) = @_;
	my $fam = $type eq 'AAAA' ? 'v6' : 'v4';
	my $row = $MEM{$key};
	$row = {} unless ref $row eq 'HASH';
	delete $row->{negative};
	delete $row->{negative_ttl};
	delete $row->{retry_at};
	delete $row->{fails};
	delete $SOFT{$key};
	my $keep = _clamp($sum->{ttl});
	$row->{$fam} = [@{ $sum->{addrs} }];
	$row->{"${fam}_expires"} = $now + $keep;
	$row->{"${fam}_ttl"} = $sum->{ttl} // 0;
	delete $row->{"${fam}_empty"};
	delete $row->{"${fam}_retry"};
	delete $row->{"${fam}_fails"};
	delete $row->{"${fam}_refresh"};
	$MEM{$key} = $row;
	_announce($key);
	return;
}

sub _note_nxdomain {
	my ($key, $type, $soa, $now) = @_;
	my $before = $MEM{$key};
	# The family that missed stays empty, so an address from the other
	# family does not start this query again on the next lap.
	_note_empty($key, $type, $soa, $now);
	if (_usable($before)) {
		return;
	}
	if (ref $before eq 'HASH' && $before->{negative}
	    && ($before->{retry_at} // 0) > $now) {
		return;
	}
	my $row = $MEM{$key};
	$row = {} unless ref $row eq 'HASH';
	my $fails = (ref $before eq 'HASH' ? ($before->{fails} // 0) : 0) + 1;
	my $wait = _delay($fails, $soa, $MIN);
	$row->{negative} = 1;
	$row->{retry_at} = $now + $wait;
	$row->{fails} = $fails;
	if (defined $soa) {
		$row->{negative_ttl} = $soa + 0;
	} else {
		delete $row->{negative_ttl};
	}
	$MEM{$key} = $row;
	delete $SOFT{$key};
	if ($fails == 1) {
		my $who = defined $soa ? "soa ${soa}s" : 'no soa';
		_say("dns: $key nxdomain, retry in ${wait}s, $who");
	}
	return;
}

sub _note_nodata {
	my ($key, $type, $soa, $now) = @_;
	my $row = $MEM{$key};
	if (ref $row eq 'HASH' && $row->{negative} && !_usable($row)) {
		return;
	}
	_note_empty($key, $type, $soa, $now);
	return;
}

sub _note_empty {
	my ($key, $type, $soa, $now) = @_;
	my $fam = $type eq 'AAAA' ? 'v6' : 'v4';
	my $row = $MEM{$key};
	$row = {} unless ref $row eq 'HASH';
	my $fails = ($row->{"${fam}_fails"} // 0) + 1;
	my $wait = _delay($fails, $soa, $MIN);
	$row->{$fam} = [];
	$row->{"${fam}_empty"} = 1;
	$row->{"${fam}_fails"} = $fails;
	$row->{"${fam}_retry"} = $now + $wait;
	delete $row->{"${fam}_expires"};
	delete $row->{"${fam}_refresh"};
	$MEM{$key} = $row;
	return;
}

sub _note_fail {
	my ($key, $type, $now) = @_;
	my $fam = $type eq 'AAAA' ? 'v6' : 'v4';
	my $row = $MEM{$key};
	if (ref $row eq 'HASH' && $row->{negative}) {
		my $fails = ($row->{fails} // 0) + 1;
		$row->{fails} = $fails;
		$row->{retry_at} = $now + _delay($fails, undef, $MIN);
		$MEM{$key} = $row;
		return;
	}
	if (_usable($row)) {
		$row = {} unless ref $row eq 'HASH';
		my $fails = ($row->{"${fam}_fails"} // 0) + 1;
		$row->{"${fam}_fails"} = $fails;
		$row->{"${fam}_refresh"} = $now + _delay($fails, undef, $MIN);
		$MEM{$key} = $row;
		delete $SOFT{$key};
		return;
	}
	my $fails = ($SOFT{$key}{fails} // 0) + 1;
	$SOFT{$key} = {
		fails    => $fails,
		retry_at => $now + _delay($fails, undef, $MIN),
	};
	return;
}

sub _announce {
	my ($key) = @_;
	my @a = @{ _usable($MEM{$key}) // [] };
	my $shown = join(' ', @a);
	return if $shown eq '' || ($SHOWN{$key} // '') eq $shown;
	$SHOWN{$key} = $shown;
	_say("dns: $key $shown");
	return;
}

sub _say {
	my ($msg) = @_;
	return unless defined &main::log_info;
	eval { main::log_info($msg); 1 };
	return;
}

sub _usable {
	my ($row) = @_;
	return unless ref $row eq 'HASH';
	return if $row->{negative};
	my @a;
	push @a, @{ $row->{v4} } if ref $row->{v4} eq 'ARRAY';
	push @a, @{ $row->{v6} } if ref $row->{v6} eq 'ARRAY';
	@a = grep { defined $_ && $_ ne '' } @a;
	return @a ? \@a : undef;
}

sub _family {
	my ($row, $fam) = @_;
	return 0 unless ref $row eq 'HASH' && ref $row->{$fam} eq 'ARRAY';
	return grep { defined $_ && $_ ne '' } @{ $row->{$fam} } ? 1 : 0;
}

sub _clamp {
	my ($ttl) = @_;
	$ttl = 0 if !defined $ttl || $ttl < 0;
	$ttl = $MIN if $ttl < $MIN;
	$ttl = $MAX if defined $MAX && $ttl > $MAX;
	return $ttl;
}

# First wait is 30s. Each miss doubles. The ceiling is the SOA negative
# TTL when the server sent one, and min_ttl when it did not. A ceiling
# under 30s stays at 30s.
sub _delay {
	my ($fails, $soa, $min) = @_;
	$fails = 1 if !defined $fails || $fails < 1;
	my $wait = 30;
	for (my $i = 1; $i < $fails; $i++) {
		last if $wait >= 1_073_741_824;
		$wait *= 2;
	}
	my $cap;
	if (defined $soa) {
		$cap = $soa < 30 ? 30 : $soa;
	} else {
		$cap = defined $min ? $min : $MIN;
		$cap = 30 if $cap < 30;
	}
	$wait = $cap if $wait > $cap;
	$wait = 30 if $wait < 30;
	return $wait;
}

sub _drop_flight {
	my ($key) = @_;
	for my $id (keys %Q) {
		next if defined $key && $Q{$id}{host} ne $key;
		_drop_one($id);
	}
	return;
}

sub _drop_one {
	my ($id) = @_;
	delete $Q{$id};
	return;
}

sub _literal {
	my ($host) = @_;
	return if !defined $host || $host eq '';
	my $h = $host;
	$h =~ s/^\[(.*)\]\z/$1/;
	return if $h eq '';
	return $h if defined inet_pton(AF_INET, $h);
	return $h if defined inet_pton(AF_INET6, $h);
	return;
}

sub _key {
	my ($host) = @_;
	$host = '' unless defined $host;
	$host =~ s/^\s+|\s+$//g;
	$host =~ s/\.\z//;
	return lc $host;
}

1;
