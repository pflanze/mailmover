#!/bin/bash

set -euo pipefail
IFS=
# remember, *still* need to quote variables!

(
set -euo pipefail

cd Maildir

rm -rf * .Z*/; mkdir tmp new cur

)

(
set -euo pipefail

cd MaildirIn

git reset --hard

)

MAILMOVER_TIME=1432123123 MAILMOVER_PID=1234 ./mailmover --debug --config ./MaildirIn/config.pl -d MaildirIn/new/ -m Maildir

echo "ran through successfully; now go look in Maildir whether it's status clean."

