#!/usr/bin/perl

use strict;
use Switch;
use Fcntl qw(:flock SEEK_END);

use constant ERROR_SUCCESS			=> 0;

use constant TYPE_FATAL				=> -1;
use constant TYPE_ERROR				=> 0;
use constant TYPE_MESSAGE			=> 1;
use constant TYPE_WARNING			=> 2;
use constant TYPE_INFORMATION		=> 3;
use constant TYPE_DEBUG				=> 4;

#GENERAL OPTIONS
my $debuglevel = TYPE_WARNING;		#DEBUGGING VERBOSITY [TYPE_FATAL == SILENT, TYPE_DEBUG == VERY VERBOSE]
my $harmless = "false";				#WHETHER OR NOT TO PROHIBIT FILE MODIFICATIONS
my $robust = "true";					#WHETHER OR NOT TO CONTINUE ON FATAL ERRORS
my $runonce = "true";				#WHETHER OR NOT WE ONLY EVER WANT ONE VERSION OF THE PROGRAM RUNNING AT A TIME


#START THE SCRIPT
insertionPoint();


###################################################################
## debugPrint(ErrorLevel, Message)
## ---------------------------------
## PRINT A FORMATTED MESSAGE FOR GIVEN INFORMATION, WARNING OR
## ERROR LEVEL IF CAUGHT IN THE CURRENT VERBOSITY LEVEL. DIES
## ON FATAL ERRORS WHERE REQUESTED
## ... ARGUMENTS ...
##    -- ErrorLevel (The importance of the message)
##    -- The message to display
###################################################################
sub debugPrint
{
	
	my ($level, $message) = @_;
	
	if($level == TYPE_FATAL)
	{
		print("\n#####################################\n");
		print("## FATAL ERROR: $message [$!]\n");
		if($robust eq "true") { print("## (Robust enabled; continuing regardless)\n"); }
		print("#####################################\n\n");
		if($robust eq "false") { die; } else { return; }
	}
	
	unless($level <= $debuglevel) { return; };
	
	switch($level)
	{
	case [TYPE_INFORMATION] { print "Information:\t\t"; }
	case [TYPE_MESSAGE] { print "Message:\t\t"; }
	case [TYPE_WARNING] { print "WARNING:\t\t"; }
	case [TYPE_ERROR] { print "***ERROR:\t\t"; }
	case [TYPE_DEBUG] { print "-debug- "; }
	}
	print "$message\n";
}



###################################################################
## insertionPoint()
## ---------------------------------
## Handles input switches and main loops before custom code is run
## ... RETURNS ...
##    -- The value of the main() routine
###################################################################
sub insertionPoint
{
	while(@ARGV)
	{
		my ($command, $parameter) = split("=", @ARGV[0]);

		switch($command)
		{
			case ["-h", "--help"]
			{
				print "Usage:\n$0 [-v|-vv|-q] [-h] [-b] [-S] [-m]\n";
				print "\t-v, --verbose\n";
				print "\t\tVerbose mode.\n";
				print "\t-vv\n";
				print "\t\tVery-verbose mode.\n";
				print "\t-q, --quiet\n";
				print "\t\tSilent (quiet) mode.\n";
				print "\t-h, --help\n";
				print "\t\tShow this help screen.\n";
				print "\t-b, --begnign --harmless\n";
				print "\t\tHarmless mode; don't modify existing files. Mutually exclusive with --cleanup.\n";
				print "\t-S, --strict\n";
				print "\t\tFail on fatal errors, rather than printing them and trying to move on.\n";
				print "\t-m, --multiple-instances\n";
				print "\t\tAllow this script to be run more than once simultaneously.\n";
				
				exit;
			}
			case ["-v", "--verbose"]
			{
				$debuglevel = TYPE_INFORMATION;
			}
			case ["-vv"]
			{
				$debuglevel = TYPE_DEBUG;
			}
			case ["-q", "--quiet"]
			{
				$debuglevel = -1;
			}
			case ["-b", "--begnign", "--harmless"]
			{
				$harmless = "true";
			}
			case ["-S", "--strict"]
			{
				$robust = "false";
			}
			case ["-m", "--multiple-instances"]
			{
				$runonce = "false";
			}
			default:
			{
			}
		}

		shift(@ARGV);
	}
	
	if($harmless eq "true") { debugPrint(TYPE_MESSAGE, "Running in harmless mode"); }
	else						{ debugPrint(TYPE_WARNING, "Running in dangerous mode (will delete files/directories)"); }
	
	
	
	##MAKE SURE WE DON'T RUN MORE THAN ONCE UNLESS SPECIFICALLY REQUESTED
	open(SELF, "<", $0) or die "Cannot open $0 -- $!";
	unless(flock(SELF, LOCK_EX | LOCK_NB))
	{
		debugPrint(TYPE_FATAL, "Already running");
		#THIS IS A SPECIAL CASE OF FATAL ERROR; DIE MANUALLY UNLESS WE REALLY DON'T WANT TO
		if($runonce eq "true")
		{
			$robust = "false";
			debugPrint(TYPE_FATAL, "NOT RUN WITH MULTIPLEINSTANCE PRIVILEGES (-m); QUITTING REGARDLESS OF ROBUST SETTINGS");
		}
	}
	
	debugPrint(TYPE_INFORMATION, "EXECUTION STARTED");
	my $retval = main();
	debugPrint(TYPE_INFORMATION, "EXECUTION FINISHED");

	close(SELF);
	
	
	return $retval;
}








###################################################################
## main()
## ---------------------------------
## Custom main routine
## ... RETURNS ...
##    -- 1
###################################################################
sub main
{
	#CODE GOES HERE
	
	return 1;
}
