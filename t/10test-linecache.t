#!/usr/bin/env perl
use strict; use warnings;
use rlib '../lib';

use Test::More;
note( "Testing Devel::Trepan::DB::LineCache" );

BEGIN {
    use English qw( -no_match_vars );
    $PERLDB |= 0x400;
    use_ok( 'Devel::Trepan::DB::LineCache' );
}

note 'Test update_script_cache';
my $lines = "now\nis\nthe\ntime";
my $script_name = '(eval 234)';
update_script_cache($script_name, {string => $lines});
my $ary_ref = $script_cache{$script_name}{lines_href}{plain};
is(join("\n", @$ary_ref), $lines);

note 'Test getlines';

my $file=__FILE__;
# my $line_count = scalar(@{"main::_<$file"});
$lines = getlines(__FILE__);
my $line_count = scalar @$lines;
ok($line_count > __LINE__, "Compare getlines count to __LINE__");

## FIXME: doesn't work:
## use Cwd 'abs_path';
## my $full_file = abs_path(__FILE__);
## $lines = DB::LineCache::getlines($full_file);
## is(scalar @$lines, $line_count, "Compare linecount for full name $full_file");

my $expected_line = 'my $line = getline(__FILE__, __LINE__);';
my $line_number = __LINE__+1;
my $line = getline(__FILE__, __LINE__);
is($line, $expected_line, "Test getline");
remap_file('another_name', __FILE__);
my $another_line = getline('another_name', $line_number);
is($another_line, $expected_line, "Test getline via remap_file");

$expected_line = "\$line = getline(__FILE__, __LINE__,
    {max_continue => 4}
    );";

$line = getline(__FILE__, __LINE__,
    {max_continue => 4}
    );

# use Config;
# if ($Config{archname} eq "x86_64-linux") {
#     diag("FIXME: figure out what's up on travis.");
# } else {
#     is($line, $expected_line, "Test multi-spanning getline line");
# }

# printf "Files cached: %s\n", join(', ', DB::LineCache::cached_files);
# DB::LineCache::update_cache(__FILE__);
## DB::LineCache::checkcache(__FILE__);
# printf "I said %s has %d lines!\n", __FILE__, DB::LineCache::size(__FILE__);

my $sha1 = Devel::Trepan::DB::LineCache::sha1(__FILE__);
like($sha1, qr/^[0-9a-f]+$/,  'Got some sort of SHA1');

note 'filename_is_eval';
eval "is(filename_is_eval(__FILE__), 1, " .
    "'eval(...) should pick up eval filename')";
is($EVAL_ERROR, '', 'no eval error on previous test');
is(filename_is_eval(__FILE__), '',
   '__FILE__ should not be an eval filename');
is(filename_is_eval('-e'), 1,
   '-e should be an eval filename');

note 'map_script';
$DB::filename = '(eval 1)';
my $eval_str = "\$x=1;\n\$y=2;\n\$z=3;\n";
my $filename = map_script($DB::filename, $eval_str);
open(FH, '<', $filename);
undef $INPUT_RECORD_SEPARATOR;
my $got_str = <FH>;
is($got_str, $eval_str, "reading contents temp file $filename");

my $have_codelines = eval("use B::CodeLines; 1") ? 1 : 0;
if ($have_codelines) {
    my $dirname = File::Basename::dirname(__FILE__);
    my $podtest_file = File::Spec->catfile($dirname, '00test-pod.t');

    # FIXME: These two things should be one routine. Also change
    # Load_Subcmd/Source.pm
    load_file($podtest_file);
    update_cache($podtest_file, {use_perl_d_file => 1});

    my @line_nums = trace_line_numbers($podtest_file);
    is($line_nums[0], 7, "trace_line_numbers for $podtest_file");
}

no warnings "once";
Devel::Trepan::DB::LineCache::clear_file_cache();
is(!%Devel::Trepan::DB::file_cache, 1,
   "File cache should be empty");
is(!%Devel::Trepan::DB::file2file_remap, 1,
   "Remapped file cache should be empty");
is(!%Devel::Trepan::DB::file2file_remap_lines, 1,
   "Remapped lines should be empty");

done_testing();
