# Mailmover email filtering script/daemon

A script to filter (dispatch) email files from a directory into a
hierarchy of Maildir+ folders. As one of the nicer features, it
automatically recognizes mailing list email, moves it to a folder
specific for that list, and issues notifications when someone replies
to a message sent to a list from you (more precisely, one of the
addresses defined in ~/.mailmover_config.pl (`is_own_emailaddress`
function)). It also notifies whenever it creates a new folder, or when
there is a warning or error during filtering. It also detects and
filters mails sent from system services (cron), and auto-replies
coming from subscribers of mailing lists that you're sending email to
(this is not perfect currently since it will only trigger if the own
email makes it back first).

All filtered mail (not destined for the inbox) is delivered into
(automatically created) subdirectories below the "Z" directory.

It can currently be configured to use german or english folder names
and notification text.

I originally wrote this in a hurry for personal use, at a time when I
wasn't that good a coder yet. I have cleaned it up quite a bit since,
but it could still use some more work.

## Installation

Get the submodules:

    git submodule init && git submodule update

Optional: run the tests, see [HACKING](HACKING.md).

## Usage

Read

    ./mailmover --help

It can be run as a daemon, using the `-l` option (and optionally
`--repeat` to limit the number of repetitions in case there are memory
leaks). For example, add the following to crontab of the user that
receives the email:

     @reboot daemonize --start --out log/mailmover.log loop /opt/chj/mailmover/mailmover --repeat 100 -l 5 -d MaildirIn/new/ -m Maildir

This assumes that incoming mail is put to the maildir ~/MaildirIn,
that there's a ~/log directory, and that `daemonize` and `loop` from
[chj-bin](https://github.com/pflanze/chj-bin) are installed and
reachable from crontab's PATH (can be set within the crontab).

Or use the [bin/init-mailmover](bin/init-mailmover) script. For a
setup that also picks up learned hams from ~/MaildirIn/HAM:

    @reboot /opt/chj/mailmover/bin/init-mailmover start ~/log/mailmover ~/MaildirIn/new  ~/Maildir
    @reboot /opt/chj/mailmover/bin/init-mailmover start ~/log/mailmover-ham ~/MaildirIn/HAM  ~/Maildir --ham

## Hacking

See [HACKING](HACKING.md).
