#
# Copyright 2015 by Christian Jaeger, ch at christianjaeger ch
# Published under the same terms as perl itself
#

=head1 NAME

Mailmover::MovePath::t

=head1 SYNOPSIS

=head1 DESCRIPTION


=cut


package Mailmover::MovePath::t;

use strict; use warnings FATAL => 'uninitialized';

use Mailmover::MovePath;
use Chj::TEST;

sub exn (&) {
    my ($thunk)=@_;
    my $res;
    eval {
	$res= &$thunk();
	1
    } ? $res : do {
	my $e= $@;
	$e =~ /(.*?):/ ? $1 : die $e
    }
}

TEST { exn { MovePath () } } 'unacceptable value for field \'items\'';
TEST { exn { MovePath ("") } } 'unacceptable value for field \'items\'';
TEST { exn { MovePath ("a")->untruncated_string } } "a";
TEST { exn { MovePath ("a","b")->untruncated_string } } "a/b";
TEST { exn { MovePath ("a","b","")->untruncated_string } }
  'unacceptable value for field \'items\'';

1
