# detect all possible addresses that are your own!
sub is_own_emailaddress {
    my ($from)=@_;
    0
}

# one email address that is to be used for sending autoreply (and
# perhaps other) mails
sub own_emailaddress {
    'XXX@YYY.org'
}

# Which language the user would like to read mailmover messages in:
# (XX perhaps also to be used for autoreplies in the future?)
sub mailbox_language {
    "en"
}

1
