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
use File::Temp qw(tempfile tempdir);
use Test::More;

require './imapidle';

my $run   = tempdir('imapidle-run-XXXX',   CLEANUP => 1, TMPDIR => 1);
my $state = tempdir('imapidle-state-XXXX', CLEANUP => 1, TMPDIR => 1);
set_runtime_dir_for_test($run);
set_state_dir_for_test($state);

# The EXAMPLES section of imapidle.conf(5), as one file.
my $example = <<'EOF';
[mail]
type = server
host = mail.example.com
proto = tls

[office]
type = server
host = outlook.office365.com
proto = tls

[personal]
type = account
server = mail
user = you@example.com
pass = secret

[work]
type = account
server = mail
user = you@work.example
pass_cmd = pizauth show work

[lists]
type = account
server = office
user = you@lists.example
pass = secret

[hot]
type = idle
channel = personal
folder0 = INBOX;priority=1
folder1 = Archive;priority=9
folder2 = INBOX.2026-11;5;3600

[desk]
type = idle
channel = work
folder0 = INBOX;priority=3

[slow]
type = pulse
sweep = 7200
channel0 = lists

[track]
type = global
min = 600
messages = 5
initial = 1800
max = 21600
empty = 86400
confirm = 604800
list = 259200
id = 604800
capability = 604800
connections = 2
tunnel = no
tunnel_timeout = 3600
EOF

sub write_conf {
    my ($text) = @_;
    my ($fh, $path) = tempfile('imapidle-XXXX', SUFFIX => '.conf', TMPDIR => 1);
    print $fh $text;
    close $fh;
    return $path;
}

sub _section_lines {
    my ($body, $section, $code) = @_;
    my (@out, @sec);
    my $in    = 0;
    my $seen  = 0;
    for my $line (split /\n/, $body, -1) {
        if ($line =~ /^\[(.+)\]\s*$/) {
            if ($in) {
                $code->(\@sec);
                push @out, @sec;
                @sec = ();
                $in  = 0;
            }
            $in   = 1 if $1 eq $section;
            $seen = 1 if $1 eq $section;
        }
        if ($in) {
            push @sec, $line;
        } else {
            push @out, $line;
        }
    }
    if ($in) {
        $code->(\@sec);
        push @out, @sec;
    }
    die "no [$section]" unless $seen;
    return join("\n", @out);
}

sub drop_line {
    my ($body, $section, $key) = @_;
    my $found = 0;
    my $text  = _section_lines($body, $section, sub {
        my ($sec) = @_;
        my @kept;
        for my $line (@$sec) {
            if (!$found && $line =~ /^\Q$key\E\s*=/) {
                $found = 1;
                next;
            }
            push @kept, $line;
        }
        @$sec = @kept;
    });
    die "no $key in [$section]" unless $found;
    return $text;
}

sub put_line {
    my ($body, $section, $key, $value) = @_;
    return _section_lines($body, $section, sub {
        my ($sec) = @_;
        my $found = 0;
        my @kept;
        for my $line (@$sec) {
            if (!$found && $line =~ /^\Q$key\E\s*=/) {
                push @kept, "$key = $value";
                $found = 1;
                next;
            }
            push @kept, $line;
        }
        push @kept, "$key = $value" unless $found;
        @$sec = @kept;
    });
}

sub rejects {
    my ($body, $re, $name) = @_;
    my $err = load_config(write_conf($body));
    like($err, $re, $name) or diag($err // 'no error');
    is_deeply([account_names()], [], "$name loads nothing");
}

sub accepts {
    my ($body, $name) = @_;
    my $err = load_config(write_conf($body));
    is($err, '', $name) or diag($err);
}

accepts($example, 'the example loads');
is(loaded_account('personal')->{role}, 'idle', 'personal is idle');
is(loaded_account('personal')->{server}, 'mail.example.com', 'personal uses mail');
is(loaded_account('personal')->{port}, 993, 'personal uses port 993');
is(loaded_account('personal')->{user}, 'you@example.com', 'personal keeps its user');
is(loaded_account('personal')->{mbsync_channel}, 'personal', 'personal names itself');
is(loaded_account('personal')->{folders}[0]{name}, 'INBOX', 'hot watches INBOX');
is(loaded_account('personal')->{folders}[0]{priority}, 1, 'INBOX priority is 1');
is(loaded_account('personal')->{folders}[1]{name}, 'Archive', 'hot watches Archive');
is(loaded_account('personal')->{folders}[1]{priority}, 9, 'Archive priority is 9');
is(loaded_account('personal')->{folders}[2]{name}, 'INBOX.2026-11', 'hot watches the dated mailbox');
is(loaded_account('personal')->{folders}[2]{priority}, 5, 'the dated mailbox is priority 5');
is(loaded_account('personal')->{folders}[2]{resync}, 3600, 'the dated mailbox resyncs in 3600s');
is(loaded_account('work')->{role}, 'idle', 'work is idle');
is(loaded_account('work')->{pass_cmd}, 'pizauth show work', 'work keeps its command');
is(loaded_account('work')->{folders}[0]{priority}, 3, 'desk priority is 3');
is(loaded_account('lists')->{role}, 'pulse', 'lists is a pulse');
is(loaded_account('lists')->{server}, 'outlook.office365.com', 'lists uses office');
is(loaded_account('lists')->{sweep}, 7200, 'slow sweeps every 7200s');
ok(!loaded_account('hot'), 'the idle label is not an account');
ok(!loaded_account('desk'), 'the other idle label is not an account');
ok(!loaded_account('slow'), 'the pulse label is not an account');
is(pulse_snapshot_for_test()->{sections}[0]{name}, 'slow', 'the pulse section is slow');
is_deeply(pulse_snapshot_for_test()->{sections}[0]{channels}, ['lists'], 'slow names lists');
is(track_cfg_for_test()->{min}, 600, 'the example min is 600');
is(track_cfg_for_test()->{connections}, 2, 'the example allows 2 mbsync processes');
is(track_cfg_for_test()->{tunnel}, 0, 'the example leaves the tunnel off');

accepts(drop_line($example, 'mail', 'proto'), 'a server proto may be omitted');
is(loaded_account('personal')->{port}, 993, 'omitted proto stays implicit TLS on 993');
accepts(drop_line($example, 'slow', 'sweep'), 'a pulse sweep may be omitted');
is(loaded_account('lists')->{sweep}, 3600, 'an omitted sweep is 3600');
accepts(drop_line(drop_line(drop_line($example, 'hot', 'folder2'), 'hot', 'folder1'), 'hot', 'folder0'),
    'idle folders may be omitted');
is(loaded_account('personal')->{folders}[0]{name}, 'INBOX', 'an idle with no folders watches INBOX');

my @required = (
    ['mail',     'type',     qr/\[mail\] missing type/],
    ['mail',     'host',     qr/\[mail\] missing host/],
    ['office',   'type',     qr/\[office\] missing type/],
    ['office',   'host',     qr/\[office\] missing host/],
    ['personal', 'type',     qr/\[personal\] missing type/],
    ['personal', 'server',   qr/\[personal\] missing server/],
    ['personal', 'user',     qr/\[personal\] missing user/],
    ['personal', 'pass',     qr/\[personal\] missing pass or pass_cmd/],
    ['work',     'type',     qr/\[work\] missing type/],
    ['work',     'server',   qr/\[work\] missing server/],
    ['work',     'user',     qr/\[work\] missing user/],
    ['work',     'pass_cmd', qr/\[work\] missing pass or pass_cmd/],
    ['lists',    'type',     qr/\[lists\] missing type/],
    ['lists',    'server',   qr/\[lists\] missing server/],
    ['lists',    'user',     qr/\[lists\] missing user/],
    ['lists',    'pass',     qr/\[lists\] missing pass or pass_cmd/],
    ['hot',      'type',     qr/\[hot\] missing type/],
    ['hot',      'channel',  qr/\[hot\] missing channel/],
    ['desk',     'type',     qr/\[desk\] missing type/],
    ['desk',     'channel',  qr/\[desk\] missing channel/],
    ['slow',     'type',     qr/\[slow\] missing type/],
    ['slow',     'channel0', qr/\[slow\] missing channel0/],
    ['track',    'type',     qr/\[track\] missing type/],
);

for my $case (@required) {
    my ($section, $key, $re) = @$case;
    rejects(drop_line($example, $section, $key), $re, "[$section] without $key");
}

my $hot = drop_line($example, 'hot', 'channel');
my $hot_err = load_config(write_conf($hot));
unlike($hot_err, qr/\[hot\] missing user/, 'hot without channel does not ask for user');
unlike($hot_err, qr/\[hot\] missing pass/, 'hot without channel does not ask for pass');

my @bad = (
    [put_line($example, 'mail', 'proto', 'plain'),  qr/\[mail\] bad proto/,  'a server proto must be tls, starttls, or notls'],
    [put_line($example, 'mail', 'port', '0'),       qr/\[mail\] bad port/,   'server port 0 is rejected'],
    [put_line($example, 'mail', 'port', '65536'),   qr/\[mail\] bad port/,   'server port 65536 is rejected'],
    [put_line($example, 'mail', 'port', 'smtp'),    qr/\[mail\] bad port/,   'a word is not a server port'],
    [put_line($example, 'mail', 'host', ''),        qr/\[mail\] missing host/, 'a blank server host is missing'],
    [put_line($example, 'personal', 'pass_cmd', 'true'), qr/\[personal\] set only one of pass or pass_cmd/, 'an account sets one secret'],
    [put_line($example, 'personal', 'user', ''),         qr/\[personal\] missing user/, 'a blank user is missing'],
    [put_line($example, 'personal', 'port', '0'),        qr/\[personal\] bad port/, 'an account port of 0 is rejected'],
    [put_line($example, 'personal', 'port', '65536'),    qr/\[personal\] bad port/, 'an account port of 65536 is rejected'],
    [put_line($example, 'personal', 'port', 'imap'),     qr/\[personal\] bad port/, 'a word is not an account port'],
    [put_line($example, 'personal', 'proto', 'clear'),   qr/\[personal\] bad proto/, 'an account proto must be tls, starttls, or notls'],
    [put_line($example, 'personal', 'mbsync_channel', 'a:b'), qr/\[personal\] bad mbsync_channel/, 'a colon is not an mbsync channel'],
    [put_line($example, 'personal', 'mbsync_channel', '-x'),  qr/\[personal\] bad mbsync_channel/, 'a channel may not look like a flag'],
    [put_line($example, 'personal', 'mbsync_channel', 'a b'), qr/\[personal\] bad mbsync_channel/, 'a channel may not contain a space'],
    [put_line($example, 'personal', 'folder0', 'INBOX'), qr/\[personal\] folder/, 'a folder belongs on the idle section'],
    [put_line($example, 'work', 'auth', 'plain'),        qr/\[work\] auth must be login or xoauth2/, 'auth is login or xoauth2'],
    [put_line($example, 'lists', 'mbsync_channel', 'personal'), qr/\[personal\] duplicate mbsync channel personal/, 'two accounts cannot share an mbsync channel'],
    [put_line(put_line($example, 'personal', 'disabled', 'no'), 'personal', 'pass', ''), qr/\[personal\] missing pass or pass_cmd/, 'disabled=no still requires a secret'],
    [put_line($example, 'hot', 'channel', 'ghost'),      qr/\[hot\] unknown account ghost/, 'an idle channel must name an account'],
    [put_line($example, 'hot', 'channel', 'in box'),     qr/\[hot\] bad channel/, 'an idle channel may not contain a space'],
    [put_line($example, 'hot', 'channel', 'a:b'),        qr/\[hot\] bad channel/, 'an idle channel may not contain a colon'],
    [put_line($example, 'hot', 'channel', '-x'),         qr/\[hot\] bad channel/, 'an idle channel may not look like a flag'],
    [put_line($example, 'hot', 'channel', ''),           qr/\[hot\] missing channel/, 'a blank idle channel is missing'],
    [put_line($example, 'hot', 'server', 'mail'),        qr/\[hot\] sets both channel and server/, 'an idle section is a channel or a login'],
    [put_line($example, 'hot', 'user', 'a@example.com'), qr/\[hot\] user/, 'an idle section does not take a user'],
    [put_line($example, 'hot', 'mbsync_channel', 'personal'), qr/\[hot\] mbsync_channel/, 'an idle section does not name an mbsync channel'],
    [put_line($example, 'slow', 'server', 'mail'),       qr/\[slow\] server/, 'a pulse section does not take a server'],
    [put_line(put_line($example, 'slow', 'disabled', 'yes'), 'slow', 'server', 'mail'), qr/\[slow\] server/, 'a disabled pulse still rejects a server'],
    [put_line($example, 'desk', 'channel', 'personal'),  qr/\[hot\] duplicate account personal/, 'one account is one idle section'],
    [drop_line($example, 'hot', 'folder1'),              qr/\[hot\] gap before folder1/, 'folder numbers have no gaps'],
    [put_line($example, 'hot', 'folder1', ''),           qr/\[hot\] empty folder1/, 'an empty folder is rejected'],
    [put_line($example, 'hot', 'folder2', 'INBOX.2026-11;5;10'), qr/\[hot\] bad resync/, 'a resync below 60 seconds is rejected'],
    [put_line($example, 'slow', 'channel0', 'ghost'),    qr/\[slow\] unknown account ghost/, 'a pulse channel must name an account'],
    [put_line($example, 'slow', 'channel0', 'personal'), qr/\[slow\] duplicate account personal/, 'one account is idle or pulse'],
    [put_line($example, 'slow', 'channel1', 'lists'),    qr/\[slow\] duplicate channel lists/, 'a pulse names an account once'],
    [put_line($example, 'slow', 'channel2', 'personal'), qr/\[slow\] gap before channel1/, 'pulse channel numbers have no gaps'],
    [put_line($example, 'slow', 'folder0', 'INBOX'),     qr/\[slow\] folder/, 'a pulse section cannot name a folder'],
    [put_line($example, 'slow', 'channel', 'lists'),     qr/\[slow\] channel\b/, 'a pulse section uses channelN'],
    [put_line($example, 'slow', 'sweep', 'soon'),        qr/\[slow\] bad sweep/, 'a pulse sweep is a number'],
    [put_line($example, 'slow', 'channel0', '-lists'),   qr/\[slow\] bad channel0/, 'a pulse channel may not look like a flag'],
    [put_line($example, 'slow', 'channel0', 'a:b'),      qr/\[slow\] bad channel0/, 'a pulse channel may not contain a colon'],
    [put_line($example, 'slow', 'channel0', 'a b'),      qr/\[slow\] bad channel0/, 'a pulse channel may not contain a space'],
    [put_line($example, 'slow', 'channel0', ''),         qr/\[slow\] empty channel0/, 'an empty pulse channel is rejected'],
    [put_line($example, 'track', 'min', '1'),            qr/\[track\] bad min/, 'min below 60 is rejected'],
    [put_line($example, 'track', 'list', '1'),           qr/\[track\] bad list/, 'list below 60 is rejected'],
    [put_line($example, 'track', 'id', '1'),             qr/\[track\] bad id/, 'id below 60 is rejected'],
    [put_line($example, 'track', 'capability', '1'),     qr/\[track\] bad capability/, 'capability below 60 is rejected'],
    [put_line($example, 'track', 'connections', '0'),    qr/\[track\] bad connections/, 'connections below 1 is rejected'],
    [put_line($example, 'track', 'initial', 'soon'),     qr/\[track\] bad initial/, 'initial must be a number'],
    [put_line($example, 'track', 'messages', '0'),       qr/\[track\] bad messages/, 'messages must be at least 1'],
    [put_line($example, 'track', 'max', '10'),           qr/\[track\] bad max/, 'max below min is rejected'],
    [put_line($example, 'track', 'empty', '1'),          qr/\[track\] bad empty/, 'empty below 60 is rejected'],
    [put_line($example, 'track', 'confirm', '1'),        qr/\[track\] bad confirm/, 'confirm below 60 is rejected'],
    [put_line($example, 'track', 'tunnel', 'maybe'),     qr/\[track\] bad tunnel/, 'tunnel must be yes or no'],
    [put_line($example, 'track', 'tunnel_timeout', '0'), qr/\[track\] bad tunnel_timeout/, 'tunnel timeout must be at least 1'],
    [put_line(put_line($example, 'track', 'id', '100'), 'track', 'capability', '90'), qr/\[track\] capability below id/, 'capability shorter than id is rejected'],
);

my $second = $example . "\n[zz]\ntype = global\n";
push @bad, [$second, qr/\[zz\] second global section/, 'a second global section is rejected'];
push @bad, [$example . "\n[extra]\nhost = mail.example.com\n", qr/\[extra\] missing type/, 'a section requires type'];
push @bad, [$example . "\n[extra]\ntype = passonly\n", qr/\[extra\] bad type/, 'an unknown type is rejected'];

for my $case (@bad) {
    rejects(@$case);
}

my $servers = <<'EOF';
[mail]
type = server
host = mail.example.com

[office]
type = server
host = outlook.office365.com
EOF
rejects($servers, qr/no usable accounts in /, 'servers alone are not a configuration');
rejects('', qr/no usable accounts in /, 'an empty file is not a configuration');

my $held = put_line(drop_line(drop_line($example, 'personal', 'user'), 'personal', 'pass'), 'personal', 'disabled', 'yes');
accepts($held, 'a disabled account may omit its login');
is(loaded_account('personal')->{config_disabled}, 1, 'the disabled account stays held');
is(loaded_account('personal')->{role}, 'idle', 'hot still names the held account');

done_testing;
