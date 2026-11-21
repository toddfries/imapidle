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

package IMAPIDLE;

use strict;
use warnings;

use JSON::PP ();

use constant {
	IMSG_ACK      => 1,
	IMSG_SHUTDOWN => 2,
	IMSG_ATTACH   => 3,
	IMSG_MAIL     => 4,
	IMSG_SOCKET   => 5,
	IMSG_SPAWN    => 6,
	IMSG_LOGIN    => 7,
	IMSG_READY    => 8,
	IMSG_DROP     => 9,
	IMSG_PROBE    => 10,
	IMSG_COUNT    => 11,
	IMSG_MAX      => 262144,
};

my $JSON = JSON::PP->new->utf8->canonical->allow_nonref;

sub json_encode {
	my ($data) = @_;
	return $JSON->encode($data);
}

sub json_decode {
	my ($bytes) = @_;
	return undef if !defined $bytes || $bytes eq '';
	return $JSON->decode($bytes);
}

1;
