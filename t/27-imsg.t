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
use POSIX qw(_exit);
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

my $built = system('make', '-C', 'ext/imsg');
is($built, 0, 'the imsg wrapper builds') or BAIL_OUT('imsg build failed');

use lib 'lib', 'blib';
require IMAPIDLE::Split;

socketpair(my $child_end, my $test_end, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die "socketpair: $!";
_autoflush($child_end);
_autoflush($test_end);

my $pid = fork();
die "fork: $!" unless defined $pid;
if ($pid == 0) {
	close $test_end;
	eval { IMAPIDLE::Split::demonstrate($child_end) };
	warn $@ if $@;
	_exit($@ ? 1 : 0);
}
close $child_end;

my $ready = <$test_end>;
like($ready, qr/^ready$/, 'the parent is titled before the exchange');
my $listed = `pgrep -xf 'imapidle: parent'`;
like($listed, qr/(^|\n)\Q$pid\E(\n|\z)/, 'pgrep sees imapidle: parent')
    or diag(`ps -p $pid -ww -o pid,args`);
print $test_end "go\n";

my $result = <$test_end>;
like($result, qr/^imsg ok account=fdc-main folder=INBOX total=3 saw=ping$/,
    'the hub forwarded one mailbox count from the passed fd');
waitpid($pid, 0);
is($?, 0, 'the parent exits 0');

is(IMAPIDLE::Imsg::worker_title('idle', 'title-acct', 'TitleBox'),
    'imapidle: idle title-acct TitleBox',
    'an idle title names the account and folder');
is(IMAPIDLE::Imsg::worker_title('account', 'title-acct', ''),
    'imapidle: account title-acct',
    'a pulse title names the account');
is(IMAPIDLE::Imsg::worker_title('idle', "a\nb", " c\td "),
    'imapidle: idle a b c d',
    'a title stays one line');

pipe(my $title_r, my $title_w) or die "pipe: $!";
my $named = fork();
die "fork: $!" unless defined $named;
if ($named == 0) {
	close $title_r;
	IMAPIDLE::Imsg::set_worker_title('idle', 'title-acct', 'TitleBox');
	print $title_w "ready\n";
	close $title_w;
	sleep 30;
	_exit(0);
}
close $title_w;
my $title_ready = <$title_r>;
like($title_ready, qr/^ready$/, 'the worker set its title');
my $named_list = `pgrep -xf 'imapidle: idle title-acct TitleBox'`;
like($named_list, qr/(^|\n)\Q$named\E(\n|\z)/,
    'pgrep sees the account and folder')
    or diag(`ps -p $named -ww -o pid,args`);
kill 'TERM', $named;
waitpid($named, 0);

done_testing;

sub _autoflush {
	my ($fh) = @_;
	my $old = select($fh);
	$| = 1;
	select($old);
	return;
}
