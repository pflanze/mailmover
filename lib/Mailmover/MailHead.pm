#
# Copyright 2007-2020 by Christian Jaeger, ch at christianjaeger ch
# Published under the same terms as perl itself
#

=head1 NAME

Mailmover::MailHead

=head1 SYNOPSIS

=head1 DESCRIPTION


=cut


package Mailmover::MailHead;

use strict; use warnings FATAL => 'uninitialized';

package Mailmover::MailHead::Header {
    use FP::Predicates;
    use Chj::chompspace;

    use FP::Struct
      [
       [*is_string, 'name'],
       [*is_string, 'value']
      ],
       "FP::Struct::Show";

    sub chompspace_value {
        my $s=shift;
        chompspace $$s{value}
    }

    _END_
}


sub looks_like_messed_up_list_id ($) {
    # returns a score, 1 = probably, 2 = quite sure, 3+ = very sure
    my ($id)= @_;
    my $score=0;
    $score++ if $id=~ /^reply\+/;
    $score++ if $id=~ /[A-Z0-9]{35,}/;
    $score++ if $id=~ /[A-F0-9]{80,}/i;
    $score++ if $id=~ /reply\.github\.com$/;
    $score
}


use MIME::Words 'decode_mimewords';
use Chj::Encode::Permissive 'encode_permissive';
use Chj::chompspace;
use Mailmover::MailUtil qw(pick_out_of_anglebrackets_or_original);
use FP::PureArray qw(is_purearray array_to_purearray);
use FP::List qw(null is_null);
use FP::Predicates;
use FP::Show;
use FP::Ops qw(the_method);

*is_header= instance_of "Mailmover::MailHead::Header";

use FP::Struct
  [
   [*is_purearray, 'errors'],
   [*is_hash, '_headers_by_name'], # hash_of purearray_of *is_header
  ],
    "FP::Struct::Show";


sub new_from_fh {
    my $class=shift;
    my ($fh)=@_; # assume this is blessed to Chj::IO::File and rewound

    my (@errors,%headers);
    my ($lastheaderkey);
  HEADER:{
        local $_;
        while (defined($_=$fh->xreadline)) {
            s/[\r\n]\z//s; # chomp doesn't work for both chars, right?
            if (length) {
                if (/^(\w[\w.-]+): *(.*)/) {
                    $lastheaderkey=lc($1);
                    my $v= Mailmover::MailHead::Header->new($1,$2);
                    push @{$headers{$lastheaderkey}}, $v;
                } elsif (/^\s+(.*)/) {
                    if ($lastheaderkey) {
                        if (my $rf= $headers{$lastheaderkey}[-1]) {
                            $$rf{value}.="\n\t$1"
                        } else {
                            warn "bug?"
                        };
                    } else {
                        push @errors,
                          "First header does not start with a key: ".show($_);
                    }
                } else {
                    push @errors, "Header of unknown format: ".show($_);
                }
            } else {
                last HEADER;
            }
        }
        # ran out of data before finishing headers? Well there is
        # no guarantee that a mail has a body at all (not even the
        # empty line inbetween), so it's not an error.
    }

    for (values %headers) { array_to_purearray $_ }

    $class->new_(errors=> array_to_purearray(\@errors),
                 _headers_by_name=> \%headers)
}

sub new_from_path {
    my $class=shift;
    my ($path)=@_;
    require Chj::xopen;
    my $fh= Chj::xopen::xopen_read($path);
    my $self= $class->new_from_fh($fh);
    $fh->xclose;
    $self
}


# call this 'headers_by_name'? but then, that would really suggest to
# return the Mailmover::MailHead::Header objects. XX stupid.
sub headers {
    my $self=shift;
    my ($name)=@_;
    if (defined (my $l= $$self{_headers_by_name}{lc $name})) {
        # Don't return header values with space at the end, since
        # that would/may lead to things like creation of folders
        # ending in spaces and then some programs won't handle
        # them correctly (e.g. squirrelmail/courier-imap). Is this
        # a HACK or a good idea?
        $l->stream->map (the_method "chompspace_value")
    } else {
        null
    }
}

sub maybe_header {
    my $self=shift;
    my ($name)=@_;
    my $hs= $self->headers($name);
    if (is_null $hs) {
        undef
    } else {
        if (is_null ($hs->rest)) {
            $hs->first
        } else {
            warn "maybe_header method called where multiple "
              ."headers of key '$name' exists";
            undef
        }
    }
}

sub maybe_first_header {
    my $s=shift;
    my ($name)=@_;
    $s->headers($name)->maybe_first
}

sub maybe_header_ignoringidenticalcopies {
    my $s=shift;
    my ($name)=@_;
    my $hs= $s->headers($name);
    if (my ($first)= $hs->perhaps_first) {
        $hs->rest->any
          (sub {
               if ($_ ne $first) {
                   warn("maybe_header_ignoringidenticalcopies('$name'):"
                        ." multiple headers of key with *different* "
                        ."values exist");
                   1 # last check
               } else {
                   0
               }
           });
        $first
    } else {
        undef
    }
}

sub maybe_decoded_header {
    my $self=shift;
    my ($name,$as_charset)=@_;
    if (defined(my $h= $self->maybe_header($name))) {
        join("",
             map {
                 my $res;
                 eval {
                     # str, from, to
                     $res = encode_permissive $_->[0], $_->[1], $as_charset;
                     1
                 } ? $res : do {
                     warn "encoding error: $@";
                     $_->[0]
                 }
             }
             decode_mimewords($h))
    } else {
        undef
    }
}


# does not belong into base package anymore:


sub precedence_stream {
    my $self=shift;
    $self->headers("precedence")->map
      (sub {
          my $precedence= lc($_[0]);
          $precedence=~ s/^\s+//s;
          $precedence=~ s/\s+\z//s;
          $precedence
      });
}

sub is_list_precedence {
    my $self=shift;
    $self->precedence_stream->any
      (sub {
           $_[0] eq "bulk" or $_[0] eq "list"
       });
}

sub is_junk_precedence {
    my $self=shift;
    $self->precedence_stream->any
      (sub {
           $_[0] eq "junk"
       });
}

sub from_out_of_anglebrackets {
    my $self=shift;
    chompspace
      pick_out_of_anglebrackets_or_original
        ($self->maybe_header("from") // "");
    # is the // "" necessary to prevent failures? Presumably yes since
    # at the latest chompspace will fail, at least with strict undef
    # handling, perhaps I still don't do that here though? Ehr I do
    # now, fatal.
}

sub maybe_mailinglist_id {
    my $self=shift;
    my ($value,$id);
  SEARCH:{
        if ($value= $self->maybe_header("x-mailing-list-name")) {       # cj 15.10.04 damit perl6-all aufgeteilt wird.
            if (($id)= $value=~ /<([^<>]{3,})>/) {##ps da gibts doch pick_out_of_anglebrackets?
                last SEARCH;
            } else {
                #warn "invalid x-mailing-list-name format '$value'";
                $id= chompspace $value;
                last SEARCH; #!
            }
        }
        # prioritize list-post over list-id since it contains the @
        # char, unless it's one that contains base64 numbers and
        # List-Id is present (e.g. Github).
        if ($value= $self->maybe_header("List-Post")) {
            if (($id)= $value=~ /<([^<>]{3,})>/) { # just in case
                # ssh list has mailto: in $id

                # Now, fall back to List-Id if useful:
                my $messedup_score= looks_like_messed_up_list_id($id);
                if ($messedup_score
                    and defined(my $id2= $self->maybe_header("List-Id"))) {
                    $id = $id2;
                } else {
                    # still use the List-Post value
                    last SEARCH;
                }
            } elsif (length $value > 3) {
                warn "even if ssh mailinglist did put List-Post value into <>, this one did not ('$value')";
                $id=$value;
                last SEARCH;
            } else {
                warn "(almost-)empty List-Post maybe_header '$value'";
            }
        }
        if ($value= $self->maybe_header("List-Id")) {
            if (my ($listid)= $value=~ /<([^<>]{3,})>/) {
                if ($listid=~ /^[\d_]{14,}\./) {
                    # ignore shitty list-id's (mis-configuration on
                    # behalf of list infrastructure owners?), like
                    # List-ID: <7209406_434176.xt.local>; ugly part is
                    # that those emails don't seem to contain any
                    # *other* indication of them being lists, so have
                    # to hack something here, man. Ah,
                    # List-Unsubscribe:
                    # <mailto:leave-fd22167270646b2531492c-fe4d117472660d7b7d1d-fec610737165037b-fe931372756d007d73-ff3212737164@leave.S7.exacttarget.com>
                    # ah oh well. This is the case with Shopify. With
                    # Brack: List-Unsubscribe:
                    # <mailto:leave-fd8011761a3c402029-fe4e127972620d747517-fec312767762057a-fe8c127277600d7b73-ff5e137372@leave.newsletter.brack.ch>
                    # (clearly the same software, but not same installation?)
                    # Aha actually the same, f:

                    # leave.newsletter.brack.ch mail is handled by 10 reply-mx.s6.exacttarget.com.

                    # Return-Path: <bounce-56_HTML-69769903-662617-6224966-737@bounce.newsletter.brack.ch>
                    # From: "BRACK.CH" <email@newsletter.brack.ch>

                    # or shopify:

                    # Return-Path: <bounce-2250_HTML-54729689-434176-7209406-6340@bounce.email.shopify.com>
                    # From: "Shopify Forums" <email@email.shopify.com>


                    my $from= $self->from_out_of_anglebrackets;
                    if (my ($domain)= $from=~ /\@(.*)/s) {
                        $id= $domain;
                        last SEARCH;
                    } else {
                        warn "mail with pseudo list-id but no proper From address: '$from'"
                    }
                } else {
                    $id=$listid;
                    last SEARCH;
                }
            } else {
                # warn "invalid list-id format '$value'"; ct: membershipreminders are getting here
            }
        } #els
        if ($value= $self->maybe_header("x-mailing-list")) {
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
        if ($value= $self->maybe_header("Mailing-List")) {
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
        if ($self->is_list_precedence) {
          RESENT:{
                if ($value= $self->maybe_header("Resent-From")) {
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
                    my $p_from= $self->from_out_of_anglebrackets;
                    my $p_id= chompspace pick_out_of_anglebrackets_or_original $id; ##sollte zwar ja eben nicht mehr nötig sein, aber warum oben eigener müll gemacht?.
                    if (defined($p_from)
                        and
                        lc($p_from) eq lc($p_id)) {
                        # need alternative value.
                        #if (my @xloop= $self->maybe_header   aber das kann ich gar nicht, mehrere abfragen so. mann. schlecht, mal todo besseren head parser machen. auf wantarray schauen um zu sehen ob undef oder multiple geben.
                        #if (my $xloop= $self->maybe_header("X-Loop")) { hm dumm ist dass bereits in meinem fall tatsächlich mehrere drin sind.
                        #} else {
                        #       warn "kein X-Loop maybe_header (oder mehrere) drin";
                        #}
                        my @xloop= $self->headers("X-Loop")->values; # XX simplify w FP?
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
                            $id= chompspace pick_out_of_anglebrackets_or_original $xloop;
                            ##Frage: warum hatte compiler nöd reklamiert über undef methode? aber runtime?
                            #warn "ok X-Loop maybe_header drin: id isch nun $id";
                            last SEARCH;
                        } else {
                            #warn "kein X-Loop maybe_header drin";
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
            if ($value= $self->maybe_header("sender")
                and $value=~ /^owner-(.*)/si) {
                $id=$1;
                last SEARCH;
            }
        }
        #warn "not a list mail";
        return undef;
    }
    #warn "listmail: $id\n";
    $id=~ s/^mailto:\s*//si;
    return $id;
}

sub is_spam {
    my $self=shift;
    if (my $status=$self->maybe_first_header("X-Spam-Status")) {
        if ($status=~ /^\s*yes\b/si) {
            return 1;
        } else {
            return '';
        }
    } else {
        return undef
    }
}

sub maybe_spamscore {
    my $self=shift;
    my ($maybe_headername)=@_; # e.g. 'X-Old-Spam-Status'
    my $headername= $maybe_headername // "X-Spam-Status";
    if (my $status=$self->maybe_first_header($headername)) {
        if ($status=~ /\b(?:score|hits)=(-?\d+(?:\.\d+)?)/){
            $1
        } else {
            warn "maybe_spamscore: $headername header found "
              ."but no score match";
            undef
        }
    } else {
        undef
    }
}

# to be used after mailing-list check, but before spam check, right?
sub is_autoreply {
    my $self=shift;
    my $score=0;
    if ($self->is_junk_precedence) {
        $score+= 1
        # XX not necessarily?, will see.
    }
    if (my $subject= $self->maybe_decoded_header("subject")) {
        $score+= 1 if $subject=~ /Your E-Mail Message will not be read/i;
        $score+= 1 if $subject=~ /Office closed/i;
        $score+= 1 if $subject=~ /Auto.?Reply/i;
        $score+= 1 if $subject=~ /abwesenheitsnotiz/i;
    }
    if (my $xmailer= $self->maybe_decoded_header("X-Mailer")) {
        $score+= 1 if $xmailer=~ /vacation/i;
        $score+= 1 if $xmailer=~ /Autoresp/i;
        # "Oracle's Siebel Email Marketing", seen used for auto-response:
        $score+= 1 if $xmailer=~ /\bSiebel /;
    }
    if (my $autosubmitted= $self->maybe_decoded_header("Auto-Submitted")) {
        $score+= 1  # if $autosubmitted=~ /auto/i; # auto-replied
    }
    $score >= 1
}


_END_
