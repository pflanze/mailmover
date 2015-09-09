#!/usr/bin/env perl

# Copyright (c) 2015 Christian Jaeger, copying@christianjaeger.ch
# This is free software. See the file COPYING.md that came bundled
# with this file.

use strict; use warnings; use warnings FATAL => 'uninitialized';

use Test::Harness;

# make sure not to carry over a TEST=0 setting, which would make
# Chj::TEST based testing fail
$ENV{TEST}=1;

our @t=
  qw(
	require_and_run_tests
   );

runtests(map {"t/$_"} @t);
