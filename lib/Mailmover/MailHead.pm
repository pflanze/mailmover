#
# Copyright 2007-2015 by Christian Jaeger, ch at christianjaeger ch
# Published under the same terms as perl itself
#

=head1 NAME

Mailmover::MailHead

=head1 SYNOPSIS

=head1 DESCRIPTION


=cut


package Mailmover::MailHead;

use strict; use warnings FATAL => 'uninitialized';

use MIME::Words 'decode_mimewords';
use Chj::Encode::Permissive 'encode_permissive';
use Chj::chompspace;

use Class::Array -fields=>(
			   # ps warum's Inmail class gibt in elcms: weil es inder db es ja auch so gross will wie es eben ist i.e. ram grösse.  (chunking?)
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

sub decoded_header {
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
			    ##ps. cj 12.12.04 warum tat ich nicht pick_out_of_anglebrackets nehmen? aha: nur optional. // $value also nötig.
			    $id=$1;
			    #warn "id=$id";
			} elsif (length $value > 3) {
			    $id=$value;
			    #warn "id=$id";
			} else {
			    warn "(almost-)empty Resent-From '$value'";
			    last RESENT;
			}
			# cj 12.12.04: weil neuerdings eine email reinkam mit Resent-From: Hideki Yamane <henrich@samba.gr.jp> (== From) vom Debian BTS, und X-Loop: mysql@packages.qa.debian.org (vorsicht mehrere X-Loop headers sind in andern mails möglich), das noch prüfen:
			my $p_from= chompspace MailUtil::oerr_pick_out_of_anglebrackets $self->header("from");
			my $p_id= chompspace MailUtil::oerr_pick_out_of_anglebrackets $id; ##sollte zwar ja eben nicht mehr nötig sein, aber warum oben eigener müll gemacht?.
			if (defined($p_from)
			    and
			    lc($p_from) eq lc($p_id)) {
			    # need alternative value.
			    #if (my @xloop= $self->header   aber das kann ich gar nicht, mehrere abfragen so. mann. schlecht, mal todo besseren head parser machen. auf wantarray schauen um zu sehen ob undef oder multiple geben.
			    #if (my $xloop= $self->header("X-Loop")) { hm dumm ist dass bereits in meinem fall tatsächlich mehrere drin sind.
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
				##Frage: warum hatte compiler nöd reklamiert über undef methode? aber runtime?
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
		    # cj 12.12.04: weil neuerdings eine email reinkam mit Resent-From: Hideki Yamane <henrich@samba.gr.jp> (== From) vom Debian BTS, und X-Loop: mysql@packages.qa.debian.org (vorsicht mehrere X-Loop headers sind in andern mails möglich), das noch prüfen:
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
    if (my $subject= $self->decoded_header("subject")) {
	return 1 if $subject=~ /Your E-Mail Message will not be read/i;
	return 1 if $subject=~ /Office closed/i;
	return 1 if $subject=~ /Auto.?Reply/i;
	return 1 if $subject=~ /abwesenheitsnotiz/i;
    }
    if (my $xmailer= $self->decoded_header("X-Mailer")) {
	return 1 if $xmailer=~ /vacation/i;
	return 1 if $xmailer=~ /Autoresp/i;
    }
    if (my $autosubmitted= $self->decoded_header("Auto-Submitted")) {
	#return 1 if $autosubmitted=~ /auto/i; # auto-replied
	return 1 if $autosubmitted;
    }
    0
}

1
