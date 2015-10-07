#
# Copyright 2015 by Christian Jaeger, ch at christianjaeger ch
# Published under the same terms as perl itself
#

=head1 NAME

Mailmover::l10n

=head1 SYNOPSIS

 use Mailmover::l10n;
 $l10n_lang="de";
 print __("Foo");

=head1 DESCRIPTION

KISS: as long as it's only about a handful of words and phrases,
don't bother about dependencies. Do it right here.

=cut


package Mailmover::l10n;
@ISA="Exporter"; require Exporter;
@EXPORT=qw(__ *l10n_lang);
@EXPORT_OK=qw();
%EXPORT_TAGS=(all=>[@EXPORT,@EXPORT_OK]);

use strict; use warnings FATAL => 'uninitialized';

use utf8;

our $l10n_lang; # configure, please!

sub __ ($);

our $translations=
  +{
    "Subject"=> {de=> "Betreff"},
    "From"=> {de=> "Von"},
    "     From"=> {de=>
    "      Von"},
    "  Subject"=> {de=>
    "  Betreff"},
    "To/Cc"=> {de=> "An"},
    "Date"=> {de=> "Datum"},
    "created new folder:"=> {de=> "Neuer Ordner erstellt:"},
    "Reply"=> {de=> "Antwort"},
    "A followup to your email"=> {de=> "Eine Nachfolge-Email auf deine Email"},
    "has arrived in folder "=> {de=> "ist in Order "},
    " eingetroffen"=> {de=> " eingetroffen", en=> ""},
    "Big"=> {de=> "Gross"},
    "Important"=> {de=> "Wichtig"},
    "Email with\n"=> {de=> "Email mit\n"},
    "sent autoreply"=> {de=> "Abwesenheitsnotiz gesendet"},
    "Error/exception:\n"=> {de=> "Fehler/Ausnahmebedingung:\n"},
    "Warnings for email"=> {de=> "Warnungen für Email"},
    "saved in folder"=> {de=> "gespeichert in Ordner"},
    "you"=> {de=> "dich"},
    "possible spam"=> {en=> " possible spam", de=> " möglicher Spam"},
    "spam"=> {en=> " spam", de=> " Spam"},
    "auto-reply through list"=> {de=> "Auto-Reply durch Liste"},
    "(stopped before retrieval)"=> {de=> "(abgebrochen bevor geholt)"},
    "(no subject)"=> {de=> "(kein Subject)"},
   };

sub __ ($) {
    my ($str)=@_;
    defined $l10n_lang or die '$l10n_lang is not set';
    if (my $h= $$translations{$str}) {
	if (defined (my $v= $$h{$l10n_lang})) {
	    $v
	} else {
	    warn "missing translation for '$str' to '$l10n_lang'"
	      unless ($l10n_lang eq "en");
	    $str
	}
    } else {
	warn "missing translations for '$str'"
	  unless ($l10n_lang eq "en");
	$str
    }
}


1
