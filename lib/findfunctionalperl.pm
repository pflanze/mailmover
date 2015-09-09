#
# Copyright 2015 by Christian Jaeger, ch at christianjaeger ch
# Published under the same terms as perl itself
#

=head1 NAME

findfunctionalperl

=head1 SYNOPSIS

=head1 DESCRIPTION



=cut


package findfunctionalperl;

if (eval 'use FP; 1') {
    # all good
} else {
    my ($home)= $ENV{HOME}=~ m{^(/home/\w+)/?\z}
      or die "weird HOME: '$ENV{HOME}'";
    my $p= "$home/functional-perl/lib";
    if (-d $p) {
	unshift @INC, $p
    } else {
	die "can't find the functional-perl libraries"
    }
}

1
