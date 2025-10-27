#!/usr/bin/perl
use strict;
use warnings;
use LWP::Simple;

# SSRF
my $url = $ARGV[0];
my $content = get($url);
print $content;
