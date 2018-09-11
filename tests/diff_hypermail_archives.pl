#!/usr/bin/perl

# diff_hypermail_archives
#
# Compare two directories with archives produced by Hypermail.
# Intended primarily to test changes to Hypermail.
#
# Originally written by Peter McCluskey (pcm@rahul.net).
# Rewritten and extended by Jose Kahan (jose.kahan@w3.org).
#
# TODO: If more portability is needed, try switch the sytem
# diff and grep to File::Compare
# https://perldoc.perl.org/File/Compare.html

use strict;
use warnings;

use File::Find;
use FindBin '$Script';
use Cwd qw( abs_path );

use Getopt::Std;

##
## configurable options
##

# path to diff command
our $diff_cmd = "/usr/bin/diff";
# path to grep command
our $grep_cmd= "/bin/grep";

##
## End of configurable options
##

##
## Global variables
##

# don't print progress messages
our $quiet;
# print a "." for each processed file
our $show_progress;
# enable to print extra messages
our $debug;
# ignore all content below the footer trailer
our $ignore_footer;
# hash with filenames|dirnames that must be ignored
our @ignore_files_regex;
# hash with text that must be ignored in the diff output
our @ignore_text_regex;
# thw two dirs that need to be compared
our $dir1;
our $dir2;
# global difference counter (we consider them errors)
our $errors = 0;
# attachmed dir prefix, hard-coded into hypermail
our $attachment_dir_prefix = "att-";
# archive generated by hypermail generated text blurb
our $hmail_generated_by_text = q(This archive was generated by <a.*hypermail-project.org/");
# footer trailer generated by hypermail
our $footer_trailer = q(<!-- trailer="footer" -->);

# returns the line number of the footer or of the generated_by hypermail
# blurb if found
sub get_hypermail_generated_by_lines {
    my $filename = shift;
    my $counter = 0;
    my $expected_counter = ($ignore_footer) ? 1 : 2;
    my %generated_by_lines;
    
    my $needle = $ignore_footer ? $footer_trailer : $hmail_generated_by_text;
    my @grep_args = ($grep_cmd, $ignore_footer ? "-A0" : "-A1", "-n", $needle, $filename);
    
    open (my $fh, "-|", @grep_args) || die("cannot @grep_args\n");
    
    while (my $line = <$fh>) {
	if ($line =~ m/^\d+-?:\ ?/) {
	    my $line_nb = (split /:/, $line)[0];
	    $line_nb =~ s/-$//;
	    $generated_by_lines{$line_nb} = 1;
	    $counter++;
	}
    }
    close ($fh);

    return ($counter == $expected_counter) ? \%generated_by_lines : {};
    
} # get_hypermail_generated_by_lines

# checks if the filenames exist in both directories and the type
sub compare_filenames {
    my ($filename1, $filename2) = @_;
    my $res = 0;
    
    if (!-e $filename2) {
	$errors++;
	$res = -1;
	print "\n" if $show_progress;
	print "[$errors] $filename2 does not exist\n" unless $quiet;
	
    } elsif (-d $filename1) {
	if (!-d $filename2) {
	    print "\n" if $show_progress;
	    print "[$errors] $filename2 is not a directory\n" unless $quiet;
	    $errors++;
	}
	$res = -1;
    }

    return $res;
    
} # compare_filenames

# filter out files we're not interested in
sub filter_filenames {
    my $filename = shift;
    my $res = 0;
    
    foreach my $regex (@ignore_files_regex) {
	if ($filename =~ m/$regex/) {
	    $res = 1;
	    print "$filename is ignored per regex: " . $regex . "\n" if $debug && !$quiet;
	}
    }

    return $res;
    
} # filter_filenames

# filter out text lines we're not interested in
sub filter_text {
    my ($text1, $text2) = @_;
    my $res = 0;
    
    foreach my $regex (@ignore_text_regex) {
	if ($text1 =~ m/$regex/ && $text2 =~ m/$regex/) {
	    $res = 1;
	    print "$text1 is ignored per regex: " . $regex . "\n" unless $quiet;
	}
    }

    return $res;
    
} # filter_text

# does a diff on existing directories, files, and file content
sub diff_files_complete {
    my $file = $_;
    my $filename1 = $File::Find::name;
    my $filename2 = $filename1;
    $filename2 =~ s/$dir1/$dir2/;
    my $generated_by_lines;
    my $footer_line;
    my $diffs = "";
    my $local_errors = 0;
    
    print "." if $show_progress;

    if (compare_filenames ($filename1, $filename2)
	|| filter_filenames ($filename1)) {
	return;
    }

    my $is_attachment_dir =  $filename1 =~ m#/$attachment_dir_prefix#;
    
    if (!$is_attachment_dir) {
	if ($filename1 =~ m/\.html$/) {
	    $generated_by_lines = get_hypermail_generated_by_lines ($filename1);
	    if ($ignore_footer) {
		$footer_line = (keys %{ $generated_by_lines } )[0];
	    }
	}
    }

    print "comparing $filename1\n" if $debug;
    
    my @diff_args = ($diff_cmd, $filename1, $filename2);
    open (my $fh, "-|", @diff_args) || die("cannot diff $filename1 $filename2\n");
    
    while (my $line = <$fh>) {

	chomp $line;
	
	if ($line eq "") {
	    next;
	}

	# for hypermail generated messages and indexes, if the diff
	# finds the the generated_by blurb, we assume that the only
	# things that changed are the version number and/or the
	# generation date. We ignore the rest of the diff output at
	# this point.
	if ($line =~ /^\d/) {
	    if ($line =~ /\d+c\d+/) {
		if (!$is_attachment_dir) {
		    my ($ln_1, $ln_2) = split /c/, $line;
		    
		    # if we have diffs in a series of sequential lines
		    my ($ln_1_1, $ln_1_2) = split /,/, $ln_1;
		    my ($ln_2_1, $ln_2_2) = split /,/, $ln_2;
		    
		    if (%{ $generated_by_lines }
			&& (defined $ln_1_2 && defined $ln_2_2
			    && ($ln_1_2 - $ln_1_1) == ($ln_2_1 - $ln_1_1))
			|| (defined $ln_1_1 && defined $ln_2_1
			    && !defined $ln_1_2 && !defined $ln_2_2)) {

			if ($ignore_footer) {
			    if ($ln_1_1 >= $footer_line) {
				last;
			    }
			} elsif ((!defined $ln_1_2 
				  && $$generated_by_lines{$ln_1_1})
				 || (defined $ln_1_2 
				     && $$generated_by_lines{$ln_1_1}
				     && $$generated_by_lines{$ln_1_2})) {
			    last;
			}
		    }
		}
	    }
	    $local_errors++;
	}
	$diffs .= $line . "\n";
    }
    close ($fh);

    if ($diffs ne "" && !$quiet) {
	$errors++;
	print "\n" if $show_progress;
	print "[$errors] $filename1\n[$errors] $filename2: found $local_errors difference" . ($local_errors == 1 ? "" : "s") . "\n";
	print "$diffs\n";
    }
    
} # diff_files_complete

# only does a diff to see if the same directories and files exist.
# Ignores content differences.
sub diff_files_dir {
    my $filename1 = $File::Find::name;
    my $filename2 = $filename1;
    $filename2 =~ s/$dir1/$dir2/;

    print "." if $show_progress;
    
    compare_filenames ($filename1, $filename2);

    return;
    
} # diff_files

sub process_options {
    my %options=();

    getopts("qhfpdi:v:", \%options);

    $dir1 = $ARGV[0];
    $dir2 = $ARGV[1];

    if (defined $options{d}) {
	$debug = 1;
    }
    if (defined $options{q}) {
	$quiet = 1;
    }

    if (defined $options{p} && !$quiet && !$debug) {
	$show_progress = 1;
    }

    if (defined $options{f}) {
	$ignore_footer = 1;
    }
    
    if (defined $options{h} || !defined $dir1 || !defined $dir2) {
	die ("\nUsage: $Script [-q -h -i foo:bar] dir1 dir2\n"
	     . "\t-q quiet mode\n"
	     . "\t-p show processing progress\n"
	     . "\t-h help prints this message\n"
	     . "\t-f ignore all content below the footer trailer comment\n"
	     . "\t-i list of colon separated regex corresponding to directories/filenames to ignore\n"
	     . "\t-v list of colon separated regex corresponding to text that should be ignored in diff reports\n"
	     . "\tdir1, dir2 paths to the two directories to compare\n\n");
    }
    
    # remove trailing / if given
    $dir1 = abs_path ($dir1);
    $dir2 = abs_path ($dir2);

    if (!defined $dir1 || !-d $dir1) {
	die ("$ARGV[0] is not a directory\n");
    }

    if (!defined $dir2 || !-d $dir2) {
	die ("$ARGV[1] is not a directory\n");
    }    

    if (defined $options{i}) {
	@ignore_files_regex = split (/:/, $options{i});
    }

    if (defined $options{v}) {
	@ignore_text_regex = split (/:/, $options{v});
    }

} # process_options

# main
{
    # read command-line options
    process_options();
    
    my %find_options = ('follow'     => 1,
			'wanted'     => \&diff_files_complete,
	);

    print "\n" unless $quiet;
    print "comparing $dir1 against $dir2\n" unless $quiet;
    print "\n" if $debug && !$quiet;
    
    find(\%find_options, $dir1);

    # do the opposite diff too, to make sure we are not generating new files
    print "\n\n" if $show_progress || $debug;
    
    print "comparing $dir2 filenames against $dir1\n" unless $quiet;

    ($dir1, $dir2) = ($dir2, $dir1);

    $find_options{wanted} = \&diff_files_dir;
    find(\%find_options, $dir1);

    print "\n" if $show_progress;
    print "\n" unless $quiet;
    
    if ($errors) {
	print "=> $dir1 and $dir2 dirs differ: $errors file", $errors > 1 ? "s are" : " is", " different\n\n" unless $quiet;
    } else {
	print "=> Archives are identical\n\n" unless $quiet;
    }
    
    exit (($errors == 0) ? 0 : -1);
    
} # main
