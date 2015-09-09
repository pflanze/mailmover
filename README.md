A script to filter (dispatch) email files from a directory into a
hierarchy of Maildir+ folders. As one of the nicer features, it
automatically recognizes mailing list email, and issues notifications
when someone replies to a message sent to a list from one of the
addresses defined in ~/.mailmover_config.pl (`is_own_emailaddress`
function).

Currently just meant for personal use. There's still quite a lot of
ugly old code, slowly improving.

