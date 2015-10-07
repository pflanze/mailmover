#
# Copyright 2007-2015 by Christian Jaeger, ch at christianjaeger ch
# Published under the same terms as perl itself
#

=head1 NAME

Mailmover::Lib

=head1 SYNOPSIS

=head1 DESCRIPTION


=cut


package Mailmover::Lib;
@ISA="Exporter"; require Exporter;
@EXPORT=qw(analyze_file is_reply save_is_own);
@EXPORT_OK=qw();
%EXPORT_TAGS=(all=>[@EXPORT,@EXPORT_OK]);

use strict; use warnings FATAL => 'uninitialized';

use Chj::xopen qw(xopen_read);
use Chj::xperlfunc;
use Chj::FileStore::MIndex;
use Chj::FileStore::PIndex;
use Chj::oerr;
use FP::Lazy;
use Mailmover::MovePath;
use Mailmover::MailUtil qw(pick_out_of_anglebrackets);
use Mailmover::MailHead;
use Mailmover::l10n;

our ($DEBUG,$verbose);

#####these here are shared with the 'x-sms-sendpending' script !!!.
my $HOME= do {# untaint it.
    $ENV{HOME}=~ m|^(/.*)|s or die "invalid \$HOME";##Hm, really trust it that far? but should be ok.
    $1
};
my $msgid_base="$HOME/.mailmover_msgids";# msgid->filenames.
my $ownmsgid_base="$HOME/.mailmover_ownmsgids";
my $ownsubjects_base="$HOME/.mailmover_ownsubjects";
####/shared
mkdir $msgid_base,0700;
mkdir $ownmsgid_base,0700;
mkdir $ownsubjects_base,0700;

my $BUFSIZE=50000;

{
    package Mailmover::Classification;
    use FP::Predicates;
    use FP::Struct [[instance_of("Mailmover::MovePath::MovePath"), "path"],
		    [*is_boolean, "is_important"]];
    _END_
}

sub important ($) {
    Mailmover::Classification->new($_[0], 1)
}
sub normal ($) {
    Mailmover::Classification->new($_[0], 0)
}

sub classify {
    my ($filename, $is_ham, $f, $head, $size_, $content_)=@_;

    my $is_spam= $is_ham ? 0 : $head->is_spam;
    if ($is_spam) {
	warn "'$filename' is spam\n" if $DEBUG;
	return normal MovePath __("spam");
    } elsif (! defined $is_spam) {
	warn "'$filename' is_spam: not scanned\n" if $verbose;
    }

    my $from= $head->maybe_header_ignoringidenticalcopies("from");

    if (my $subject= $head->maybe_decoded_header("subject")) {
	# mailinglist reminders
	if ($subject=~ /^\S+\s+mailing list memberships reminder\s*$/
	    and
	    $from=~ /^mailman-owner\@/
	   ) {
	    return normal MovePath "mailinglistmembershipreminders";
	}
    }

    my $maybe_spamscore= $head->maybe_spamscore;
    my $maybe_spamscore_old= $head->maybe_spamscore('X-Old-Spam-Status');
    my $is_possible_spam= (!$is_ham
			   and defined($maybe_spamscore)
			   and $maybe_spamscore > 0);
    my $is_possible_spam_old= (!$is_ham
			       and defined($maybe_spamscore_old)
			       and $maybe_spamscore_old > 0);

    my $list= $head->maybe_mailinglist_id;
    if ($list) {
	# trust the spamfilter on list servers
	if ($is_possible_spam or $is_possible_spam_old) {
	    return normal MovePath "list", __("possible spam");
	} else {
	    warn "'$filename': mailinglist $list\n" if $DEBUG;
	    my $class= ($list=~ /debian-security-announce/i ? *important
			: *normal);
	    return &$class (MovePath "list", $list);
	}
    }

    # various subject checks
    if (my $subject= $head->maybe_decoded_header("subject")) {
	# system mails
	if ($subject=~ /^([a-zA-Z][\w-]+)\s+\d+.*\d system check\s*\z/) {
	    return normal MovePath "system", "systemcheck-$1";
	    ##ps.punkte dürfen in maildir foldernamen dann nicht vorkommen. weils separatoren sind. quoting möglich? in meiner library dann.
	} elsif ($subject eq 'DEBUG') {
	    return normal MovePath "system", "DEBUG";
	} else {
	    my $tmp; # instead of relying on $1 too long
	    if ($subject=~ /^\[LifeCMS\]/
		and ( $from eq 'alias@ethlife.ethz.ch'
		      or $from eq 'newsletter@ethlife.ethz.ch') ) {
		return normal MovePath "system", $subject;
	    } elsif ($subject=~ /^Cron/ and $from=~ /Cron Daemon/) {
		return normal MovePath "system", $subject;
	    } elsif ($subject=~ /^Delivery Status Notification/
		     and $from=~ /^postmaster/) {
		return normal MovePath "BOUNCE";
	    } elsif ($subject=~ /failure notice/ and
		     ($from=~ /\bMAILER[_-]DAEMON\@/i
		      or
		      $from=~ /\bpostmaster\@/i
		     )
		     # [siehe history fuer ethlife newsletter bounce (why war das?)]
		     and do {
			 if (force($content_)=~ /but the bounce bounced\! *\n *\n *<[^\n]*>: *\n *Sorry, no mailbox here by that name/s) {
			     # ^ the 'Sorry' check (or checking
			     # the domain of the address) is
			     # necessary to see that it tried to
			     # deliver to *us*, not remotely.
			     # Mess. XX is there any solid
			     # alternative? XX ah, perhaps that
			     # the mail doesn't have a message-id
			     # header is at least indicative of a
			     # bounce? XX ah, or this in the
			     # original mail: 'Return-Path: <>',
			     # or this in the current mail?:
			     # 'Return-Path: <#@[]>'
			     return normal MovePath "backscatter";
			     # XX only backscatter that was sent
			     # to an invalid address of mine! How
			     # to trap the rest?
			     1
			 } else {
			     0
			 }
		     }) {
		# filtered. else go on in other elsifs
	    } elsif ($from=~ /GMX Magazin <mailings\@gmx/) {
		return normal MovePath "list", "GMX Magazin";
	    } elsif ($from=~ /GMX Spamschutz.* <mailings\@gmx/) {
		return normal MovePath "list", "GMX Spamschutz";
	    }
	    # cj 3.12.04 ebay:
	    elsif ($from=~ /\Q<newsletter_ch\@ebay.com>\E/) {
		return normal MovePath "ebay-newsletter";
	    }
	    # sourceforge:
	    elsif (do {
		#warn "checking for sourceforge:";
		(
		 (($tmp)= $subject=~ /^\[([^\]]+)\]/)
		 and
		 $from=~ /noreply\@sourceforge\.net/
		)
	    }) {
		#warn "yes, sourceforge";
		return normal MovePath "sourceforge", $tmp;
	    }
	}
    }

    # postmaster
    if (my $to= $head->maybe_header("to")) {
	if ($to=~ /^(postmaster\@[^\@;:,\s]+[a-z])/) {
	    return normal MovePath $1;
	}
    }

    # facebook
    if ($head->maybe_header('x-facebook')) {
	# XX how many times to get that header? Also, why never
	# decoded above?
	if (my $subject= $head->maybe_decoded_header("subject")) {
	    if ($subject=~ /\bTrending\b/i) {
		return normal MovePath "facebook", "trending"
	    } elsif ($subject=~ /\bdo you know /i) {
		return normal MovePath "facebook", "doyouknow"
	    } elsif ($subject=~ /\bYou have more friends .*than you think/i) {
		return normal MovePath "facebook", "morethanyouthink"
	    } else {
		#use Chj::repl;repl;
	    }
	}
    }

    # auto-replies received over mailing lists
    if ($head->is_autoreply) {
	if (is_reply ($head)) {
	    return normal MovePath __("auto-reply through list");
	}
	# In auto-replies so bad that they don't check out as replies
	# to one of one's own mails to a list, there's still the
	# chance that those are captured in "possible spam". They
	# might be trained as spam from there, too (possibly a good or
	# bad idea, let the user 'decide').
    }

    if ($is_possible_spam) {
	return normal MovePath __("possible spam");
    }

    # making the inbox

    # check mail size, to avoid downloading big mails over mobile
    # connections
    if (force($size_) > 5000000) {
	return important MovePath "inbox-big"
    } else {
	return normal MovePath (); # inbox
    }
}


sub analyze_file($;$$) {
    # $maybe_filename is the filename of the file it will get in
    # future in the maildir
    my ($filepath, $maybe_filename, $is_ham)=@_;

    my $filename= $maybe_filename || do {
	my $f=$filepath; $f=~ s{^.*/}{}s;
	$f
    };
    my $f= xopen_read $filepath;
    my $head= Mailmover::MailHead->new_from_fh($f);

    my $classification= classify ($filename, $is_ham, $f, $head,
				  lazy {
				      xstat ($filepath)->size
				  },
				  lazy {
				      my $content;
				      # XX could even be lazier by
				      # using streams!
				      $f->xread($content,$BUFSIZE);
				      $content
				  });

    ($head,
     $classification->path,
     $classification->is_important)
}

sub _reduce { # testcase siehe lombi:~/perldevelopment/test/mailmoverlib/t1
    my ($str)=@_;
    if (defined $str) {
	#$str=~ s/\s+/ /sg; cj 24.8.04: weil manche mailer wörter in mitte abeinanderbrechen, whitespace ganz raus.
	$str=~ s/\s+//sg;
	my $stripprefix=sub {
	    $str=~ s/^(?:re|aw|fwd)://i
	};
	my $stripbrackets=sub {
	    if ($str=~ m|^\[|) {
		my $p=1;
		my $inner=1;
		my $len=length$str;
		while($p<$len) {
		    my $c=substr($str,$p,1);
		    if ($c eq '[') {
			$inner++;
		    }elsif($c eq ']') {
			$inner--;
			if ($inner==0) {
			    if ($p == $len-1) {
				# rausnehmen
				$str= substr($str,1,$len-2);
			    } else {
				# wegschneiden.
				#warn "vorwegschneiden '$str'";
				substr($str,0,$p+1)="";
				#warn "weggeschnitten, '$str'";
			    }
			    return 1;
			}
		    }
		    $p++;
		}
		#warn "endslash nicht gefunden";
		$str=substr($str,1);#tja. sosolala  sollte nicht schaden.
		return 1;
	    }
	    0
	};
	do {} while &$stripprefix or &$stripbrackets;

	#$str=~ s/^\s+//s;
	$str= lc($str);
        if (length($str)>=8) {
	    $str
	} else {
	    undef
	}
    } else {
	undef
    }
}

sub maybe_reduced_subject {
    my ($mail)=@_;
    _reduce($mail->maybe_decoded_header("subject","ascii"));
}

my $ownsubjectstable= Chj::FileStore::PIndex->new($ownsubjects_base);
my $ownmsgidtable= Chj::FileStore::PIndex->new($ownmsgid_base);

sub is_reply {
    my ($mail) = @_;
    if (my $subj= maybe_reduced_subject($mail)) {
	return 1 if $ownsubjectstable->exists($subj);
	# XX also check mailing list? i.e. should only the right
	# combination of subject and list trigger?
    }

    # many (broken?) clients actually do seem to send multiple such headers
    if (defined (my $in_reply_to = pick_out_of_anglebrackets
		 ($mail->maybe_first_header("In-Reply-To")))) {
	return 1 if $ownmsgidtable->exists($in_reply_to)
    }

    for (pick_out_of_anglebrackets($mail->maybe_header("References"))) {
	return 1 if $ownmsgidtable->exists($_);
    }
}

sub save_is_own {
    my ($mail) = @_;
    my $ownmsgidtable= Chj::FileStore::PIndex->new($ownmsgid_base);
    $ownmsgidtable->add(scalar pick_out_of_anglebrackets
			($mail->maybe_first_header("message-id")),"");
    if (my $subj= maybe_reduced_subject($mail)) {
	my $ownsubjectstable= Chj::FileStore::PIndex->new($ownsubjects_base);
	$ownsubjectstable->add($subj,"");
    }
}

1
