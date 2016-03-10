# detect all possible addresses that are your own!
sub is_own_emailaddress {
    my ($from)=@_;
    0
}

# one email address that is to be used for sending autoreply (and
# perhaps other) mails
sub own_emailaddress {
    undef # 'XXX@YYY.org'
}

# Which language the user would like to read mailmover messages in:
# (XX perhaps also to be used for autoreplies in the future?)
sub mailbox_language {
    "en"
}

# Whether a debian-security-announce message should issue an
# "Important" notification; receives the package name as first
# argument
sub is_important_package {
    my ($packagename)=@_;
    # never notify:
    0
}


1
