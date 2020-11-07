#!/bin/bash

set -euo pipefail
IFS=
# remember, *still* need to quote variables!

bin/local_corpus_reset

MAILMOVER_TIME=1432123123 MAILMOVER_PID=1234 ./mailmover --debug --config ./MaildirIn/config.pl -d MaildirIn/new/ -m Maildir

echo "ran through successfully; now go look in Maildir whether it's status clean."

