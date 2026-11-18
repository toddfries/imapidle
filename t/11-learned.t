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
my $path = "$dir/learned";
set_learned_for_test($path);
set_foreground_for_test(1);

my $acc = { server => 'outlook.example', port => 993 };
my $first = capture(sub {
    is(remember_discovery('ma', 'outlook.example', 993, 'absent', undef, []), 'absent',
        'an absent server is recorded');
});
is($first, "imapidle: ma      : server does not advertise NOTIFY, using IDLE\n",
    'the first discovery is logged');
ok(-f $path, 'learned was created');
is((stat $path)[2] & 0777, 0600, 'learned mode is 0600');
like(slurp($path), qr/^outlook\.example:993\tabsent$/m, 'the host line has no server id');

my $again = capture(sub {
    remember_discovery('ma', 'outlook.example', 993, 'absent', undef, []);
});
is($again, '', 'the same discovery is not logged again');
ok(server_uses_idle('outlook.example', 993), 'a cached absent server uses IDLE');
is(setup_notification('ma', $acc, bless({}, 'CapBoom'), []), 0,
    'a cached absent server is not probed');

my $idle_host = { server => 'fresh.example', port => 993 };
my $idle_log = capture(sub {
    is(setup_notification('ma', $idle_host, bless({}, 'CapIdle'), []), 0,
        'a server without NOTIFY is IDLE');
});
is($idle_log, "imapidle: ma      : server does not advertise NOTIFY, using IDLE\n",
    'the probe logs the discovery once');
my $idle_again = capture(sub {
    is(setup_notification('ma', $idle_host, bless({}, 'CapBoom'), []), 0,
        'the next connection skips the probe');
});
is($idle_again, '', 'a repeated absent probe is quiet');

my $reject_host = { server => 'mail.example', port => 993 };
my $reject_log = capture(sub {
    is(setup_notification('fdc', $reject_host, bless({}, 'CapReject'), []), 0,
        'a rejected NOTIFY falls back');
});
like($reject_log, qr/NOTIFY NOTIFY SET \(personal/, 'the first probe sends NOTIFY');
like($reject_log, qr/server identified as dovecot-2\.2/, 'the server id is logged once');
like($reject_log, qr/NOTIFY rejected, falling back to IDLE/, 'the rejection is logged once');
like(slurp($path), qr/^mail\.example:993\trejected\tdovecot-2\.2$/m, 'the id is stored');
my $reject_again = capture(sub {
    is(setup_notification('fdc-main', $reject_host, bless({}, 'CapBoom'), []), 0,
        'another account on that host skips the probe');
});
is($reject_again, '', 'a shared host does not repeat the discovery');

my @folders = ({ name => 'INBOX' }, { name => 'Archive' });
my $active_log = capture(sub {
    remember_discovery('acct', 'new.example', 993, 'active', 'other', \@folders);
});
like($active_log, qr/acct    : server identified as other/, 'a new active server is named');
like($active_log, qr/NOTIFY active \(2 folder\(s\) in the personal namespace\)/,
    'an active server counts its folders');
ok(!server_uses_idle('new.example', 993), 'an active server is still armed');

my $quiet = capture(sub {
    is(setup_notification('acct', { server => 'new.example', port => 993 },
        bless({}, 'CapQuiet'), \@folders), 1, 'a cached active server is armed again');
});
is($quiet, '', 'a repeated active arm is quiet');

my $dropped = capture(sub {
    is(setup_notification('acct', { server => 'new.example', port => 993 },
        bless({}, 'CapDrop'), \@folders), 0, 'a failed re-arm falls back');
});
like($dropped, qr/NOTIFY rejected, falling back to IDLE/, 'a changed result is logged');
ok(server_uses_idle('new.example', 993), 'the host is now IDLE');

my $empty_log = capture(sub {
    is(setup_notification('acct', { server => 'down.example', port => 993 },
        bless({}, 'CapEmpty'), []), 0, 'an empty capability list is not a discovery');
});
is($empty_log, '', 'a failed capability read is not cached as a log line');
ok(!server_uses_idle('down.example', 993), 'a failed capability read is not stored');

open my $fh, '>>', $path or die "append: $!";
print $fh "not a row\nmail.example:993\tnope\n";
close $fh;
is(learned_row('nope.example', 993), undef, 'a bad line is ignored');
is(learned_row('mail.example', 993)->{notify}, 'rejected', 'a good line still loads');

my %hand = load_learned();
$hand{'hand.example:993'} = { notify => 'absent', id => '' };
save_learned(%hand);
my $look = time();
refresh_local_state($look);
is(learned_row('hand.example', 993)->{notify}, 'absent',
    'a saved host is remembered');
open my $edit, '>', $path or die "rewrite learned: $!";
print $edit "hand.example:993\trejected\n";
close $edit;
is(learned_row('hand.example', 993)->{notify}, 'absent',
    'a hand edit stays out of memory until the next stat');
refresh_local_state($look + 599);
is(learned_row('hand.example', 993)->{notify}, 'absent',
    'the stat waits out ten minutes');
refresh_local_state($look + 600);
is(learned_row('hand.example', 993)->{notify}, 'rejected',
    'a changed learned file is read after ten minutes');
ok(!learned_row('mail.example', 993),
    'a host deleted from the file is dropped on that read');

set_foreground_for_test(0);
done_testing;

sub capture {
    my ($code) = @_;
    my ($fh, $errpath) = tempfile('imapidle-learn-XXXX', UNLINK => 1, TMPDIR => 1);
    close $fh;
    open my $old, '>&', \*STDERR or die "dup stderr: $!";
    open STDERR, '>', $errpath or die "redirect stderr: $!";
    my $err;
    eval { $code->(); 1 } or $err = $@;
    open STDERR, '>&', $old or die "restore stderr: $!";
    close $old;
    open my $in, '<', $errpath or die "read stderr: $!";
    local $/;
    my $buf = <$in> // '';
    close $in;
    die $err if $err;
    return $buf;
}

sub slurp {
    my ($file) = @_;
    open my $in, '<', $file or die "read $file: $!";
    local $/;
    return scalar <$in>;
}

package CapBoom;
sub capability { die "probed\n"; }
sub tag_and_run { die "probed\n"; }

package CapIdle;
sub capability { return qw(IMAP4rev1 IDLE); }
sub tag_and_run { die "NOTIFY was sent without an advertisement\n"; }

package CapEmpty;
sub capability { return; }

package CapReject;
sub capability { return qw(IMAP4rev1 NOTIFY); }
sub tag_and_run {
    my (undef, $cmd) = @_;
    return '* ID ("name" "Dovecot" "version" "2.2.36")' if $cmd eq main::id_command();
    return 'A5 BAD Error in IMAP command NOTIFY: Invalid arguments.';
}

package CapQuiet;
sub capability { die "capability ran on a cached active server\n"; }
sub tag_and_run {
    my (undef, $cmd) = @_;
    die "ID ran on a cached active server\n" if defined $cmd && $cmd =~ /^ID\b/;
    return 'A9 OK NOTIFY completed.';
}

package CapDrop;
sub capability { die "capability ran on a cached active server\n"; }
sub tag_and_run {
    my (undef, $cmd) = @_;
    die "ID ran on a cached active server\n" if defined $cmd && $cmd =~ /^ID\b/;
    return 'A9 BAD NOTIFY unavailable.';
}
