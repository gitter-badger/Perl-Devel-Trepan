# Perl's Core DB.pm library with some corrections, additions and modifications and
# code merged from perl5db.pl
#
# Documentation is at the __END__
#

use lib '../..';

package DB;
use warnings; no warnings 'redefine';
use English;
use vars qw(@stack $usrctxt $running $caller $eval_result $evalarg
            $event $return_type @ret $ret $return_value @return_value);

use Devel::Trepan::DB::Backtrace;
use Devel::Trepan::DB::Sub;

# "private" globals
my ($ready, $deep, @saved, @skippkg, @clients);
my $preeval = {};
my $posteval = {};
my $ineval = {};

####
#
# Globals - must be defined at startup so that clients can refer to 
# them right after a C<use Devel::Trepan::DB;>
#
####

BEGIN {
    no warnings 'once';
    $ini_warn = $WARNING;
    @ini_INC = @INC;       # Save the contents of @INC before they are modified elsewhere.
    @ini_ARGV = @ARGV;
    $ini_dollar0 = $0;

    # these are hardcoded in perl source (some are magical)
    
    $DB::sub = '';        # name of current subroutine
    %DB::sub = ();        # "filename:fromline-toline" for every known sub
    $DB::single = 0;      # single-step flag (set it to 1 to enable stops in BEGIN/use)
    $DB::signal = 0;      # signal flag (will cause a stop at the next line)
    $DB::trace = 0;       # are we tracing through subroutine calls?

    @DB::args = ();       # arguments of current subroutine or @ARGV array
    @DB::dbline = ();     # list of lines in currently loaded file
    %DB::dbline = ();     # actions in current file (keyed by line number)
    
    # other "public" globals  
    
    $DB::package = '';    # current package space
    $DB::filename = '';   # current filename
    $DB::subname = '';    # currently executing sub (fullly qualified name)
    $DB::lineno = '';     # current line number
    $DB::subroutine = '';
    $DB::hasargs = '';
    $DB::wantarray = '';
    $DB::evaltext = '';
    $DB::is_require = '';
    $DB::hints = '';
    $DB::bitmask = '';
    $DB::hinthash = '';
    $DB::caller = [];
    $DB::eval_result = undef;
    $DB::event = undef;  # The reason we have entered the debugger
    
    $DB::VERSION = '1.03rocky';
    
    # initialize private globals to avoid warnings
    
    $running = 1;         # are we running, or are we stopped?
    @stack = (0);
    @clients = ();
    $ready = 0;
    @saved = ();
    @skippkg = ();
    $usrctxt = '';
    $evalarg = '';
    
    # ensure we can share our non-threaded variables or no-op
    if ($ENV{PERL5DB_THREADED}) {
	require threads;
	require threads::shared;
	import threads::shared qw(share);
	no strict; no warnings;
	$DBGR;
	share(\$DBGR);
	lock($DBGR);
	use strict; use warnings;
	print "Thread support enabled\n";
    } else {
	*lock  = sub(*) {};
	*share = sub(*) {};
    }

    # Used to track the current stack depth using the auto-stacked-variable
    # trick.
    $stack_depth = 0;      # Localized repeatedly; simple way to track $#stack

    # Don't print return values on exiting a subroutine.
    $doret = -2;

    # No extry/exit tracing.
    $frame = 0;
}

####
# this is called by perl for every statement
#
sub DB {

    # lock the debugger and get the thread id for the prompt
    lock($DBGR);
    my $tid;
    if ($ENV{PERL5DB_THREADED}) {
	$tid = eval { "[".threads->tid."]" };
    }

    return unless $ready;
    &save;
    $DB::caller = [caller];
    ($DB::package, $DB::filename, $DB::lineno, $DB::subroutine, $DB::hasargs,
     $DB::wantarray, $DB::evaltext, $DB::is_require, $DB::hints, $DB::bitmask,
     $DB::hinthash
    ) = @{$DB::caller};
    #  print "+++2 ", $evaltext, "\n" if $evaltext;
    
    return if @skippkg and grep { $_ eq $DB::package } @skippkg;
    
    $usrctxt = "package $DB::package;";		# this won't let them modify, alas
    local(*DB::dbline) = "::_<$DB::filename";
    
    my ($stop, $action);
    if (exists $DB::dbline{$DB::lineno} and 
	($stop,$action) = split(/\0/,$DB::dbline{$DB::lineno})) {
	if ($stop eq '1') {
	    $event = 'brkpt';
	    $DB::signal |= 1;
	}
	else {
	    $stop = 0 unless $stop;			# avoid un_init warning
	    $evalarg = "\$DB::signal |= do { $stop; }"; &eval;
	    if ($DB::dbline{$DB::lineno} =~ /;9($|\0)/) {
		$DB::event = 'tbrkpt';
		# clear any temp breakpt
		$DB::dbline{$DB::lineno} =~ s/;9($|\0)/$1/;
	    }
	}
    }
    if ($DB::signal) {
	$event ||= 'signal';
    } elsif ($DB::single & RETURN_EVENT) {
	$event ||= 'return';
    } elsif ($DB::trace  || $DB::single) {
	$event ||= 'line';
    } else {
	$event = 'unknown';
  }
    
    if ($DB::single || $DB::trace || $DB::signal) {
	$DB::subname = ($DB::sub =~ /\'|::/) ? $DB::sub : "${DB::package}::$DB::sub"; #';
	DB->loadfile($DB::filename, $DB::lineno);
    }
    $evalarg = $action, &eval if $action;
    if ($DB::single || $DB::signal) {
	_warnall($#stack . " levels deep in subroutine calls.\n") if $DB::single & 4;
	$DB::single = 0;
	$DB::signal = 0;
	$running = 0;
	
	&eval if ($evalarg = DB->prestop);
	my $c;
	for $c (@clients) {
	    # perform any client-specific prestop actions
	    &eval if ($evalarg = $c->cprestop);
	    
	    # Now sit in an event loop until something sets $running
	    my $after_eval = 0;
      do {
	  # call client event loop; must not block
	  $c->idle($after_eval);
	  $after_eval = 0;
	  if ($running == 2) { 
	      # client wants something eval-ed
	      $eval_result = &DB::eval_with_return if $evalarg;
	      $after_eval = 1;
	      $running = 0;
	  }
      } until $running;
	    
	    # perform any client-specific poststop actions
	    &eval if ($evalarg = $c->cpoststop);
	}
	&eval if ($evalarg = DB->poststop);
    }
    $event = undef;
    ($EVAL_ERROR, $ERRNO, $EXTENDED_OS_ERROR, 
     $OUTPUT_FIELD_SEPARATOR, 
     $INPUT_RECORD_SEPARATOR, 
     $OUTPUT_RECORD_SEPARATOR, $WARNING) = @saved;
    ();
}
  
####
# this takes its argument via $evalarg to preserve current @_
#    
sub eval {
  ($EVAL_ERROR, $ERRNO, $EXTENDED_OS_ERROR, 
   $OUTPUT_FIELD_SEPARATOR, 
   $INPUT_RECORD_SEPARATOR, 
   $OUTPUT_RECORD_SEPARATOR, $WARNING) = @saved;
  eval "$usrctxt $evalarg; &DB::save";
  _warnall($@) if $@;
}

sub eval_with_return {
  no strict;
  ($EVAL_ERROR, $ERRNO, $EXTENDED_OS_ERROR, 
   $OUTPUT_FIELD_SEPARATOR, 
   $INPUT_RECORD_SEPARATOR, 
   $OUTPUT_RECORD_SEPARATOR, $WARNING) = @saved;
  use strict;
  my $eval_result = eval "$usrctxt $evalarg";
  my $EVAL_ERROR_SAVE = $EVAL_ERROR;
  eval "$usrctxt &DB::save";
  if ($EVAL_ERROR_SAVE) {
      _warnall($EVAL_ERROR_SAVE);
      $evalarg = '';
      return undef;
  } else {
      return $eval_result;
  }
}

=head1 RESTART SUPPORT

These routines are used to store (and restore) lists of items in environment 
variables during a restart.

=head2 set_list

Set_list packages up items to be stored in a set of environment variables
(VAR_n, containing the number of items, and VAR_0, VAR_1, etc., containing
the values). Values outside the standard ASCII charset are stored by encoding
then as hexadecimal values.

=cut

sub set_list {
    my ( $stem, @list ) = @_;
    my $val;

    # VAR_n: how many we have. Scalar assignment gets the number of items.
    $ENV{"${stem}_n"} = @list;

    # Grab each item in the list, escape the backslashes, encode the non-ASCII
    # as hex, and then save in the appropriate VAR_0, VAR_1, etc.
    for $i ( 0 .. $#list ) {
        $val = $list[$i];
        $val =~ s/\\/\\\\/g;
        $val =~ s/([\0-\37\177\200-\377])/"\\0x" . unpack('H2',$1)/eg;
        $ENV{"${stem}_$i"} = $val;
    } ## end for $i (0 .. $#list)
} ## end sub set_list

=head2 get_list

Reverse the set_list operation: grab VAR_n to see how many we should be getting
back, and then pull VAR_0, VAR_1. etc. back out.

=cut 

sub get_list {
    my $stem = shift;
    my @list;
    my $n = delete $ENV{"${stem}_n"};
    my $val;
    for $i ( 0 .. $n - 1 ) {
        $val = delete $ENV{"${stem}_$i"};
        $val =~ s/\\((\\)|0x(..))/ $2 ? $2 : pack('H2', $3) /ge;
        push @list, $val;
    }
    @list;
} ## end sub get_list

###############################################################################
#         no compile-time subroutine call allowed before this point           #
###############################################################################

use strict;                # this can run only after DB() and sub() are defined

sub save {
  @saved = ( $EVAL_ERROR, $ERRNO, $EXTENDED_OS_ERROR, 
             $OUTPUT_FIELD_SEPARATOR, 
	     $INPUT_RECORD_SEPARATOR, 
	     $OUTPUT_RECORD_SEPARATOR, $WARNING );

  $OUTPUT_FIELD_SEPARATOR  = ""; 
  $INPUT_RECORD_SEPARATOR  = "\n";
  $OUTPUT_RECORD_SEPARATOR = "";  
  $WARNING = 0;       # warnings off
}

sub catch {
  for (@clients) { $_->awaken; }
  $event = 'interrupt';
  $DB::signal = 1;
  $ready = 1;
}

####
#
# Client callable (read inheritable) methods defined after this point
#
####

sub register {
  my $s = shift;
  $s = _clientname($s) if ref($s);
  push @clients, $s;
}

sub done {
  my $s = shift;
  $s = _clientname($s) if ref($s);
  @clients = grep {$_ ne $s} @clients;
  $s->cleanup;
#  $running = 3 unless @clients;
  exit(0) unless @clients;
}

sub _clientname {
  my $name = shift;
  "$name" =~ /^(.+)=[A-Z]+\(.+\)$/;
  return $1;
}

sub next {
  my $s = shift;
  $DB::single = 2;
  $running = 1;
}

sub step {
  my $s = shift;
  $DB::single = 1;
  $running = 1;
}

sub cont {
  my $s = shift;
  my $i = shift;
  $s->set_tbreak($i) if $i;
  for ($i = 0; $i <= $#stack;) {
	$stack[$i++] &= ~1;
  }
  $DB::single = 0;
  $running = 1;
}

# stop before finishing the current subroutine
sub finish($;$$) {
  my $s = shift;
  # how many levels to get to DB sub?
  my $count = scalar @_ >= 1 ?  shift : 1;
  my $scan_for_DB_sub = scalar @_ >= 1 ?  shift : 1;

  if ($scan_for_DB_sub) {
      my $i = 0;
      while (my ($pkg, $file, $line, $fn) = caller($i++)) {
	  if ('DB::DB' eq $fn or ('DB' eq $pkg && 'DB' eq $fn)) {
	      $i -= 3;
	      last;
	  }
      }
      $count += $i;
  }

  $stack[$#stack-$count] |= (SINGLE_STEPPING_EVENT | RETURN_EVENT);
  $DB::single = 0;
  $running = 1;
}

sub return_value($) 
{
    if ('undef' eq $DB::return_type) {
	return undef;
    } elsif ('array' eq $DB::return_type) {
	return @DB::return_value;
    } else {
	return $DB::return_value;
    }
}

sub return_type($) 
{
    $DB::return_type;
}

sub _outputall {
  my $c;
  for $c (@clients) {
    $c->output(@_);
  }
}

sub _warnall {
  my $c;
  for $c (@clients) {
    $c->warning(@_);
  }
}

sub trace_toggle {
  my $s = shift;
  $DB::trace = !$DB::trace;
}


####
# without args: returns all defined subroutine names
# with subname args: returns a listref [file, start, end]
#
sub subs {
  my $s = shift;
  if (@_) {
    my(@ret) = ();
    while (@_) {
      my $name = shift;
      push @ret, [$DB::sub{$name} =~ /^(.*)\:(\d+)-(\d+)$/] 
	if exists $DB::sub{$name};
    }
    return @ret;
  }
  return keys %DB::sub;
}

####
# first argument is a filename whose subs will be returned
# if a filename is not supplied, all subs in the current
# filename are returned.
#
sub filesubs {
  my $s = shift;
  my $fname = shift;
  $fname = $DB::filename unless $fname;
  return grep { $DB::sub{$_} =~ /^$fname/ } keys %DB::sub;
}

####
# returns a list of all filenames that DB knows about
#
sub files {
  my $s = shift;
  my(@f) = grep(m|^_<|, keys %main::);
  return map { substr($_,2) } @f;
}

####
# returns reference to an array holding the lines in currently
# loaded file
#
sub lines {
  my $s = shift;
  return \@DB::dbline;
}

####
# loadfile($file, $line)
#
sub loadfile {
  my $s = shift;
  my($file, $line) = @_;
  if (!defined $main::{'_<' . $file}) {
    my $try;
    if (($try) = grep(m|^_<.*$file|, keys %main::)) {  
      $file = substr($try,2);
    }
  }
  if (defined($main::{'_<' . $file})) {
    my $c;
#    _outputall("Loading file $file..");
    *DB::dbline = "::_<$file";
    $DB::filename = $file;
    for $c (@clients) {
#      print "2 ", $file, '|', $line, "\n";
      $c->showfile($file, $line);
    }
    return $file;
  }
  return undef;
}

sub lineevents {
  my $s = shift;
  my $fname = shift;
  my(%ret) = ();
  my $i;
  $fname = $DB::filename unless $fname;
  local(*DB::dbline) = "::_<$fname";
  for ($i = 1; $i <= $#DB::dbline; $i++) {
    $ret{$i} = [$DB::dbline[$i], split(/\0/, $DB::dbline{$i})] 
      if defined $DB::dbline{$i};
  }
  return %ret;
}

sub set_break {
  my ($s, $i, $cond) = @_;
  $i ||= $DB::lineno;
  $cond ||= '1';
  $i = _find_subline($i) if ($i =~ /\D/);
  $s->warning("Subroutine not found.\n") unless $i;
  if ($i) {
    if (!defined($DB::dbline[$i]) || $DB::dbline[$i] == 0) {
      $s->warning("Line $i not breakable.\n");
    }
    else {
      $DB::dbline{$i} ||= '';
      $DB::dbline{$i} =~ s/^[^\0]*/$cond/;
      $s->output("Breakpoint set at line $i\n");
    }
  }
}

sub set_tbreak {
  my ($s, $i) = @_;
  $i ||= $DB::lineno;
  $i = _find_subline($i) if ($i =~ /\D/);
  $s->warning("Subroutine not found.\n") unless $i;
  if ($i) {
    if (!defined($DB::dbline[$i]) || $DB::dbline[$i] == 0) {
      $s->warning("Line $i not breakable.\n");
    }
    else {
      $DB::dbline{$i} ||= '';
      $DB::dbline{$i} =~ s/($|\0)/;9$1/; # add one-time-only b.p.
      $s->output("Temporary breakpoint set at line $i\n");
    }
  }
}

sub _find_subline {
    my $name = shift;
    $name =~ s/\'/::/;
    $name = "${DB::package}\:\:" . $name if $name !~ /::/;
    $name = "main" . $name if substr($name,0,2) eq "::";
    if (exists $DB::sub{$name}) {
	my($fname, $from, $to) = ($DB::sub{$name} =~ /^(.*):(\d+)-(\d+)$/);
	if ($from) {
	    local *DB::dbline = "::_<$fname";
	    ++$from while $DB::dbline[$from] == 0 && $from < $to;
	    return $from;
	}
    }
    return undef;
}

sub clr_breaks {
  my $s = shift;
  my $i;
  if (@_) {
    while (@_) {
      $i = shift;
      $i = _find_subline($i) if ($i =~ /\D/);
      $s->output("Subroutine not found.\n") unless $i;
      if (defined $DB::dbline{$i}) {
        $DB::dbline{$i} =~ s/^[^\0]+//;
        if ($DB::dbline{$i} =~ s/^\0?$//) {
          delete $DB::dbline{$i};
        }
      }
    }
  }
  else {
    for ($i = 1; $i <= $#DB::dbline ; $i++) {
      if (defined $DB::dbline{$i}) {
        $DB::dbline{$i} =~ s/^[^\0]+//;
        if ($DB::dbline{$i} =~ s/^\0?$//) {
          delete $DB::dbline{$i};
        }
      }
    }
  }
}

sub set_action {
  my $s = shift;
  my $i = shift;
  my $act = shift;
  $i = _find_subline($i) if ($i =~ /\D/);
  $s->output("Subroutine not found.\n") unless $i;
  if ($i) {
    if ($DB::dbline[$i] == 0) {
      $s->output("Line $i not actionable.\n");
    }
    else {
      $DB::dbline{$i} =~ s/\0[^\0]*//;
      $DB::dbline{$i} .= "\0" . $act;
    }
  }
}

sub clr_actions {
  my $s = shift;
  my $i;
  if (@_) {
    while (@_) {
      my $i = shift;
      $i = _find_subline($i) if ($i =~ /\D/);
      $s->output("Subroutine not found.\n") unless $i;
      if ($i && $DB::dbline[$i] != 0) {
	$DB::dbline{$i} =~ s/\0[^\0]*//;
	delete $DB::dbline{$i} if $DB::dbline{$i} =~ s/^\0?$//;
      }
    }
  }
  else {
    for ($i = 1; $i <= $#DB::dbline ; $i++) {
      if (defined $DB::dbline{$i}) {
	$DB::dbline{$i} =~ s/\0[^\0]*//;
	delete $DB::dbline{$i} if $DB::dbline{$i} =~ s/^\0?$//;
      }
    }
  }
}

sub prestop {
  my ($client, $val) = @_;
  return defined($val) ? $preeval->{$client} = $val : $preeval->{$client};
}

sub poststop {
  my ($client, $val) = @_;
  return defined($val) ? $posteval->{$client} = $val : $posteval->{$client};
}

#
# "pure virtual" methods
#

# client-specific pre/post-stop actions.
sub cprestop {}
sub cpoststop {}

# client complete startup
sub awaken {}

sub skippkg {
  my $s = shift;
  push @skippkg, @_ if @_;
}

sub evalcode {
  my ($client, $val) = @_;
  if (defined $val) {
    $running = 2;    # hand over to DB() to evaluate in its context
    $ineval->{$client} = $val;
  }
  return $ineval->{$client};
}

sub ready {
  my $s = shift;
  return $ready = 1;
}

# stubs
    
sub init {}
sub stop {}
sub idle {}
sub cleanup {}
sub output {}
sub warning {}
sub showfile {}

#
# client init
#
for (@clients) { $_->init }

$SIG{'INT'} = \&DB::catch;

# disable this if stepping through END blocks is desired
# (looks scary and deconstructivist with Swat)
END { $ready = 0 }

1;
__END__

=head1 NAME

DB - programmatic interface to the Perl debugging API

=head1 SYNOPSIS

    package CLIENT;
    use DB;
    @ISA = qw(DB);

    # these (inherited) methods can be called by the client

    CLIENT->register()      # register a client package name
    CLIENT->done()          # de-register from the debugging API
    CLIENT->skippkg('hide::hide')  # ask DB not to stop in this package
    CLIENT->cont([WHERE])       # run some more (until BREAK or another breakpt)
    CLIENT->step()              # single step
    CLIENT->next()              # step over
    CLIENT->finish()            # stop before finishing the current subroutine
    CLIENT->backtrace()         # return the call stack description
    CLIENT->ready()             # call when client setup is done
    CLIENT->trace_toggle()      # toggle subroutine call trace mode
    CLIENT->subs([SUBS])        # return subroutine information
    CLIENT->files()             # return list of all files known to DB
    CLIENT->lines()             # return lines in currently loaded file
    CLIENT->loadfile(FILE,LINE) # load a file and let other clients know
    CLIENT->lineevents()        # return info on lines with actions
    CLIENT->set_break([WHERE],[COND])
    CLIENT->set_tbreak([WHERE])
    CLIENT->clr_breaks([LIST])
    CLIENT->set_action(WHERE,ACTION)
    CLIENT->clr_actions([LIST])
    CLIENT->evalcode(STRING)  # eval STRING in executing code's context
    CLIENT->prestop([STRING]) # execute in code context before stopping
    CLIENT->poststop([STRING])# execute in code context before resuming

    # These methods you should define; They will be called by the DB
    # when appropriate. The stub versions provided do nothing. You should
    # Write your routine so that it doesn't block.

    CLIENT->init()          # called when debug API inits itself
    CLIENT->idle()          # while stopped (can be a client event loop)
    CLIENT->cleanup()       # just before exit
    CLIENT->output(STRING)   # called to print any output that API must show
    CLIENT->warning(STRING) # called to print any warning output that API 
                            # must show
    CLIENT->showfile(FILE,LINE) # called to show file and line before idling

=head1 DESCRIPTION

Perl debug information is frequently required not just by debuggers,
but also by modules that need some "special" information to do their
job properly, like profilers.

This module abstracts and provides all of the hooks into Perl internal
debugging functionality, so that various implementations of Perl debuggers
(or packages that want to simply get at the "privileged" debugging data)
can all benefit from the development of this common code.  Currently used
by Swat, the perl/Tk GUI debugger.

Note that multiple "front-ends" can latch into this debugging API
simultaneously.  This is intended to facilitate things like
debugging with a command line and GUI at the same time, debugging 
debuggers etc.  [Sounds nice, but this needs some serious support -- GSAR]

In particular, this API does B<not> provide the following functions:

=over 4

=item *

data display

=item *

command processing

=item *

command alias management

=item *

user interface (tty or graphical)

=back

These are intended to be services performed by the clients of this API.

This module attempts to be squeaky clean w.r.t C<use strict;> and when
warnings are enabled.


=head2 Global Variables

The following "public" global names can be read by clients of this API.
Beware that these should be considered "readonly".

=over 8

=item  $DB::sub

Name of current executing subroutine.

=item  %DB::sub

The keys of this hash are the names of all the known subroutines.  Each value
is an encoded string that has the sprintf(3) format 
C<("%s:%d-%d", filename, fromline, toline)>.

=item  $DB::single

Single-step flag.  Will be true if the API will stop at the next statement.

=item  $DB::signal

Signal flag. Will be set to a true value if a signal was caught.  Clients may
check for this flag to abort time-consuming operations.

=item  $DB::trace

This flag is set to true if the API is tracing through subroutine calls.

=item  @DB::args

Contains the arguments of current subroutine, or the C<@ARGV> array if in the 
toplevel context.

=item  @DB::dbline

List of lines in currently loaded file.

=item  %DB::dbline

Actions in current file (keys are line numbers).  The values are strings that
have the sprintf(3) format C<("%s\000%s", breakcondition, actioncode)>. 

=item  $DB::package

Package namespace of currently executing code.

=item  $DB::filename

Currently loaded filename.

=item  $DB::subname

Fully qualified name of currently executing subroutine.

=item  $DB::lineno

Line number that will be executed next.

=back

=head2 API Methods

The following are methods in the DB base class.  A client must
access these methods by inheritance (*not* by calling them directly),
since the API keeps track of clients through the inheritance
mechanism.

=over 8

=item CLIENT->register()

register a client object/package

=item CLIENT->evalcode(STRING)

eval STRING in executing code context

=item CLIENT->skippkg('D::hide')

ask DB not to stop in these packages

=item CLIENT->cont()

continue some more (until a breakpoint is reached)

=item CLIENT->step()

single step

=item CLIENT->next()

step over

=item CLIENT->done()

de-register from the debugging API

=back

=head2 Client Callback Methods

The following "virtual" methods can be defined by the client.  They will
be called by the API at appropriate points.  Note that unless specified
otherwise, the debug API only defines empty, non-functional default versions
of these methods.

=over 8

=item CLIENT->init()

Called after debug API inits itself.

=item CLIENT->prestop([STRING])

Usually inherited from DB package.  If no arguments are passed,
returns the prestop action string.

=item CLIENT->stop()

Called when execution stops (w/ args file, line).

=item CLIENT->idle(BOOLEAN)

Called while stopped (can be a client event loop or REPL). If called
after the idle program requested an eval to be performed, BOOLEAN will be
true. False otherwise. See evalcode below

=item CLIENT->poststop([STRING])

Usually inherited from DB package.  If no arguments are passed,
returns the poststop action string.

=item CLIENT->evalcode(STRING)

Usually inherited from DB package. Ask for a STRING to be C<eval>-ed
in executing code context. 

In order to evaluate properly, control has to be passed back to the DB
subroutine. Suppose you would like your C<idle> program to do this:

    until $done {
        $command = read input
        if $command is a valid debugger command, 
           run it
        else 
           evaluate it via CLIENT->evalcode($command) and print
           the results.
    }

Due to the limitation of Perl, the above is not sufficient. You have to 
break out of the B<until> to get back to C<DB::sub> to have the eval run.
After that's done, C<DB::sub> will call idle again, from which you can
then retrieve the results.

One other important item to note is that one can only evaluation reliably
current (most recent) frame and not frames further down the stack.

That's probably why the stock Perl debugger doesn't have
frame-switching commands.

=item CLIENT->cleanup()

Called just before exit.

=item CLIENT->output(LIST)

Called when API must show a message (warnings, errors etc.).


=back


=head1 BUGS

The interface defined by this module is missing some of the later additions
to perl's debugging functionality.  As such, this interface should be considered
highly experimental and subject to change.

=head1 AUTHOR

Gurusamy Sarathy	gsar@activestate.com

This code heavily adapted from an early version of perl5db.pl attributable
to Larry Wall and the Perl Porters.

Further modifications by R. Bernstein rocky@cpan.org

=cut
