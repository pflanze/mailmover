#!/bin/bash

set -euo pipefail
IFS=
# remember, *still* need to quote variables!

(
set -euo pipefail

cd Maildir

rm -rf * .Moved*/; mkdir tmp new cur

)

(
set -euo pipefail

cd MaildirIn

git reset --hard

)

DEBUG=1 ./mailmover --config ./MaildirIn/config.pl -d MaildirIn/new/ -m Maildir

echo "ran through successfully; now go look in Maildir whether it's status clean."

