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
@EXPORT=qw(analyze_file is_reply save_is_own Log);
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
use Chj::TEST;

# For printing to stderr (and then stored in log dir if using
# `bin/init-mailmover`):
sub Log {
    print STDERR join(": ", @_), "\n"
        or warn "can't write to stderr: $!";
}

# For output to report mails delivered to output Maildir's inbox:
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

package Mailmover::Hex {
    use Exporter qw(import);
    our @EXPORT=qw(unsafe_hexdigit2dec);
    my $O0= ord '0';
    my $O9= ord '9';
    my $OA= ord 'A';
    sub unsafe_hexdigit2dec {
        #only works for a single 0-9A-F character
        my $d = ord $_[0];
        ($d >= $O0 and $d <= $O9) ? $d - $O0 : ($d - $OA + 10)
    }
}

# XX move to separate module? But this one is currently (just) used
# for *MIME parts*, not full mails, careful! Also, may only work with
# linebreaks normalized to \n.
package Mailmover::HeadAndBody {
    use Encode qw(decode encode _utf8_off);
    Mailmover::Hex->import("unsafe_hexdigit2dec");

    use FP::Struct ["head", "body"], "FP::Struct::Show";

    sub decoded_body {
	my $self=shift;
        my $h= $self->head;
	my $b= $self->body;
	my $cte= $h->maybe_decoded_header('Content-Transfer-Encoding') // "";
	if ($cte=~ /quoted-printable/) {
	    $b=~ s{=([0-9A-F])([0-9A-F])}{
		chr(unsafe_hexdigit2dec($1)*16 + unsafe_hexdigit2dec($2))
            }sge;
	    $b=~ s{=\n}{}sg;
	}
	my $ct= $h->maybe_decoded_header ('Content-Type') // "";
	if (my ($charset)= $ct=~ /charset\s*=\s*"?([^"\s=,;]+)"?/i) {
	    decode($charset, $b)
	} else {
	    $b
        }
    }

    sub content_type {
	# "" if not declared
	my $self=shift;
        my $h= $self->head;
	my $ct= $h->maybe_decoded_header ('Content-Type') // "";
	$ct=~ s/;.*//s;
	$ct=~ s/\s//sg;
	lc $ct
    }

    sub is_plaintext {
	my $self=shift;
        my $ct= $self->content_type;
	$ct eq "text/plain" or $ct eq ""
    }

    sub is_html {
	my $self=shift;
        my $ct= $self->content_type;
	$ct eq "text/html" or $ct eq ""
    }

    _END_
}
Mailmover::HeadAndBody::constructors->import;

sub string_to_HeadAndBody {
    @_==1 or die "need 1 arg";
    my @hb= split /\n\n/, $_[0], 2;
    @hb == 2 or die "missing separator between head and body";
    my ($headstr, $body)= @hb;
    open my $in, "<", \$headstr or die "?";
    bless $in, "Chj::IO::File"; # uh hack. but works?
    my $head= Mailmover::MailHead->new_from_fh($in);
    HeadAndBody($head, $body)
}

sub html_to_plain {
    my ($str)= @_;
    $str=~ s/\n/ /sg;

    # Tag conversions:
    $str=~ s/<br[^<>]*>/\n/sg;
    $str=~ s{<blockquote[^<>]*>(.*?)</blockquote[^<>]*>}{
         my $inner= $1;
	 join '', map { "&gt;$_\n" } split /\n/, $inner
    }sge;
    $str=~ s/<[^<>]*>//sg;

    # Escape conversions:
    $str=~ s/&#(\d+);/chr $1/sge;
    $str=~ s/&amp;/&/sg;
    $str=~ s/&lt;/</sg;
    $str=~ s/&gt;/>/sg;

    $str
}

sub plaintext_strip_noise {
    # strip mail signature and quoted parts
    my ($str)= @_;
    
    # mail signature:
    $str=~ s/\n-- *\n.*//s;
    
    # quoted part with 'introduction' line(s) (1 or 2 lines):
    $str=~ s/^ ?On [^\n]*(?:\n[^\n]*)?\bwrote: *\n{1,2} ?>.*$//mg;
    
    # other quoted lines:
    $str=~ s/^ ?>.*$//mg;
    
    $str
}

sub content_as_plaintexts {
    # returns all variants (as multiple values) of texts, so that all
    # can be searched
    my ($head, $content)= @_;
    # needed?
    $content=~ s/\r\n/\n/sg;
    $content=~ s/\r/\n/sg;
    # /needed?
    my $asplain= sub {
	$content
    };
    if ($head ->maybe_header('mime-version')) {
	if (defined (my $ct= $head ->maybe_header('Content-Type'))) {
	    if (my ($boundary)= $ct=~ /boundary\s*=\s*"([^"]+)"/s) {
		my @parts= 
		    split /(?:^|\n)--\Q$boundary\E(?:\n|--\n?\z)/s, $content;
		if (@parts > 1) {
		    my $f= shift @parts;
		    # $f eq '' or die "missing mime separator at beginning";
                    # Ah, can be things like "This is an OpenPGP/MIME
                    # signed message (RFC 4880 and 3156)". Have to
                    # simply ignore them.
		}
		my @p= map { string_to_HeadAndBody $_ } @parts;

		my $maybe_plain = do {
		    if (my @plain= grep { $_->is_plaintext } @p) {
			$plain[0]->decoded_body
		    } else { 
			undef
		    }
		};
		my $maybe_html = do {
		    if (my @html= grep { $_->is_html } @p) {
			html_to_plain($html[0]->decoded_body)
		    } else {
			undef
		    }
		};
		my $maybe_other = do {
		    if (defined $maybe_plain or defined $maybe_html) {
			undef
		    } else {
			$p[0]->decoded_body
		    }
		};

		grep { 
		    defined $_
	        } $maybe_plain, $maybe_html, $maybe_other
	    } else {
		$asplain->()
	    }
	} else {
	    $asplain->()
	}
    } else {
	$asplain->()
    }
}

sub is_unsubscribecrap ($$) {
    my ($head, $content)= @_;
    my @plain= content_as_plaintexts($head, $content);
    my @stripped = map {
	plaintext_strip_noise $_ 
    } @plain;
    for (@stripped) {
	local $_= lc $_;
	s/\W+/ /sg;
	s/\s+/ /sg;
	next if length($_) > 200;
	my $s= qr{ *};
	return 1 if (
	    /^ $s (please)? $s remove $s me/sx
	    or
	    /^ $s (please)? $s remove $s from/sx
	    or 
	    /^ $s unsubscribe/sx
	    );
    }
    0
}


sub bayesclass_cmp ($$) {
    # higher is spammier
    my ($a, $b)=@_;
    (($a <=> $b) or
     length($b) <=> length($a))
}
TEST {
    [ sort { bayesclass_cmp $a, $b }
      qw( 0000 00 95 000 10 999 99 9999 ) ]
} ['0000', '000', '00', '10', '95', '99', '999', '9999'];

sub bayesclass_lt ($$) { &bayesclass_cmp(@_) < 0 }
TEST { bayesclass_lt "00", "000" } '';
TEST { bayesclass_lt "00", "00" } '';
TEST { bayesclass_lt "99", "999" } 1;
sub bayesclass_le ($$) { &bayesclass_cmp(@_) <= 0 }
TEST { bayesclass_le "00", "000" } '';
TEST { bayesclass_le "00", "00" } 1;
TEST { bayesclass_le "99", "999" } 1;


sub head_maybe_bayesclass ($) {
    # The most extreme of the BAYES_(\d+); use it with bayesclass_cmp,
    # bayesclass_lt or bayesclass_le to compare against your desired
    # cutoff.
    my ($head)=@_;
    if (defined (my $v= $head->maybe_first_header('X-Spam-Status'))) {
        # If there are multiple bayes classifications they are all
        # eithe /0+/ or /9+/, right?, so this just sorts by length, so
        # we will pick the last as that one is the most extreme. Do
        # *not* use bayesclass_cmp!
        if (my @b= sort $v=~ /BAYES_(\d+)/g) {
            $b[-1]
        } else {
            undef
        }
    } else {
        undef
    }
}


sub is_whitelisted ($$$$) {
    my ($filename, $head, $size_, $content_)= @_;
    my $cl= head_maybe_bayesclass $head;
    my $white_enough = (defined $cl and bayesclass_le $cl, "0000");
    ($white_enough and
     (
      # Debian PR system messages (if white enough)
      defined($head->maybe_first_header("X-Debian-PR-Message"))
      or
      # Debian BTS?
      do {
          my $xloop= $head->maybe_first_header("X-Loop");
          defined $xloop and $xloop =~ /\b\Qowner\@bugs.debian.org\E\b/
      }
     ))
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

    my $_is_spam= $head->is_spam;
    my $is_spam= $is_ham ? 0 : $_is_spam;

    if (!$is_ham and is_whitelisted($filename, $head, $size_, $content_)) {
        Log $filename, "is_whitelisted";
        $is_ham= 1;
        $is_spam= 0;
    }

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

    my $maybe_spamscore_old= $head->maybe_spamscore('X-Old-Spam-Status');
    my $maybe_mailmover_spamscore = do {
        my $maybe_spamscore= $head->maybe_spamscore;
        defined $maybe_spamscore ? do {
            # Correct SA's spamscore with more scoring (would it be cleaner to
            # do this in SA itself? Yes. Except I don't know it. And in future
            # will do NN too and that probably won't be in SA either.)
            my $correction= do {
                if (defined (my $old= $head->maybe_first_header(
                                 'X-Old-Spam-Status'))) {
                    my $total= 0;
                    $total+= -2 if $old=~ /\bLDOSUBSCRIBER\b/;
                    $total+= -3 if $old=~ /\bLDO_WHITELIST\b/;
                    $total
                } else {
                    0
                }
            };
            $maybe_spamscore + $correction
        } : undef
    };
    my $is_possible_spam= (!$is_ham
                           and defined($maybe_mailmover_spamscore)
                           and ($maybe_mailmover_spamscore
                                >= $possible_spam_minscore));

    my $list= $head->maybe_mailinglist_id;
    if ($list) {
        # also use the spamfilter on list servers (trust it to be
        # honest)

        # can't maybe_, since and chain may give '' right?
        my $possible_spam_reason=
          (!$is_ham and defined $maybe_mailmover_spamscore and do {
              my $spamscore= $maybe_mailmover_spamscore;

              # some lists just seem to come with higher scores
              my $specific_list_allowance=
                ($list=~ /spamassassin/ ? 2.5 :
                 $list=~ /debian/ ? -2 :
                 0);

              # for a list mail, allow higher scores (somehow SA finds
              # bad things in lists per se)
              my $high_spamscore =
                  '$spamscore > (1 + $specific_list_allowance)';
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
              } elsif (defined $maybe_spamscore_old and
                       eval($mix_with_old) // die $@) {
                  $show_with_interpol->("mix_with_old", $mix_with_old)
              } else {
                  ''
              }
        });

        if ($possible_spam_reason) {
            Log $filename, "reason for 'possible spam': $possible_spam_reason";
            return normal MovePath "list", __("possible spam");
        } elsif (! $is_ham and is_unsubscribecrap($head, force($content_))) {
	    # "misusing" $is_ham here to indicate not wanting that
	    # mail to be filtered out of the normal mailing list box,
	    # too; it's very similar to spam handling, after all.
	    return normal MovePath "unsubscribecrap";
	} else {
            warn "'$filename': mailinglist $list\n" if $DEBUG;
            my $class=
                (($list=~ /debian-security-announce/i and
                  content_is_important_package ($content_)) ? *important
                 : *normal);
            return $class->(MovePath "list", $list);
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
