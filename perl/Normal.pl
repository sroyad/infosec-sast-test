#!/usr/bin/perl
my $filename = $ARGV[0];
open(FILE, "<$filename") or die "Can't open file!";
print <FILE>;
