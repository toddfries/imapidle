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
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use File::Temp qw(tempdir tempfile);
use IO::Handle;
use POSIX qw(_exit);
use Socket qw(AF_UNIX SOCK_STREAM);
use Test::More;
use Time::HiRes qw(time);

require './imapidle';

my $run = tempdir('imapidle-tls-XXXX', CLEANUP => 1, TMPDIR => 1);
set_runtime_dir_for_test($run);
install_track(_blank_track(), 0);

my @kids;
END { kill 'KILL', @kids if @kids; }

sub nb {
    my ($fh) = @_;
    my $fl = fcntl($fh, F_GETFL, 0);
    defined $fl or die "fcntl: $!";
    fcntl($fh, F_SETFL, $fl | O_NONBLOCK) or die "fcntl: $!";
}

# The peer has to be another process. One process cannot answer the
# greeting it is also waiting to read.
sub starttls_peer {
    my ($child_fn) = @_;
    socketpair(my $parent, my $child, AF_UNIX, SOCK_STREAM, 0)
        or die "socketpair: $!";
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        close $parent;
        $child->autoflush(1);
        $SIG{ALRM} = sub { _exit(3); };
        alarm(8);
        eval { $child_fn->($child); };
        _exit($@ ? 1 : 0);
    }
    close $child;
    nb($parent);
    push @kids, $pid;
    return ($parent, $pid);
}

sub finish_peer {
    my ($pid) = @_;
    waitpid($pid, 0);
    @kids = grep { $_ != $pid } @kids;
    return $? >> 8;
}

# io_wait_fd reaps every child, so the exit status is not ours to read.
# The peer records the command before it answers.
sub read_cmd {
    my ($fh, $path) = @_;
    my $line = <$fh>;
    $line = '' unless defined $line;
    $line =~ s/\r?\n\z//;
    open my $out, '>', $path or die "cmd file: $!";
    print $out $line, "\n";
    close $out;
}

sub saw_starttls {
    my ($path) = @_;
    open my $in, '<', $path or return '';
    my $line = <$in> // '';
    close $in;
    chomp $line;
    return $line;
}

my ($ok_note, $ok_path) = tempfile('imapidle-cmd-XXXX', TMPDIR => 1, UNLINK => 1);
close $ok_note;
my ($ok_fh, $ok_pid) = starttls_peer(sub {
    my ($fh) = @_;
    print $fh "* OK ready\r\n";
    read_cmd($fh, $ok_path);
    print $fh "A001 OK begin TLS\r\n";
});
my $ok = eval { _imap_starttls($ok_fh, time() + 5); 1 };
my $ok_err = $@;
ok($ok, 'an OK greeting and STARTTLS reply is accepted') or diag($ok_err);
is(saw_starttls($ok_path), 'A001 STARTTLS', 'the peer saw A001 STARTTLS');
finish_peer($ok_pid);
close $ok_fh;

my ($pre_note, $pre_path) = tempfile('imapidle-cmd-XXXX', TMPDIR => 1, UNLINK => 1);
close $pre_note;
my ($pre_fh, $pre_pid) = starttls_peer(sub {
    my ($fh) = @_;
    print $fh "* PREAUTH ready\r\n";
    read_cmd($fh, $pre_path);
    print $fh "A001 OK begin TLS\r\n";
});
my $pre = eval { _imap_starttls($pre_fh, time() + 5); 1 };
my $pre_err = $@;
ok($pre, 'a PREAUTH greeting is accepted') or diag($pre_err);
is(saw_starttls($pre_path), 'A001 STARTTLS', 'PREAUTH still sends STARTTLS');
finish_peer($pre_pid);
close $pre_fh;

my ($no_fh, $no_pid) = starttls_peer(sub {
    my ($fh) = @_;
    print $fh "* OK ready\r\n";
    <$fh>;
    print $fh "A001 NO tls\r\n";
});
my $no = eval { _imap_starttls($no_fh, time() + 5); 1 };
my $no_err = $@;
ok(!$no, 'a NO reply is not a STARTTLS success');
like($no_err, qr/^starttls rejected/, 'a NO reply names the rejection')
    or diag($no_err);
finish_peer($no_pid);
close $no_fh;

my ($bye_fh, $bye_pid) = starttls_peer(sub {
    my ($fh) = @_;
    print $fh "* BYE gone\r\n";
});
my $bye = eval { _imap_starttls($bye_fh, time() + 5); 1 };
my $bye_err = $@;
ok(!$bye, 'BYE is not a greeting');
like($bye_err, qr/^starttls greeting/, 'BYE fails before STARTTLS')
    or diag($bye_err);
finish_peer($bye_pid);
close $bye_fh;

done_testing;
