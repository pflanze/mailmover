#
# Copyright 2015 by Christian Jaeger, ch at christianjaeger ch
# Published under the same terms as perl itself
#

=head1 NAME

Chj::TransparentNoncachingLazy

=head1 SYNOPSIS

=head1 DESCRIPTION


=cut


package Chj::TransparentNoncachingLazy;
@ISA="Exporter"; require Exporter;
@EXPORT=qw(Lazy);
@EXPORT_OK=qw();
%EXPORT_TAGS=(all=>[@EXPORT,@EXPORT_OK]);

use strict; use warnings FATAL => 'uninitialized';

use Chj::TEST;

# now in FP as transparent lazy, but whatever... also, non-remembering
# variant! # XX ahh, mailmoverlib.pm requires FP::Lazy anyway now. But
# still, non-caching. TODO move to lib somehow.

{
    package Chj::TransparentNoncachingLazy::Promise;
    use overload '""'=> 'force';
    sub force {
        shift->()
    }
}

sub Lazy (&) {
    my ($thunk)=@_;
    bless $thunk, 'Chj::TransparentNoncachingLazy::Promise'
}


my $f;

TEST {
    my $z=0;
    $f= Lazy { $z++ };
    "hello $f"
} "hello 0";

TEST {
    "hello $f"
} "hello 1";

1
