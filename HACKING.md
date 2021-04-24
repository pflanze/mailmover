# Developer info

## Logging

Perl warnings for each mail (XX or run?) are redirected to a newly
created mail in the target Maildir's inbox, as well as printed to
stderr.

`Log` writes to stderr only.

`bin/init-mailmover` redirects mailmover's stdout and stderr to a
daemontools multilog dir, which will contain the `Log` messages from
above.

## Testing

To run the test suite of the functional-perl submodule (although the
kind of test most likely to fail is rather unlikely to be relevant for
better-qmail-remote):

    cd functional-perl
    ./test.pl

To run the t/local_corpus test, you need to put maildirs holding a set
of to-be filtered mails (in MaildirIn) and how you want it to be
filtered (in Maildir), both committed to Git repositories within those
folders. An unclean working dir status after conversion represents a
test failure.

To run the tests:

    ./test.pl

