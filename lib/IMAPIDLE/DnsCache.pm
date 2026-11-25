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

# tie %dns, 'IMAPIDLE::DnsCache', $path
# The hash in this process is the copy the hub reads. A store writes
# the row through. $dns{$host} = undef calls STORE, so that removes
# the row too.

package IMAPIDLE::DnsCache;

use strict;
use warnings;

use IMAPIDLE ();

sub TIEHASH {
	my ($class, $path) = @_;
	die "dns cache path\n" if !defined $path || $path eq '';
	require DBI;
	my $old = umask 077;
	my $dbh = eval {
	    DBI->connect(
		"dbi:SQLite:dbname=$path", '', '',
		{ RaiseError => 1, PrintError => 0, AutoCommit => 1 },
	    );
	};
	my $err = $@;
	umask $old;
	die $err if !defined $dbh;
	$dbh->do(<<'SQL');
CREATE TABLE IF NOT EXISTS host (
    host TEXT PRIMARY KEY,
    body TEXT NOT NULL
)
SQL
	if ($path ne ':memory:' && -f $path) {
		chmod 0600, $path;
	}
	my $cache = {};
	my $sth = $dbh->prepare('SELECT host, body FROM host');
	$sth->execute;
	while (my ($host, $body) = $sth->fetchrow_array) {
		my $row = eval { IMAPIDLE::json_decode($body) };
		$cache->{$host} = $row if ref $row eq 'HASH';
	}
	$sth->finish;
	return bless {
		dbh   => $dbh,
		path  => $path,
		cache => $cache,
		iter  => [],
	}, $class;
}

sub FETCH {
	my ($self, $key) = @_;
	$key = _key($key);
	return if $key eq '' || !exists $self->{cache}{$key};
	return IMAPIDLE::json_decode(IMAPIDLE::json_encode($self->{cache}{$key}));
}

# Assignment of undef is a delete. Perl does not call DELETE for it.
sub STORE {
	my ($self, $key, $val) = @_;
	$key = _key($key);
	return if $key eq '';
	if (!defined $val) {
		$self->DELETE($key);
		return;
	}
	return if ref $val ne 'HASH';
	my $body = IMAPIDLE::json_encode($val);
	$self->{dbh}->do(
	    'INSERT OR REPLACE INTO host (host, body) VALUES (?, ?)',
	    undef, $key, $body,
	);
	$self->{cache}{$key} = IMAPIDLE::json_decode($body);
	return;
}

sub DELETE {
	my ($self, $key) = @_;
	$key = _key($key);
	return if $key eq '';
	$self->{dbh}->do('DELETE FROM host WHERE host = ?', undef, $key);
	return delete $self->{cache}{$key};
}

sub EXISTS {
	my ($self, $key) = @_;
	$key = _key($key);
	return $key ne '' && exists $self->{cache}{$key};
}

sub CLEAR {
	my ($self) = @_;
	$self->{dbh}->do('DELETE FROM host');
	$self->{cache} = {};
	$self->{iter} = [];
	return;
}

sub FIRSTKEY {
	my ($self) = @_;
	$self->{iter} = [sort keys %{ $self->{cache} }];
	return $self->NEXTKEY;
}

sub NEXTKEY {
	my ($self) = @_;
	return shift @{ $self->{iter} };
}

sub SCALAR {
	my ($self) = @_;
	return scalar keys %{ $self->{cache} };
}

sub UNTIE { $_[0]->DESTROY }

sub DESTROY {
	my ($self) = @_;
	return unless $self && $self->{dbh};
	eval { $self->{dbh}->disconnect };
	delete $self->{dbh};
	return;
}

sub _key {
	my ($key) = @_;
	$key = '' unless defined $key;
	$key =~ s/^\s+|\s+$//g;
	$key =~ s/\.\z//;
	return lc $key;
}

1;
