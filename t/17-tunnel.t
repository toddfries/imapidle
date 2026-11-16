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
use IO::Select;
use POSIX qw(_exit);
use Socket qw(AF_UNIX SOCK_STREAM SHUT_WR);
use Test::More;

require './imapidle';

my $dir = tempdir('imapidle-tunnel-XXXX', CLEANUP => 1, TMPDIR => 1);
set_state_dir_for_test($dir);
set_runtime_dir_for_test($dir);
set_foreground_for_test(0);
set_self_path_for_test('/imap idle');
set_config_file_for_test("/tmp/a'b");

sub write_conf {
    my ($body) = @_;
    my ($out, $file) = tempfile('imapidle-XXXX', SUFFIX => '.conf', DIR => $dir);
    print $out $body;
    close $out;
    return $file;
}

sub slurp {
    my ($file) = @_;
    open my $fh, '<', $file or die "read $file: $!";
    local $/;
    return scalar <$fh>;
}

my $rc_text = <<'EOF';
# kept

IMAPAccount work
Host imap.example.com
Port 993
User a@example.com
Pass "sek rit"
PassCmd "printf secret"
AuthMechs LOGIN
TLSType IMAPS
TLSVersions +1.2
Timeout 20
CertificateFile /tmp/c.pem
PipelineDepth 1

IMAPStore work
Account work

MaildirStore local
Path /tmp/mail/

Channel work
Far :work:
Near :local:
Patterns *

IMAPAccount other
Host other.example
Pass stay-secret
TLSType IMAPS

IMAPStore other
Account other

Channel other
Far :other:
Near :local:

Channel current
Far :work:
Near :local:

IMAPStore solo
Host solo.example
User u
Pass hidden

Channel solo
Far :solo:
Near :local:

Group both
Channel work
Channel other
EOF

my $rc_path = "$dir/mbsyncrc";
open my $rcfh, '>', $rc_path or die $!;
print $rcfh $rc_text;
close $rcfh;

my $conf = write_conf(<<"EOF");
[track]
type = global
tunnel = yes
tunnel_timeout = 99
mbsyncrc = $rc_path

[work]
type = idle
server = imap.example.com
user = a\@example.com
pass = secret
mbsync_channel = work

[solo]
type = account
server = solo.example
user = u\@example.com
pass = secret
mbsync_channel = solo
EOF
is(load_config($conf), '', 'tunnel fixture loads') or diag(load_config($conf));
is(track_cfg_for_test()->{tunnel}, 1, 'tunnel is on');
is(track_cfg_for_test()->{tunnel_timeout}, 99, 'tunnel timeout is loaded');

my $shell = tunnel_shell('work');
like($shell, qr|'/imap idle' '--tunnel' 'work' '-c' '/tmp/a'\\''b'|,
    'the helper command quotes each argument');

my $out = tunnel_rewrite($rc_text, 'work:INBOX');
ok(defined $out, 'a matching channel is rewritten');
like($out, qr/^# kept/m, 'a comment stays');
like($out, qr/^Channel work$/m, 'the channel section stays');
like($out, qr/^Pass stay-secret$/m, 'an unmatched account keeps its password');
unlike($out, qr/sek rit/, 'the matched password is removed');
unlike($out, qr/^Host imap\.example\.com$/m, 'the matched host is removed');
my @tunnel_lines = grep { /^Tunnel / } split /\n/, $out;
is(@tunnel_lines, 1, 'one account is pointed at the helper');
is($tunnel_lines[0], 'Tunnel ' . _mbsync_dq(tunnel_shell('work')),
    'the helper is one mbsync argument');
like($out, qr/^TLSType None$/m, 'the tunnel does not start TLS again');
like($out, qr/^Timeout 99$/m, 'the mbsync timeout is the tunnel timeout');
like($out, qr/^Far :work:$/m, 'the store reference stays');

my $shared = tunnel_rewrite($rc_text, 'current');
ok(defined $shared, 'a channel that shares the IMAP account is rewritten');
my @shared_lines = grep { /^Tunnel / } split /\n/, $shared;
is($shared_lines[0], 'Tunnel ' . _mbsync_dq(tunnel_shell('work')),
    'the shared account uses the section that names it');

my $mixed = tunnel_rewrite($rc_text, 'work', 'other');
ok(defined $mixed, 'a mixed argv still rewrites the known account');
like($mixed, qr/^Pass stay-secret$/m, 'the unknown account is not rewritten');
unlike($mixed, qr/sek rit/, 'the known password is still removed');

ok(!defined tunnel_rewrite($rc_text, 'other'), 'no match leaves the file alone');
ok(!defined tunnel_rewrite($rc_text, 'missing'), 'an unknown channel is not rewritten');

my $group = tunnel_rewrite($rc_text, 'both');
ok(defined $group, 'a group expands to its channels');
like($group, qr/^Pass stay-secret$/m, 'a group member without a section stays');
unlike($group, qr/sek rit/, 'a group member with a section is rewritten');

my $inline = tunnel_rewrite($rc_text, 'solo');
ok(defined $inline, 'an inline IMAP store is rewritten');
unlike($inline, qr/^Pass hidden$/m, 'the inline password is removed');
my @solo_lines = grep { /^Tunnel / } split /\n/, $inline;
is($solo_lines[0], 'Tunnel ' . _mbsync_dq(tunnel_shell('solo')),
    'an account is a tunnel section');

my $path = prepare_tunnel_config('work:INBOX');
ok(defined $path && -f $path, 'a private mbsyncrc is written');
is((stat $path)[2] & 0777, 0600, 'the private mbsyncrc is mode 0600');
like($path, qr/^\Q$dir\/tunnel\E/, 'the file is under the state dir');
is(slurp($path), tunnel_rewrite($rc_text, 'work:INBOX'), 'the file is the rewrite');
_unlink_tunnel_cfg({ tunnel_cfg => $path });
ok(!-e $path, 'the private mbsyncrc is removed');

my $off = track_cfg_for_test();
$off->{tunnel} = 0;
install_track($off, 0, 1);
ok(!defined prepare_tunnel_config('work'), 'tunnel off writes nothing');

is_deeply(
    [mbsync_exec_argv(undef, 'work')],
    ['/usr/local/bin/mbsync', 'work'],
    'a plain run has no config switch',
);
is_deeply(
    [mbsync_exec_argv("$dir/x.rc", 'work:INBOX')],
    ['/usr/local/bin/mbsync', '-c', "$dir/x.rc", 'work:INBOX'],
    'a tunnel run passes -c before the channel',
);

my $conflict_rc = <<'EOF';
IMAPAccount work
Host imap.example.com
Pass secret

IMAPStore work
Account work

Channel work
Far :work:
Near :local:

Channel extra
Far :work:
Near :local:
EOF
my $conflict = write_conf(<<'EOF');
[track]
type = global
tunnel = yes

[a]
type = idle
server = imap.example.com
user = a@example.com
pass = secret
mbsync_channel = work

[b]
type = idle
server = imap.example.com
user = b@example.com
pass = secret
mbsync_channel = extra
EOF
is(load_config($conflict), '', 'conflict fixture loads');
ok(!defined tunnel_rewrite($conflict_rc, 'work', 'extra'),
    'one IMAP account cannot use two sections');

# Plain socket pair stands in for the TLS session. mbsync's end is the
# other pair, duped onto stdin and stdout the way Tunnel does it.
sub nb {
    my ($fh) = @_;
    my $flags = fcntl($fh, F_GETFL, 0);
    fcntl($fh, F_SETFL, $flags | O_NONBLOCK);
}

sub read_exact {
    my ($fh, $n) = @_;
    my $buf = '';
    my $sel = IO::Select->new($fh);
    while (length $buf < $n) {
        my ($ready) = IO::Select->select($sel, undef, undef, 2);
        die "splice read timed out\n" unless $ready && @$ready;
        my $chunk;
        my $got = sysread($fh, $chunk, $n - length $buf);
        die "splice eof\n" if defined $got && $got == 0;
        next if !defined $got && ($!{EAGAIN} || $!{EWOULDBLOCK});
        die "splice read: $!\n" unless defined $got && $got > 0;
        $buf .= $chunk;
    }
    return $buf;
}

sub write_all {
    my ($fh, $buf) = @_;
    my $off = 0;
    while ($off < length $buf) {
        my $n = syswrite($fh, $buf, length($buf) - $off, $off);
        if (!defined $n) {
            next if $!{EAGAIN} || $!{EWOULDBLOCK} || $!{EINTR};
            die "splice write: $!\n";
        }
        die "splice short write\n" if $n == 0;
        $off += $n;
    }
}

socketpair(my $srv, my $cli, AF_UNIX, SOCK_STREAM, 0) or die "socketpair: $!";
socketpair(my $app_a, my $app_b, AF_UNIX, SOCK_STREAM, 0) or die "socketpair: $!";
nb($srv);
nb($app_b);

my $pid = fork();
die "fork: $!" unless defined $pid;
if ($pid == 0) {
    alarm 0;
    close $srv;
    close $app_b;
    open STDIN,  '<&', $app_a or _exit(2);
    open STDOUT, '>&', $app_a or _exit(2);
    close $app_a;
    my $ok = eval { _tunnel_splice($cli); 1 };
    _exit($ok ? 0 : 3);
}

local $SIG{ALRM} = sub { die "splice hung\n" };
alarm 8;
my $splice_err;
eval {
    write_all($app_b, "ping\n");
    is(read_exact($srv, 5), "ping\n", 'client bytes reach the server');
    write_all($srv, "pong\n");
    is(read_exact($app_b, 5), "pong\n", 'server bytes reach the client');
    shutdown($app_b, SHUT_WR);
    write_all($srv, "late\n");
    is(read_exact($app_b, 5), "late\n", 'server bytes still flow after client EOF');
    close $srv;
    1;
} or $splice_err = $@;
alarm 0;
if ($splice_err) {
    kill 'TERM', $pid;
    waitpid($pid, 0);
    die $splice_err;
}
my $reaped = waitpid($pid, 0);
is($reaped, $pid, 'the splice child exits');
is($? >> 8, 0, 'the splice exits 0 when the server closes');

done_testing;
