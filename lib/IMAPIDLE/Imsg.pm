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

package IMAPIDLE::Imsg;

use strict;
use warnings;

use POSIX ();
use IMAPIDLE ();
use XSLoader;

XSLoader::load('IMAPIDLE::Imsg');

sub open {
	my ($class, $fd) = @_;
	my $self = $class->new($fd + 0);
	$self->allow_fdpass;
	my $rc = $self->set_maxsize(IMAPIDLE::IMSG_MAX);
	die "imsgbuf_set_maxsize failed\n" if !defined $rc || $rc < 0;
	return $self;
}

sub _flush_block {
	my ($self) = @_;
	my $rc = $self->flush;
	die "imsgbuf_flush: $!\n" if !defined $rc || $rc != 0;
	return;
}

sub send {
	my ($self, $type, $payload) = @_;
	$payload = '' unless defined $payload;
	die "imsg payload exceeds max\n" if length($payload) > IMAPIDLE::IMSG_MAX;
	my $rc = $self->compose($type, $payload, -1);
	die "imsg_compose failed\n" if !defined $rc || $rc != 1;
	$self->_flush_block;
	return;
}

# imsg_compose closes the descriptor it is given. Duplicate first so
# the caller's fd stays open.
sub send_fd {
	my ($self, $type, $payload, $fd) = @_;
	$payload = '' unless defined $payload;
	die "imsg payload exceeds max\n" if length($payload) > IMAPIDLE::IMSG_MAX;
	my $dup = POSIX::dup($fd + 0);
	die "dup: $!\n" if !defined $dup || $dup < 0;
	my $rc = $self->compose($type, $payload, $dup);
	die "imsg_compose fd failed\n" if !defined $rc || $rc != 1;
	$self->_flush_block;
	return;
}

sub queued {
	my ($self) = @_;
	my @msgs;
	while (my $msg = $self->get) {
		push @msgs, $msg;
	}
	return @msgs;
}

sub recv {
	my ($self) = @_;
	while (1) {
		my $msg = $self->get;
		return $msg if $msg;
		my $r = $self->read_more;
		return undef if defined $r && $r == 0;
		die "imsgbuf_read: $!\n" if !defined $r || $r < 0;
	}
}

1;
