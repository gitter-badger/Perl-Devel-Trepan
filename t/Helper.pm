use warnings; use strict;
require Test::More;
use File::Spec;
use File::Basename;
my $trepanpl = File::Spec->catfile(dirname(__FILE__), qw(.. bin trepan.pl));
my $debug = $^W;

package Helper;
use File::Basename qw(dirname); use File::Spec;
use English qw( -no_match_vars ) ;
sub run_debugger($$;$$)
{
    my ($test_invoke, $cmd_filename, $right_filename, $opts) = @_;
    $opts //= {};
    Test::More::note( "running $test_invoke with $cmd_filename" );
    my $run_opts = $opts->{run_opts} || "--basename --nx --no-highlight";
    my $full_cmd_filename = File::Spec->catfile(dirname(__FILE__), 
						'data', $cmd_filename);

    my $ext_file = sub {
        my ($ext) = @_;
        my $new_fn = $full_cmd_filename;
        $new_fn =~ s/\.cmd\z/.$ext/;
        return $new_fn;
    };

    $run_opts .= " --testing $full_cmd_filename" unless ($opts->{no_cmdfile});
    $right_filename = $ext_file->('right') unless defined($right_filename);
    my $cmd = "$EXECUTABLE_NAME $trepanpl $run_opts $test_invoke";
    print $cmd, "\n" if $debug;
    my $output = `$cmd`;
    print $output if $debug;
    my $rc = $? >> 8;
    Test::More::is($rc, 0, 'Debugger command executed successfully');
    open(RIGHT_FH, "<$right_filename");
    undef $INPUT_RECORD_SEPARATOR;
    my $right_string = <RIGHT_FH>;
    ($output, $right_string) = $opts->{filter}->($output, $right_string) if $opts->{filter};
    my $got_filename;
    $got_filename = $ext_file->('got');
    # TODO : Perhaps make sure we optionally use eq_or_diff from 
    # Test::Differences here.
    if (Test::More::ok($right_string eq $output, 'Output comparison')) {
        unlink $got_filename;
    } else {
        open (GOT_FH, '>', $got_filename)
            or die "Cannot open '$got_filename' for writing - $OS_ERROR";
        print GOT_FH $output;
        close GOT_FH;
        Test::More::diag("Compare $got_filename with $right_filename:");
	my $output = `diff -u $right_filename $got_filename 2>&1`;
	my $rc = $? >> 8;
	# GNU diff returns 0 if files are equal, 1 if different and 2
	# if something went wrong. We also should take care of the
	# case where diff isn't installed. So although we expect a 1
	# for GNU diff, we'll also take accept 0, but any other return
	# code means some sort of failure.
	$output = `diff $right_filename $got_filename 2>&1` 
	     if ($rc > 1) || ($rc < 0) ;
        Test::More::diag($output);
    }
    return;
}

1;
