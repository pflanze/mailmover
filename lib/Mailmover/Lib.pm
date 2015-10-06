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

    my ($folderpath,$important);

    my $is_spam= $is_ham ? 0 : $head->is_spam;
    if ($is_spam) {
	warn "'$filename' is spam\n" if $DEBUG;
	$folderpath= MovePath __("spam");
    } elsif (! defined $is_spam) {
	warn "'$filename' is_spam: not scanned\n" if $verbose;
    }

    my $from= $head->maybe_header_ignoringidenticalcopies("from");
    my $content;
    my $messageid= lazy {
	pick_out_of_anglebrackets($head->maybe_first_header("message-id"))
    };

    my $maybe_spamscore= $head->maybe_spamscore;

    if (!$folderpath) {
	if (my $subject= $head->maybe_decoded_header("subject")) {
	    # mailinglist reminders
	    if ($subject=~ /^\S+\s+mailing list memberships reminder\s*$/
		and
		$from=~ /^mailman-owner\@/
	       ) {
		$folderpath= MovePath "mailinglistmembershipreminders";
	    }
	}
    }

    if (!$folderpath) {
	my $list= $head->maybe_mailinglist_id;
	if (defined $list) {
	    warn "'$filename': mailinglist $list\n" if $DEBUG;
	} else {
	    warn "'$filename': not a list mail\n" if $DEBUG;
	}
	#if (!$list and 0) {
	#use Data::Dumper;
	#print "head for $filepath:",Dumper($head);
	#}
	if ($list) {
	    if ($list=~ /debian-security-announce/i) {
		$important=1;
	    }
	    $folderpath= MovePath "list", $list;
	}
    }

    # various subject checks
    if (!$folderpath) {
	if (my $subject= $head->maybe_decoded_header("subject")) {
	    # system mails
	    if ($subject=~ /^([a-zA-Z][\w-]+)\s+\d+.*\d system check\s*\z/) {
		$folderpath= MovePath "system", "systemcheck-$1";
		##ps.punkte d�rfen in maildir foldernamen dann nicht vorkommen. weils separatoren sind. quoting m�glich? in meiner library dann.
	    } elsif ($subject eq 'DEBUG') {
		$folderpath= MovePath "system", "DEBUG";
	    } else {
		my $tmp; # instead of relying on $1 too long
		if ($subject=~ /^\[LifeCMS\]/
		    and ( $from eq 'alias@ethlife.ethz.ch'
			  or $from eq 'newsletter@ethlife.ethz.ch') ) {
		    $folderpath= MovePath "system", $subject;
		} elsif ($subject=~ /^Cron/ and $from=~ /Cron Daemon/) {
		    $folderpath= MovePath "system", $subject;
		} elsif ($subject=~ /^Delivery Status Notification/
			 and $from=~ /^postmaster/) {
		    $folderpath= MovePath "BOUNCE";
		} elsif ($subject=~ /failure notice/ and
			 ($from=~ /\bMAILER[_-]DAEMON\@/i
			  or
			  $from=~ /\bpostmaster\@/i
			 )
			 # [siehe history fuer ethlife newsletter bounce (why war das?)]
 			 and do {
 			     $f->xread($content,$BUFSIZE);
 			     if ($content=~ /but the bounce bounced\! *\n *\n *<[^\n]*>: *\n *Sorry, no mailbox here by that name/s) {
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
 				 $folderpath= MovePath "backscatter";
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
		    $folderpath= MovePath "list", "GMX Magazin";
		} elsif ($from=~ /GMX Spamschutz.* <mailings\@gmx/) {
		    $folderpath= MovePath "list", "GMX Spamschutz";
		}
		# cj 3.12.04 ebay:
		elsif ($from=~ /\Q<newsletter_ch\@ebay.com>\E/) {
		    $folderpath= MovePath "ebay-newsletter";
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
		    $folderpath= MovePath "sourceforge", $tmp;
		}
	    }
	}
    }

    # postmaster
    if (!$folderpath) {
	if (my $to= $head->maybe_header("to")) {
	    if ($to=~ /^(postmaster\@[^\@;:,\s]+[a-z])/) {
		$folderpath= MovePath $1;
	    }
	}
    }

    # facebook
    if (!$folderpath) {
	if ($head->maybe_header('x-facebook')) {
	    # XX how many times to get that header? Also, why never
	    # decoded above?
	    if (my $subject= $head->maybe_decoded_header("subject")) {
		if ($subject=~ /\bTrending\b/i) {
		    $folderpath= MovePath "facebook", "trending"
		} elsif ($subject=~ /\bdo you know /i) {
		    $folderpath= MovePath "facebook", "doyouknow"
		} elsif ($subject=~ /\bYou have more friends .*than you think/i) {
		    $folderpath= MovePath "facebook", "morethanyouthink"
		} else {
		    #use Chj::repl;repl;
		}
	    }
	}
    }

    # auto-replies received over mailing lists
    if ($head->is_autoreply) {
	if (is_reply ($head)) {
	    $folderpath= MovePath __("auto-reply through list");
	}
	# In auto-replies so bad that they don't check out as replies
	# to one of one's own mails to a list, there's still the
	# chance that those are captured in "possible spam". They
	# might be trained as spam from there, too (possibly a good or
	# bad idea, let the user 'decide').
    }

    if (!$folderpath) {
	if (!$is_ham and defined($maybe_spamscore) and $maybe_spamscore > 0) {
	    $folderpath = MovePath __("possible spam");
	}
    }

    # making the inbox
    if (!$folderpath) {
	# check mail size, to avoid downloading big mails over mobile
	# connections
	my $s= xstat $filepath;
	if ($s->size > 5000000) {
	    $folderpath= MovePath "inbox-big";$important=1;
	} else {
	    $folderpath= MovePath (); # inbox
	}
    }

    ($head,$folderpath,$important);
}


sub _reduce { # testcase siehe lombi:~/perldevelopment/test/mailmoverlib/t1
    my ($str)=@_;
    if (defined $str) {
	#$str=~ s/\s+/ /sg; cj 24.8.04: weil manche mailer w�rter in mitte abeinanderbrechen, whitespace ganz raus.
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
    $ownmsgidtable->add(scalar pick_out_of_anglebrackets($mail->maybe_first_header("message-id")),"");
    if (my $subj= maybe_reduced_subject($mail)) {
	my $ownsubjectstable= Chj::FileStore::PIndex->new($ownsubjects_base);
	$ownsubjectstable->add($subj,"");
    }
}

1
