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
#@ISA="Exporter"; require Exporter;
#@EXPORT=qw();
#@EXPORT_OK=qw();
#%EXPORT_TAGS=(all=>[@EXPORT,@EXPORT_OK]);

use strict; use warnings FATAL => 'uninitialized';

use strict;
use Chj::xopen qw(xopen_read);
use Chj::xperlfunc;
use Chj::FileStore::MIndex;
use Chj::FileStore::PIndex;
use Chj::oerr;
use FP::Lazy;
use Mailmover::MovePath;
use Mailmover::MailUtil qw(pick_out_of_anglebrackets oerr_pick_out_of_anglebrackets);


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
our $opt_leaveinbox;

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
    my $head= MailHead->new_from_fh($f);

    my ($folderpath,$type,$important);
    $type="unbekannt";

    my $is_spam= $is_ham ? 0 : $head->is_spam;
    if ($is_spam) {
	warn "'$filename' is spam\n" if $DEBUG;
	$folderpath= MovePath "spam";
    } elsif (! defined $is_spam) {
	warn "'$filename' is_spam: not scanned\n" if $verbose;
    }

    my $from= $head->maybe_header_ignoringidenticalcopies("from");
    my $content;
    my $messageid= lazy {
	pick_out_of_anglebrackets($head->maybe_first_header("message-id"))
    };

    my $spamscore= $head->spamscore;

    if (!$folderpath) {
	if (my $subject= $head->maybe_decoded_header("subject")) {
	    # mailinglist reminders
	    if ($subject=~ /^\S+\s+mailing list memberships reminder\s*$/
		and
		$from=~ /^mailman-owner\@/
	       ) {
		$folderpath= MovePath "mailinglistmembershipreminders";#$type="list";oder toplevel
	    }
	}
    }

    if (!$folderpath) {
	my $list= $head->mailinglist_id;
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
	    $folderpath= MovePath $list; $type="list";
	}
    }


    # noch gemäss subject einiges filtern:
    if (!$folderpath) {
	if (my $subject= $head->maybe_decoded_header("subject")) {
	    # system mails
	    if ($subject=~ /^([a-zA-Z][\w-]+)\s+\d+.*\d system check\s*\z/) {
		$folderpath= MovePath "systemcheck-$1";$type="system";
		##ps.punkte dürfen in maildir foldernamen dann nicht vorkommen. weils separatoren sind. quoting möglich? in meiner library dann.
	    } elsif ($subject eq 'DEBUG') {
		$folderpath= MovePath "DEBUG";$type="system";
	    } else {
		my $tmp; # instead of relying on $1 too long
		if ($subject=~ /^\[LifeCMS\]/
		    and ( $from eq 'alias@ethlife.ethz.ch'
			  or $from eq 'newsletter@ethlife.ethz.ch') ) {
		    $folderpath= MovePath $subject;$type="system";#gefährlich? jaaaa war es!!! jetzt hab ich unten geflickt.
		} elsif ($subject=~ /^Cron/ and $from=~ /Cron Daemon/) {
		    $folderpath= MovePath $subject;$type="system";
# 		} elsif ($subject=~ /out of office autoreply/i
# 			 #or
# 			) {
# 		    $folderpath= MovePath "AUTOREPLY";
		} elsif ($subject=~ /^Delivery Status Notification/
			 and $from=~ /^postmaster/) {
		    $folderpath= MovePath "BOUNCE";
		} elsif (#$subject=~ /failure notice/ and
			 ($from=~ /\bMAILER[_-]DAEMON\@/i
			  or
			  $from=~ /\bpostmaster\@/i
			 )
			 #and $content=~ /ETH Life Newsletter/
			 #and $messageid=~ /\@ethlife.ethz.ch/  # dann kam sie von hier. ; eh1: ist im content. eh2: muss auch lifecms enthalten. aber alte nl tun dies nicht.
			 and do {
			     $f->xread($content,$BUFSIZE);
			     if ($content=~ /From: ETH Life/) {
				 $folderpath= MovePath "newslettermanuell..$from";$type="system";
				 1
			     } elsif ($content=~ /Message-[Ii]d:[^\n]+lifecms/) {
				 $folderpath= MovePath "lifecms..$from";$type="system";
				 1
			     } else {
				 0
			     }
			 }) {
		    # filtered. else go on in other elsifs
		} elsif ($from=~ /GMX Magazin <mailings\@gmx/) {
		    $folderpath= MovePath "GMX Magazin"; $type="list";
		} elsif ($from=~ /GMX Spamschutz.* <mailings\@gmx/) {
		    $folderpath= MovePath "GMX Spamschutz"; $type="list";
		}
		# cj 3.12.04 ebay:
		elsif ($from=~ /\Q<newsletter_ch\@ebay.com>\E/) {
		    $folderpath= MovePath "ebay-newsletter";# $type="list"; oder "unbekannt" lassen? frage an ct: welche typen gibt es und wie werden sie sonst gehandhabt, resp. ändere es hier einfach selber ab, ich benutze type derzeit eh nicht.
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
		    $folderpath= MovePath $tmp;
		    $type= "sourceforge";
		}
	    }
	}
    }
    if (!$folderpath) {
	if (my $to= $head->maybe_header("to")) {
	    if ($to=~ /^(postmaster\@[^\@;:,\s]+[a-z])/) {
		$folderpath= MovePath $1;
	    }
	}
    }
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

    if (!$folderpath) { # wie oft prüfe ich den noch hehe ?..
	if (!$is_ham and defined($spamscore) and $spamscore > 0) {
	    $folderpath = MovePath "möglicher spam";
	}
    }

    # nichts matchende sonstwohin:
    if (!$folderpath) {
	my $s= xstat $filepath;
	if ($s->size > 1000000) { #cj: ps. sollte size messung ausserhalb geschehen? weil, wenn per symlink redirected, ja doch wieder die frage ob dann-doch-nicht in die inbox.
	    $folderpath= MovePath "inbox-big";$type="inbox";$important=1;
	} else {
	    $folderpath= MovePath "inbox" unless $opt_leaveinbox;$type="inbox";
	}

    } else {
	my $str= $folderpath->untruncated_string;
	if ($str eq "inbox" or $str eq "inbox-big") {
	    die "mail '$filename' somehow managed to get foldername '$str'";
	    #sollte nicht passieren vom Ablauf her
	}
    }
    undef $messageid;
    ($head,$folderpath,$type,$important);
}

sub _einstampfen { # testcase siehe lombi:~/perldevelopment/test/mailmoverlib/t1
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

sub _eingestampftessubject {
    my ($mail)=@_;
    _einstampfen($mail->maybe_decoded_header("subject","ascii"));
}

sub is_reply {
    my ($mail) = @_;
    if (my $subj= _eingestampftessubject($mail)) {
	my $ownsubjectstable= Chj::FileStore::PIndex->new($ownsubjects_base);
	return 1 if $ownsubjectstable->exists($subj);
	# ev. todo: hier auch noch mailingliste berücksichtigen? also subject.liste-kombination soll matchen?.
    }
    my $in_reply_to = pick_out_of_anglebrackets($mail->maybe_first_header("In-Reply-To")); # many (broken?) clients actually do seem to send multiple such headers
    return unless defined $in_reply_to;
    my $ownmsgidtable= Chj::FileStore::PIndex->new($ownmsgid_base);
    return
      $ownmsgidtable->exists($in_reply_to)
	or
	  sub {
	      for (pick_out_of_anglebrackets($mail->maybe_header("References"))) {
		  return 1 if $ownmsgidtable->exists($_);
	      }
	      0;
	  }->();
}

sub save_is_own {
    my ($mail) = @_;
    my $ownmsgidtable= Chj::FileStore::PIndex->new($ownmsgid_base);
    $ownmsgidtable->add(scalar pick_out_of_anglebrackets($mail->maybe_first_header("message-id")),"");
    if (my $subj= _eingestampftessubject($mail)) {
	my $ownsubjectstable= Chj::FileStore::PIndex->new($ownsubjects_base);
	$ownsubjectstable->add($subj,"");
    }
}

1
