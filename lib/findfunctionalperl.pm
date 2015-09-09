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

use Mailmover::safe_HOME;

if (eval 'use FP; 1') {
    # all good
} else {
    my $home= safe_HOME;
    my $p= "$home/functional-perl/lib";
    if (-d $p) {
	unshift @INC, $p
    } else {
	die "can't find the functional-perl libraries"
    }
}

1
