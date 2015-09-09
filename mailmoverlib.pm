use strict;
use Chj::xopen qw(xopen_read);
use Chj::xperlfunc;
use Chj::FileStore::MIndex;
use Chj::FileStore::PIndex;
use Chj::oerr;
use FP::Lazy;

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

{
    package MovePath;
    use Chj::Path::Truncator::MD5;
    use FP::Predicates "is_array";
    use FP::Array "array_append";

    use FP::Struct [[*is_array, "items"]];

    sub untruncated_string {
	@_==1 or die "wrong number of arguments";
	my $s=shift;
	join "/",
	    map {
		local $_= /^\./ ? "dot.$_" : $_;
		s{/}{--}sg
	    } @{$s->items};
    }

    sub string {
	@_==2 or die "wrong number of arguments";
	my ($s, $targetbase)=@_;
	my $truncator= Chj::Path::Truncator::MD5->new($targetbase,3);
	# XX: not totally safe as it might truncate away a folder
	# boundary if parent folders are long!
	$truncator->trunc($s->untruncated_string)
    }

    sub string_split {
	@_==2 or die "wrong number of arguments";
	my ($s, $targetbase)=@_;
	# sounds stupid first to stringify then split again, but,
	# proper escaping is being done this way (only?) *and
	# especially truncation*.
	split /\//, $s->string ($targetbase)
    }

    sub append {
	@_==2 or die "wrong number of arguments";
	my ($a,$b)=@_;
	UNIVERSAL::isa($b, "MovePath") or die "wrong type of $b";
	$a->items_set(array_append ($a->items, $b->items))
    }

    _END_
}
sub MovePath {
    MovePath->new([@_])
}


{
    package MailUtil;
    our @EXPORT_OK=qw(pick_out_of_anglebrackets
		      oerr_pick_out_of_anglebrackets
		     );
    use base "Exporter";
    use Carp;

    our $verbose=0;
    our $raiseerrors=0;

    sub pick_out_of_anglebrackets {
	my ($str)=@_;
	unless (defined $str) {
	    return wantarray ? () : undef;
	}
	my @res= $str=~ /<([^>]*)>/g;
	if (wantarray){
	    @res
	} elsif (@res>1) {
	    my $msg= "multiple angle brackets found but only one expected";
	    if ($verbose) {
		warn $msg
	    }#naja, DBI like doppelwarn behaviour. is this liked?   [todo?]
	    if ($raiseerrors){
		croak $msg
	    } else {
		$res[0]
	    }
	} else {
	    $res[0]
	}
    }
    sub oerr_pick_out_of_anglebrackets {
	my ($str)=@_;
	if (wantarray) {
	    my @res= pick_out_of_anglebrackets $str;
	    @res ? @res : ($str)
	} else {
	    my $res= pick_out_of_anglebrackets $str;
	    defined($res) ? $res : $str
	}
    }
}

import MailUtil qw(pick_out_of_anglebrackets oerr_pick_out_of_anglebrackets);

{
    package MailHead;
    use MIME::Words 'decode_mimewords';
    use Chj::Encode::Permissive 'encode_permissive';
    use Chj::chompspace;

    use Class::Array -fields=>(
			       # ps warum's Inmail class gibt in elcms: weil es inder db es ja auch so gross will wie es eben ist i.e. ram gr�sse.  (chunking?)
			       # enum? wie schon machte ich jenes, zahlen versus db.
			       'Errors', #arrayrf
			       'Warnings', #arrayrf
			       'HeadersHash', #hashref, only single headers
			       'HeadersArray', #arrayref, all headers
			       'HeaderSHash', # $headers{$key}=[ multiple of same type as $header{$key} ]  (leider gabs HeadersHash schon drum S)
			      );

    sub new_from_fh {
	my $class=shift;
	my ($fh)=@_; # assume this is blessed to Chj::IO::File? or do it now?
	# assume it is rewinded (rewound).!
	my $self= $class->SUPER::new;
	@{$self}[Errors,Warnings]= ([],[]);

	my (%header,@headers,@errors,%headers); # $headers{$key}=[ multiple of same type as $header{$key} ]
	my ($lastheaderkey);
      HEADER:{
	    local $_;
	    while (defined($_=$fh->xreadline)) {
		s/[\r\n]\z//s; # chomp doesn't work for both chars, right?
		if (length) {
		    if (/^(\w[\w.-]+): *(.*)/) {
			$lastheaderkey=lc($1);
			push @headers,$_;
			# Always keep the *last* header with same name in %header.
			# This way, multi-line build up is still correct.
			# Have to check in (with?) ->header() method if multiple.
			push @{ $headers{$lastheaderkey} }, [$#headers,$1,$2];
			$header{$lastheaderkey}=[$#headers,$1,$2];
		    } elsif (/^\s+(.*)/) {  #(naja, ist das alles so wirklich korrekt?)
			if ($lastheaderkey) {
			    $headers[-1].="\n\t$1";
			    $header{$lastheaderkey}[2].="\n\t$1"
			      if defined $header{$lastheaderkey};
			    if (my $rf= $headers{$lastheaderkey}[-1]) {
				$$rf[2].="\n\t$1"
			    } else {
				warn "bug?"
			    };
			} else {
			    push @errors, "First header does not start with a key: '$_'";
			}
		    } else {
			push @errors, "Header of unknown format: '$_'";
		    }
		} else {
		    last HEADER;
		}
	    }
	    # ran out of data before finishing headers? Well there is
	    # no guarantee that a mail has a body at all (not even the
	    # empty line inbetween), so it's not an error.
	}
	@{$self}[HeadersHash,HeadersArray,HeaderSHash]= (\%header,\@headers,\%headers);
	$self->[Errors]= \@errors;
	$self
    }

    # XX rename to maybe_header
    sub header {
	my $self=shift;
	my ($key)=@_;
	if (defined(my $h=$$self[HeadersHash]{lc($key)})) {
	    if (@{ $$self[HeaderSHash]{lc $key} } > 1) {
		warn "header method called where multiple headers of key '$key' exists";
		return undef
	    }
	    # Don't return header values with space at the end, since
	    # that would/may lead to things like creation of folders
	    # ending in spaces and then some programs won't handle
	    # them correctly (e.g. squirrelmail/courier-imap). Is this
	    # a HACK or a good idea?
	    chompspace($h->[2]);
	} else {
	    undef
	}
    }

    # XX rename to maybe_first_header; etc.
    sub first_header {
	my $s=shift;
	($s->headers(@_))[0]
    }

    sub header_ignoringidenticalcopies {
	my $s=shift;
	my ($key)=@_;
	if (my @v= $s->headers($key)) {
	    if (@v > 1) {
		my $first= shift @v;
	      CHECK: {
		    for (@v) {
			if ($_ ne $first) {
			    warn "header_ignoringidenticalcopies('$key'): multiple headers of key with *different* values exist";
			    last CHECK;
			}
		    }
		}
	    }
	    $v[0]
	} else {
	    return
	}
    }

    sub headers {
	my $self=shift;
	my ($key)=@_;
	map {
	    chompspace($_->[2]);
	} @{ $$self[HeaderSHash]{lc $key} }
    }

    sub decodedheader {
	my $self=shift;
	my ($key,$as_charset)=@_;
	if (defined(my $h=$$self[HeadersHash]{lc($key)})) {
	    join("",
		 map{ encode_permissive $_->[0],$_->[1],$as_charset }
		 decode_mimewords(chompspace($h->[2])));
	} else {
	    undef
	}
    }

    # does not belong into base package anymore:
    my %known_list_precedences= map {$_=>undef} qw( bulk list );
    sub mailinglist_id {
	my $self=shift;
	my ($value,$id);
      SEARCH:{
	    if ($value= $self->header("x-mailing-list-name")) {	# cj 15.10.04 damit perl6-all aufgeteilt wird.
		if ($value=~ /<([^<>]{3,})>/) {##ps da gibts doch pick_out_of_anglebrackets?
		    $id=$1;
		    last SEARCH;
		} else {
		    #warn "invalid x-mailing-list-name format '$value'";
		    $id= chompspace $value;
		    last SEARCH; #!
		}
	    }
	    # prioritize list-post over list-id since it contains the @ char?
	    if ($value= $self->header("List-Post")) {
		if ($value=~ /<([^<>]{3,})>/) { # just in case
		    $id=$1;# hier ist dann bei ssh list noch mailto: dabei
		    last SEARCH;
		} elsif (length $value > 3) {
		    warn "even if ssh mailinglist did put List-Post value into <>, this one did not ('$value')";
		    $id=$value;
		    last SEARCH;
		} else {
		    warn "(almost-)empty List-Post header '$value'";
		}
	    }
	    if ($value= $self->header("List-Id")) {
		if ($value=~ /<([^<>]{3,})>/) {
		    $id=$1;
		    last SEARCH;
		} else {
		    # warn "invalid list-id format '$value'"; ct: membershipreminders kommen hierhin
		}
	    } #els
	    if ($value= $self->header("x-mailing-list")) {
		if ($value=~ /<([^<>]{3,})>/) {
		    $id=$1;
		    last SEARCH;
		} elsif ($value=~ /^\s*(\S.*\S)/) { # cj Tue,  9 May 2006 03:18:14 +0200 for majordomo
		    $id= $1;
		    last SEARCH;
		} else {
		    warn "invalid x-mailing-list format '$value'";
		    # actually hab ich, bei ezmlm, perl6-all, dies gesehen:
		    # X-Mailing-List: contact perl6-language-help@perl.org; run by ezmlm
		    # X-Mailing-List-Name: perl6-language
		    # daher weiter oben nun noch X-Mailing-List-Name anschauen.
		}
	    }
	    # 'Mailing-List: contact qmail-help@list.cr.yp.to; run by ezmlm'
	    if ($value= $self->header("Mailing-List")) {
		if ($value=~ /<([^<>]{3,})>/) {
		    warn "even if Qmail (yet another ezmlm based, right??) mailing list didn't use <..> format, this list does ('$value')";
		    $id=$1;
		    last SEARCH;
		} elsif($value=~ /([^\s\@;:,?]+\@[^\s\@;:,?]+[a-z])/) {
		    $id= $1;
		    last SEARCH;
		} else {
		    warn "invalid x-mailing-list format '$value'";
		}
	    }
	    if (my $precedence= $self->header("precedence")) {
		$precedence= lc($precedence);
		$precedence=~ s/^\s+//s;
		$precedence=~ s/\s+\z//s;
		if (exists $known_list_precedences{$precedence}) {
		  RESENT:{
			if ($value= $self->header("Resent-From")) {
			    #warn "entered Resent-From check";
			    if ($value=~ /<([^<>]{3,})>/) { # just in case
				#warn "note: even if debian mailinglists do not put resent-from into <>, this mail did it ('$value')"; -> cj14.12.: die neuen Debian BTS Mails tun dies.
				##ps. cj 12.12.04 warum tat ich nicht pick_out_of_anglebrackets nehmen? aha: nur optional. // $value also n�tig.
				$id=$1;
				#warn "id=$id";
			    } elsif (length $value > 3) {
				$id=$value;
				#warn "id=$id";
			    } else {
				warn "(almost-)empty Resent-From '$value'";
				last RESENT;
			    }
			    # cj 12.12.04: weil neuerdings eine email reinkam mit Resent-From: Hideki Yamane <henrich@samba.gr.jp> (== From) vom Debian BTS, und X-Loop: mysql@packages.qa.debian.org (vorsicht mehrere X-Loop headers sind in andern mails m�glich), das noch pr�fen:
			    my $p_from= chompspace MailUtil::oerr_pick_out_of_anglebrackets $self->header("from");
			    my $p_id= chompspace MailUtil::oerr_pick_out_of_anglebrackets $id; ##sollte zwar ja eben nicht mehr n�tig sein, aber warum oben eigener m�ll gemacht?.
			    if (defined($p_from)
				and
				lc($p_from) eq lc($p_id)) {
				# need alternative value.
				#if (my @xloop= $self->header   aber das kann ich gar nicht, mehrere abfragen so. mann. schlecht, mal todo besseren head parser machen. auf wantarray schauen um zu sehen ob undef oder multiple geben.
				#if (my $xloop= $self->header("X-Loop")) { hm dumm ist dass bereits in meinem fall tats�chlich mehrere drin sind.
				#} else {
				#	warn "kein X-Loop header (oder mehrere) drin";
				#}
				my @xloop= $self->headers("X-Loop");
				my $xloop= do {
				    if (@xloop >=2) {
					my @xloopn= grep { ! /^[^\@]*\bowner\b/i } @xloop;
					#warn "xloops ohne owner: ".join(", ",@xloopn);
					if (@xloopn) {
					    @xloop= @xloopn;
					    #warn "since we still had one, this is now assigned to xloop";
					}
				    }
				    $xloop[-1]
				};
				if (defined $xloop) {
				    $id= chompspace MailUtil::oerr_pick_out_of_anglebrackets $xloop;
				    ##Frage: warum hatte compiler n�d reklamiert �ber undef methode? aber runtime?
				    #warn "ok X-Loop header drin: id isch nun $id";
				    last SEARCH;
				} else {
				    #warn "kein X-Loop header drin";
				}
			    } else {
				last SEARCH;##frage gibt das ein warning wegen leave mehrere schritte? nah doch nid
			    }
			}
			#warn "still in Resent-From check, id is ".(defined($id)? "'$id'": "undef");
			#warn "id=$id";  wie kann das undef sein????--> mann blind auf beiden Augen
			# cj 12.12.04: weil neuerdings eine email reinkam mit Resent-From: Hideki Yamane <henrich@samba.gr.jp> (== From) vom Debian BTS, und X-Loop: mysql@packages.qa.debian.org (vorsicht mehrere X-Loop headers sind in andern mails m�glich), das noch pr�fen:
			# ----> NACH OBEN
		    }#/RESENT
		    # lugs: (mail alt dings)
		    if ($value= $self->header("sender")
			and $value=~ /^owner-(.*)/si) {
			$id=$1;
			last SEARCH;
		    }
		}
	    }
	    #warn "not a list mail";
	    return;
	}
	#warn "listmail: $id\n";
	$id=~ s/^mailto:\s*//si;
	return $id;
    }

    sub is_spam {
	my $self=shift;
	if (my $status=$self->first_header("X-Spam-Status")) {
	    if ($status=~ /^\s*yes\b/si) {
		return 1;
	    } else {
		return 0;
	    }
	} else {
	    return undef
	}
    }

    sub spamscore {#ps. ebenso wie is_spam: was wenn multiple spamchecks were done?
	my $self=shift;
	if (my $status=$self->first_header("X-Spam-Status")) {
	    if ($status=~ /score=(-?\d+(?:\.\d+)?)/){
		$1
	    } else {
		warn "spamscore: X-Spam-Status header found but no score match";
		undef
	    }
	} else {
	    undef
	}
    }

    sub lookslike_autoreply { # cj 10.10.04; sollte 1. wohl eben auch nicht in basisklasse sein und 2. ist sehr heuristisch (nadel im heustack)
	my $self=shift;
	# schau nur inhalt an, denn bulk header wurde schon angekuckt.
	# obwohl: scheint dass precedence junk nur bei autoreplies (und ev spam??) angewendet wird, list mails haben bulk oder list.
	if (my $subject= $self->decodedheader("subject")) {
	    return 1 if $subject=~ /Your E-Mail Message will not be read/i;
	    return 1 if $subject=~ /Office closed/i;
	    return 1 if $subject=~ /Auto.?Reply/i;
	    return 1 if $subject=~ /abwesenheitsnotiz/i;
	}
	if (my $xmailer= $self->decodedheader("X-Mailer")) {
	    return 1 if $xmailer=~ /vacation/i;
	    return 1 if $xmailer=~ /Autoresp/i;
	}
	if (my $autosubmitted= $self->decodedheader("Auto-Submitted")) {
	    #return 1 if $autosubmitted=~ /auto/i; # auto-replied
	    return 1 if $autosubmitted;
	}
	0
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

    my $from= $head->header_ignoringidenticalcopies("from");
    my $content;
    my $messageid= lazy {
	pick_out_of_anglebrackets($head->first_header("message-id"))
    };

    my $spamscore= $head->spamscore;

    if (!$folderpath) {
	if (my $subject= $head->decodedheader("subject")) {
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


    # noch gem�ss subject einiges filtern:
    if (!$folderpath) {
	if (my $subject= $head->decodedheader("subject")) {
	    # system mails
	    if ($subject=~ /^([a-zA-Z][\w-]+)\s+\d+.*\d system check\s*\z/) {
		$folderpath= MovePath "systemcheck-$1";$type="system";
		##ps.punkte d�rfen in maildir foldernamen dann nicht vorkommen. weils separatoren sind. quoting m�glich? in meiner library dann.
	    } elsif ($subject eq 'DEBUG') {
		$folderpath= MovePath "DEBUG";$type="system";
	    } else {
		my $tmp; # instead of relying on $1 too long
		if ($subject=~ /^\[LifeCMS\]/
		    and ( $from eq 'alias@ethlife.ethz.ch'
			  or $from eq 'newsletter@ethlife.ethz.ch') ) {
		    $folderpath= MovePath $subject;$type="system";#gef�hrlich? jaaaa war es!!! jetzt hab ich unten geflickt.
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
		    $folderpath= MovePath "ebay-newsletter";# $type="list"; oder "unbekannt" lassen? frage an ct: welche typen gibt es und wie werden sie sonst gehandhabt, resp. �ndere es hier einfach selber ab, ich benutze type derzeit eh nicht.
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
	if (my $to= $head->header("to")) {
	    if ($to=~ /^(postmaster\@[^\@;:,\s]+[a-z])/) {
		$folderpath= MovePath $1;
	    }
	}
    }
    if (!$folderpath) {
	if ($head->header('x-facebook')) {
	    # XX how many times to get that header? Also, why never
	    # decoded above?
	    if (my $subject= $head->decodedheader("subject")) {
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

    if (!$folderpath) { # wie oft pr�fe ich den noch hehe ?..
	if (!$is_ham and defined($spamscore) and $spamscore > 0) {
	    $folderpath = MovePath "m�glicher spam";
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

sub _eingestampftessubject {
    my ($mail)=@_;
    _einstampfen($mail->decodedheader("subject","ascii"));
}

sub is_reply {
    my ($mail) = @_;
    if (my $subj= _eingestampftessubject($mail)) {
	my $ownsubjectstable= Chj::FileStore::PIndex->new($ownsubjects_base);
	return 1 if $ownsubjectstable->exists($subj);
	# ev. todo: hier auch noch mailingliste ber�cksichtigen? also subject.liste-kombination soll matchen?.
    }
    my $in_reply_to = pick_out_of_anglebrackets($mail->first_header("In-Reply-To")); # many (broken?) clients actually do seem to send multiple such headers
    return unless defined $in_reply_to;
    my $ownmsgidtable= Chj::FileStore::PIndex->new($ownmsgid_base);
    return
      $ownmsgidtable->exists($in_reply_to)
	or
	  sub {
	      for (pick_out_of_anglebrackets($mail->header("References"))) {
		  return 1 if $ownmsgidtable->exists($_);
	      }
	      0;
	  }->();
}

sub save_is_own {
    my ($mail) = @_;
    my $ownmsgidtable= Chj::FileStore::PIndex->new($ownmsgid_base);
    $ownmsgidtable->add(scalar pick_out_of_anglebrackets($mail->first_header("message-id")),"");
    if (my $subj= _eingestampftessubject($mail)) {
	my $ownsubjectstable= Chj::FileStore::PIndex->new($ownsubjects_base);
	$ownsubjectstable->add($subj,"");
    }
}
