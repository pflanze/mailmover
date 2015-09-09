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

use Mailmover::MailHead;
use Chj::TEST;
use Chj::xopen;

my $in= xopen_read ('testcorpus/1441781601.28365.servi:2,S');

my $head= Mailmover::MailHead->new_from_fh($in);

use Chj::repl;repl;

1
