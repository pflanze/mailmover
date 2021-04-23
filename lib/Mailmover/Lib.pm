#
# Copyright 2007-2021 by Christian Jaeger, ch at christianjaeger ch
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
    $ENV{HOME}=~ m|^(/.*)|s
      or die "invalid \$HOME";##Hm, really trust it that far? but should be ok.
    $1
};
my $msgid_base="$HOME/.mailmover_msgids";# msgid->filenames.
my $ownmsgid_base="$HOME/.mailmover_ownmsgids";
my $ownsubjects_base="$HOME/.mailmover_ownsubjects";
####/shared
mkdir $msgid_base,0700;
mkdir $ownmsgid_base,0700;
mkdir $ownsubjects_base,0700;


# for whether to notify about debian-security-announce mails
sub content_is_important_package ($) {
    my ($content_)=@_;
    my ($package)= force ($content_)=~ /\nPackage\s*:\s*(\S+)/
	or do {
	    warn "no match";
	    return undef
    };
    main::is_important_package ($package)
}

# From which score on mails are moved to "possible spam" (versus
# "spam" which is the target when SA said it is spam, usually 5)
our $possible_spam_minscore; # see default_mailmover_config.pl


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
    my $subject= $head->maybe_decoded_header("subject");

    if ($subject) {
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
    my $maybe_bayes_=
      lazy {
	  my $v= $head->maybe_first_header('X-Spam-Status');
	  defined $v ? ($v=~ /BAYES_(\d+)/ ? $1 : undef) : undef
      };
    my $is_possible_spam= (!$is_ham
			   and defined($maybe_spamscore)
			   and $maybe_spamscore >= $possible_spam_minscore);

    my $list= $head->maybe_mailinglist_id;
    if ($list) {
	# also use the spamfilter on list servers (trust it to be
	# honest)

	# can't maybe_, since and chain may give '' right?
	my $possible_spam_reason=
	  (!$is_ham and defined $maybe_spamscore and do {
	      my $spamscore= $maybe_spamscore;

	      # some lists just seem to come with higher scores
	      my $specific_list_allowance=
		($list=~ /spamassassin/ ? 2.5 :
		 # $list=~ /debian/ ? -1 :
		 0);

	      # for a list mail, allow higher scores (somehow SA finds
	      # bad things in lists per se)
              my $high_spamscore = '$spamscore > (1 + $specific_list_allowance)';
              my $mix_with_old =
                  '$spamscore <= 1 and (2*($spamscore-1) + $maybe_spamscore_old) > $specific_list_allowance*2';
              # $mix_with_old=~ s/\n\s+/\n/sg;

              my $show_with_interpol= sub {
                  my ($which, $formula)= @_;
                  my $interpolated= eval('"' . $formula . '"') // die $@;
                  "$which: $formula [ $interpolated ]"
              };
              
              if (eval($high_spamscore) // die $@) {
                  $show_with_interpol->("high_spamscore", $high_spamscore)
	      } elsif (defined $maybe_spamscore_old and eval($mix_with_old) // die $@) {
                  $show_with_interpol->("mix_with_old", $mix_with_old)
	      } else {
		  ''
	      }
	});
	
	if ($possible_spam_reason) {
	    warn "$filename: reason for 'possible spam': $possible_spam_reason\n"
                #  if $DEBUG
                ;
	    # ^XX: use $DEBUG >= 2 or so, this is a more useful debug
	    #      message than others. Or make a Log function.
	    return normal MovePath "list", __("possible spam");
	} else {
	    warn "'$filename': mailinglist $list\n" if $DEBUG;
	    my $class=
		(($list=~ /debian-security-announce/i and
		  content_is_important_package ($content_)) ? *important
		 : *normal);
	    return &$class (MovePath "list", $list);
	}
    }

    # various subject checks
    if ($subject) {
	# system mails
	if ($subject=~ /^([a-zA-Z][\w-]+)\s+\d+.*\d system check\s*\z/) {
	    return normal MovePath "system", "systemcheck-$1";
	} elsif ($subject eq 'DEBUG') {
	    return normal MovePath "system", "DEBUG";
	} else {
	    my $tmp; # instead of relying on $1 too long
	    if ($subject=~ /^Cron/ and $from=~ /Cron Daemon/) {
		return normal MovePath "system", $subject;
	    } elsif ($subject=~ /^Delivery Status Notification/
		     and $from=~ /^postmaster/) {
		return normal MovePath "BOUNCE";
	    } elsif ($subject=~ /failure notice/ and
		     ($from=~ /\bMAILER[_-]DAEMON\@/i
		      or
		      $from=~ /\bpostmaster\@/i
		     )
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
	    # ebay:
	    elsif ($from=~ /\Q<newsletter_ch\@ebay.com>\E/) {
		return normal MovePath "ebay-newsletter";
	    }
	    # sourceforge:
	    elsif (do {
		(
		 (($tmp)= $subject=~ /^\[([^\]]+)\]/)
		 and
		 $from=~ /noreply\@sourceforge\.net/
		)
	    }) {
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
	if ($subject) {
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

    # BRACK
    if ($from =~ /<email\@newsletter.brack.ch>/
	# but they are sending *all* of their mail from this address,
	# including order confirmations. man. Luckily, oddly:
	and $head->maybe_header("List-Unsubscribe")) {
	return normal MovePath "newsletter", "BRACK"
    }

    # General Assembly (spammy or legit service?)
    my $GA_From= 'hello@hello.generalassemb.ly';
    # 'General Assembly <hello@hello.generalassemb.ly>' didn't match, huh
    if ($from =~ /\Q$GA_From\E/
	and $head->maybe_header("List-Unsubscribe")
       ) {
	return normal MovePath "newsletter", "GeneralAssemb.ly"
    }

    # Shopify (really pretty spammy usually *paid* service ey)
    if ($from =~ /\b(?:welcome|email)\@email\.shopify\.com\b/
	and $head->maybe_header("List-Unsubscribe")
       ) {
	return normal MovePath "newsletter", "Shopify"
    }

    # Gitlab news
    if ($from =~ /\bGitLab News\b.*\@gitlab\.com\b/
	and $head->maybe_header("List-Unsubscribe")
       ) {
	return normal MovePath "newsletter", "GitLab"
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

    my $classification= classify ($filename,
				  $is_ham,
				  $f,
				  $head,
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

# testcase siehe lombi:~/perldevelopment/test/mailmoverlib/t1
sub _reduce {
    my ($str)=@_;
    if (defined $str) {
	# since some mailers break apart words in the middle, remove
	# whitespace completely
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
				$str= substr($str,1,$len-2);
			    } else {
				substr($str,0,$p+1)="";
			    }
			    return 1;
			}
		    }
		    $p++;
		}
		$str=substr($str,1);
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
