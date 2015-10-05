#
# Copyright 2015 by Christian Jaeger, ch at christianjaeger ch
# Published under the same terms as perl itself
#

=head1 NAME

Mailmover::MailHead::t

=head1 SYNOPSIS

=head1 DESCRIPTION


=cut


package Mailmover::MailHead::t;

use strict; use warnings FATAL => 'uninitialized';
use Function::Parameters qw(:strict);

use Mailmover::MailHead;
use Chj::TEST;
use FP::Array ":all";
use FP::Ops qw(cut_method the_method);
use FP::Combinators qw(:all);

my $heads=
  array_map (compose(cut_method ("Mailmover::MailHead", "new_from_path"),
		     fun ($file) { "testcorpus/$file" }),
	     ['1441781601.28365.servi:2,S',
	      '1439194193.2749.servi:2,S']);

TEST { array_map the_method ("maybe_decoded_header","subject"), $heads }
  [
   'Sch?tzen Sie Ihre Amazon.de Konto', # this is an odd mail, probably wrong?
   "Just landed, your business\n\treport for the past month" # hm, really? 'decoded'?
  ];

TEST { array_map the_method ("maybe_spamscore"), $heads }
  [
   '2.8',
   '-8.8'
  ];

TEST { array_map the_method ("is_spam"), $heads }
  [
   '',
   ''
  ];

TEST { array_map the_method ("is_autoreply"), $heads }
  [
   '',
   ''
  ];

TEST { array_map the_method ("maybe_mailinglist_id"), $heads }
  [
   undef,
   undef
  ];

#use Chj::repl;repl;

1
