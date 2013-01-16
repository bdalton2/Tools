#!/usr/bin/perl

use strict;
use File::Copy;
use File::Basename;
use File::Path qw/make_path/;
use Cwd;
use Cwd qw/realpath/;
use Switch;
use Fcntl qw(:flock SEEK_END);

use constant ERROR_SUCCESS			=> 0;
use constant WARNING_EMPTY_DIR 		=> 1;
use constant ERROR_SIZE_MISMATCH 	=> 4;
use constant ERROR_EXISTANCE_MISMATCH => 8;
use constant ERROR_INVALID_HANDLE 	=> 16;

use constant TYPE_FATAL				=> -1;
use constant TYPE_ERROR				=> 0;
use constant TYPE_MESSAGE			=> 1;
use constant TYPE_WARNING			=> 2;
use constant TYPE_INFORMATION		=> 3;
use constant TYPE_DEBUG				=> 4;


my $ZIPPATH = "/usr/bin/zip";
my $UNZIPPATH = "/usr/bin/unzip";

#DIRECTORIES
my $scriptpath = "";
my $inpath = ".";
my $temppath = "/tmp";
my $outpath = "./out";

#FILTERING REGEXES
my $dirpattern = ".*";
my $filepattern = ".*";

#GENERAL OPTIONS
my $debuglevel = TYPE_WARNING;		#DEBUGGING VERBOSITY [TYPE_FATAL == SILENT, TYPE_WARNING=DEFAULT, TYPE_DEBUG == VERY VERBOSE]
my $sleeplen = 5;					#LENGTH TO WAIT BETWEEN MAIN LOOPS
my $stablesleeplen = 2;				#LENGTH TO WAIT BETWEEN FILESIZE COMPARISONS IN A GIVEN FOLDER
my $harmless = "false";				#WHETHER OR NOT TO PROHIBIT FILE MODIFICATIONS
my $cleanup = "true";				#WHETHER OR NOT TO DELETE EMPTY DIRECTORIES
my $robust = "true";					#WHETHER OR NOT TO DIE ON FATAL ERRORS
my $runonce = "true";				#WHETHER OR NOT WE ONLY EVER WANT ONE VERSION OF THE PROGRAM RUNNING AT A TIME


my @curdirFileList;



###################################################################
## processRootDir(RootPath, DirFilter, Filter)
## ---------------------------------
## CHECK THROUGH A GIVEN ROOT DIRECTORY AND ZIP ANY SUBDIRECTORIES
## THAT ARE NOT CURRENTLY BEING UPDATED
## ... ARGUMENTS ...
##    -- RootPath (A directory path to monitor)
##    -- DirFilter (A regex filter on which top-level folders to process)
##    -- Filter (A regex filter to limit sub-files/folders are checked against)
## ... RETURNS ...
##	  -- [None]
###################################################################
sub processRootDir
{
	my ($rootpath, $dirfilter, $filter) = @_;
	#EXPAND ROOTPATH INTO AN ABSOLUTE PATHNAME
	$rootpath = realpath($rootpath) . "/";
	
	
	opendir ROOTDIR, $rootpath or die "Couldn't open dir '$rootpath': $!";
	debugPrint(TYPE_DEBUG, "Searching root dir with filter $filter");
	
	
	#PROCESS EACH DIRECTORY FOUND IN ROOT
	while(my $file = readdir(ROOTDIR))
	{
		my $curdir = "$rootpath$file/";
		
		
		if($file =~ /^\.{1,2}$/) { next; }
		if($file !~ m/$dirfilter/) { debugPrint(TYPE_WARNING, "$file ignored by filter"); next; }
		debugPrint(TYPE_DEBUG, "Checking directory $curdir");
		debugPrint(TYPE_MESSAGE, "Working on $file");
		
		#PREPARE ZIP COMMAND ARGUMENTS TO BE USED WITH system()
		my @commandList = ($ZIPPATH);
		if($debuglevel < 1) { push(@commandList, "-q"); }
		push(@commandList, "$temppath$file.zip");
		
		
		#SKIP FILES IN THE ROOT DIRECTORY
		unless(-d $curdir) { next; }
		
		
		#CAN WE ZIP THE DIRECTORY?
		@curdirFileList = ();
		debugPrint(TYPE_INFORMATION, "Running subdirectory check with filter $filter");
		my $retval = checkSubDir($curdir, "", $filter);
		
		if($retval == ERROR_SUCCESS)
		{
			#IF WE'VE GOT NO FILELIST, DELETE THE DIRECTORY AND MOVE ON
			unless(@curdirFileList)
			{
				debugPrint(TYPE_WARNING, "No matching files found for $curdir; cleaning and skipping directory");
				cleanDirs("$curdir", $filter);
				next;
			}
			#ADD THE FILELIST TO THE LIST SENT TO THE COMPRESSION PROGRAM
			push(@commandList, @curdirFileList);
			
			
			
			#DIRECTORY IS READY FOR ZIPPING
			chdir($curdir);
			debugPrint(TYPE_INFORMATION, "Moving to working directory $file");
			debugPrint(TYPE_DEBUG, "Resolved as: $curdir");
			debugPrint(TYPE_DEBUG, "Command is: \"@commandList\"");
			
			
			#ZIP THE FILES
			unless(system(@commandList))
			{
				chdir("$scriptpath");
				debugPrint(TYPE_DEBUG, "Moving to working directory $scriptpath");
				debugPrint(TYPE_INFORMATION, "Moving zip file to output directory.");
				
				#MOVE THE ZIP FILE INTO THE OUTPUT DIRECTORY
				unless(move("$temppath$file.zip", "$outpath$file.zip"))
				{
					debugPrint(TYPE_ERROR, "Failed copying $temppath$file.zip to $outpath$file.zip");
				}
				
				#CLEAN EVERYTHING UP
				if($harmless ne "true")
				{
					#DELETE ALL FILES ZIPPED
					my $delfile;
					foreach $delfile (@curdirFileList)
					{
						if(unlink("$curdir$delfile")) { debugPrint(TYPE_INFORMATION, "Deleted \"$curdir$delfile\""); }
						else						      { debugPrint(TYPE_WARNING, "Couldn't delete \"$curdir$delfile\""); }
					}
					
					#DELETE ALL DIRECTORIES
					debugPrint(TYPE_MESSAGE, "Cleaning directory $file");
					cleanDirs($curdir, $filter);
				}
			}
			else
			{
				debugPrint(TYPE_ERROR, "Zip command failed");
			}
			chdir("$scriptpath");
		}
		elsif($retval == WARNING_EMPTY_DIR)
		{
			debugPrint(TYPE_MESSAGE, "Cleaning empty directory $file");
			cleanDirs($curdir, $filter);
		}
		else
		{
			debugPrint(TYPE_ERROR, "Checksubdir failed");
		}
	}

	closedir ROOTDIR;
}



###################################################################
## checkSubDir(RootPath, DirPath, Filter)
## ---------------------------------
## COMPILE A LIST OF FILESIZES IN A SUBDIRECTORY, WAIT TWO SECONDS
## AND COMPARE THEM TO CURRENT FILESIZES [i.e. CHECK FILES ARE
## NOT BEING UPDATED]. RECURSES ON DIRECTORIES
## ... ARGUMENTS ...
##    -- RootPath (The root directory)
##    -- DirPath (A directory path to check)
##    -- Filter (A filename regex filter to limit files/folders checked)
## ... RETURNS ...
##    -- 0 [Success; no files being updated]
##    -- 1 [Failure; filesize mismatch(es)]
##    -- 2 [Failure; new files detected]
###################################################################
sub checkSubDir
{
	my ($rootpath, $dirpath, $filter) = @_;
	
	my $originaldircount;
	my %filesizes;
	my @directories;
	
	debugPrint(TYPE_INFORMATION, "Checking subdirectory $dirpath");
	
	
	#BUILD A SIZELIST
	my $dirhandle;
	opendir $dirhandle, "$rootpath$dirpath" or debugPrint(TYPE_FATAL, "Couldn't open $rootpath$dirpath for filesize globbing");
	while(my $file = readdir($dirhandle))
	{
		my $filepath = "$rootpath$dirpath$file";
		
		#IGNORE . DIRECTORIES OR FILES NOT CAUGHT IN OUR REGEX
		if($file =~ /^\.{1,2}$/) { next; }
		if($filter ne "") { if($filepath !~ m/$filter/) { next; } }
		
		#IF IT'S A DIRECTORY, SAVE IT FOR LATER
		if(-d $filepath)
		{
			debugPrint(TYPE_DEBUG, "Pending check on directory $dirpath$file");
			push(@directories, "$dirpath$file/");
		}
		#IF IT'S A FILE, ADD ITS ORIGINAL SIZE TO THE SIZELIST
		elsif(-e $filepath)
		{
			my $size = -s "$filepath";
			$filesizes{$file}  = $size;
			debugPrint(TYPE_DEBUG, "\"$file\" is $size bytes");
		}
		
	}
	close $dirhandle;

	if(%filesizes)
	{
		#COMPARE THE SIZELIST
		sleep($stablesleeplen);

		opendir $dirhandle, "$rootpath$dirpath" or debugPrint(TYPE_FATAL, "Couldn't open $rootpath$dirpath for filesize checks");
		while(my $file = readdir($dirhandle))
		{
			my $filepath = "$rootpath$dirpath$file";
		
			if($file =~ /^\.{1,2}$/) { next; }
			if($filepattern ne "") { if($file !~ m/$filter/) { next; } }
		
			if(-d $filepath) {}
			elsif(-e $filepath)
			{
				#QUIT IF THE FILE HAS BEEN CREATED OR RESIZED SINCE WE CHECKED LAST
				if(!exists($filesizes{$file}))
				{
					debugPrint(TYPE_WARNING, "\"$filepath\" has been created since last check");
					closedir $dirhandle;
					return ERROR_EXISTANCE_MISMATCH;
				}
				
				
				my $val = -s "$filepath";;			#BODGE TO FIX SYNTAX HIGHLIGHTING ERROR WITH -s
				if($filesizes{$file} != $val)
				{
					debugPrint(TYPE_WARNING, "\"$filepath\" has a different filesize");
					closedir $dirhandle;
					return ERROR_SIZE_MISMATCH;
				}
				
				debugPrint(TYPE_DEBUG, "$dirpath$file passed filetest");
				push(@curdirFileList, "$dirpath$file");
			}
		}
		closedir $dirhandle;
	}
	
	
	#IF WE MADE IT HERE, THE FILES IN THIS DIRECTORY ARE RELATIVELY STABLE (READ: PROBABLY FINISHED UPLOADING)
	#CHECK ON SUBDIRECTORIES IF WE HAVE THEM
	my $dir;
	foreach $dir (@directories)
	{
		#PASS UP THE CHAIN IF FOUND
		my $retval = checkSubDir($rootpath, $dir, $filter);
		unless (($retval == WARNING_EMPTY_DIR) || ($retval == ERROR_SUCCESS)) { return $retval; }
	}
	
	#IF THIS DIRECTORY IS EMPTY
	if(!@directories && !%filesizes) { return WARNING_EMPTY_DIR; }
	
	
	return ERROR_SUCCESS;
}



sub cleanDirs
{
	my ($dir, $filter) = @_;
	
	#BUILD A SIZELIST
	my $dirhandle;
	opendir $dirhandle, "$dir" or debugPrint(TYPE_FATAL, "Couldn't open directory $dir for cleaning");
	
	debugPrint(TYPE_DEBUG, "Directory is $dir");
	
	while(my $file = readdir($dirhandle))
	{
		#IGNORE . DIRECTORIES OR FILES NOT CAUGHT IN OUR REGEX
		if($file =~ /^\.{1,2}$/) { next; }
		if($filter ne "") { if("$dir$file" !~ m/$filter/) { next; } }
		
		if(-d "$dir$file")
		{
			cleanDirs("$dir$file/", $filter);
		}
	}
	close $dirhandle;
	
	debugPrint(TYPE_DEBUG, "Deleting root folder [$dir]");
	unless(rmdir("$dir"))
	{
		debugPrint(TYPE_ERROR, "Couldn't delete root folder $dir");
	}
}









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
## main()
## ---------------------------------
## MAIN SUBROUTINE
###################################################################
sub main
{
	while(@ARGV)
	{
		my ($command, $parameter) = split("=", @ARGV[0]);

		switch($command)
		{
			case ["-h", "--help"]
			{
				print "Usage:\ncs.pl [-v|-vv|-q] [-h] [-d] [-r=ROOTPATH] [-t=TEMPPATH] [-o=OUTPUTPATH] [-f=FILTER] [-s=SUBDIRECTORYFILTER]\n";
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
				print "\t-c, --cleanup\n";
				print "\t\tDelete empty directories. Mutually exclusive with --harmless.\n";
				print "\t-r=DIR, --root=DIR\n";
				print "\t\tSet the root path to monitor for incoming directories.\n";
				print "\t\tDEFAULTS TO ./\n";
				print "\t-t=DIR, --temppath=DIR\n";
				print "\t\tSet the path to save temporary files into (i.e. generated zip files before copying).\n";
				print "\t\tDEFAULTS TO /tmp/\n";
				print "\t-o=DIR, --outpath=DIR\n";
				print "\t\tSet the output path (i.e. the path where the zip files will be copied to).\n";
				print "\t\tDEFAULTS TO ./out/\n";
				print "\t-f=REGEX, --root-filter=REGEX\n";
				print "\t\tApply a regex filter to the folders that will be monitored from the root directory.\n";
				print "\t\tDEFAULTS TO \".*\"\n";
				print "\t-s=REGEX, --subdirectory-filter=REGEX\n";
				print "\t\tApply a regex filter to the files/folders under each monitored subdirectory.\n";
				print "\t\tDEFAULTS TO \".*\"\n";
				print "\t-d=TIME, --sleepdelay=TIME\n";
				print "\t\tSet the delay between each execution of the main loop, in seconds (useful for daemons). Set to 0 to disable the loop.\n";
				print "\t\tDEFAULTS TO 5\n";
				print "\t-a=TIME, --stabledelay=TIME\n";
				print "\t\tSet the delay between checking filesizes within each folder, in seconds.\n";
				print "\t\tDEFAULTS TO 2\n\n";
				print "\t-S, --strict\n";
				print "\t\tFail on fatal errors, rather than printing them and trying to move on.\n";
				
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
				$cleanup = "false";
			}
			case ["-c", "--cleanup"]
			{
				$cleanup = "true";
				$harmless = "false";
			}
			case ["-r", "--root"]
			{
				$inpath = $parameter;
			}
			case ["-t", "--temppath"]
			{
				$temppath = $parameter;
			}
			case ["-o", "--outpath"]
			{
				$outpath = $parameter;
			}
			case ["-f", "--root-filter"]
			{
				$dirpattern = $parameter;
			}
			case ["-s", "--subdirectory-filter"]
			{
				$filepattern = $parameter;
			}
			case ["-d", "--sleepdelay"]
			{
				$sleeplen = $parameter;
			}
			case ["-a", "--stabledelay"]
			{
				$stablesleeplen = $parameter;
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

	##APPEND TRAILING SLASH ONTO DIRECTORIES WHERE NEEDED
	$scriptpath = getcwd();
	
	$inpath = realpath($inpath);
	$temppath = realpath($temppath);
	$outpath = realpath($outpath);
	
	if($inpath !~ m/.*\/$/) { $inpath .= "/"; }
	if($temppath !~ m/.*\/$/) { $temppath .= "/"; }
	if($outpath !~ m/.*\/$/) { $outpath .= "/"; }
	
	make_path($temppath);
	make_path($outpath);
	
	if($debuglevel >= 0)
	{
		debugPrint(TYPE_MESSAGE, "Using input path:\t $inpath");
		debugPrint(TYPE_MESSAGE, "Using working path:\t$temppath");
		debugPrint(TYPE_MESSAGE, "Using output path:\t$outpath");
		debugPrint(TYPE_INFORMATION, "Pause between loops: $sleeplen" . ($sleeplen == 0 ? " (Looping disabled)" : ""));
		debugPrint(TYPE_INFORMATION, "Pause between filesize checks: $stablesleeplen");
		
		if($harmless eq "true") { debugPrint(TYPE_MESSAGE, "Running in harmless mode"); }
		else						{ debugPrint(TYPE_WARNING, "Running in dangerous mode (will delete files/directories)"); }
	}

	open(SELF, "<", $0) or die "Cannot open $0 -- $!";
	unless(flock(SELF, LOCK_EX | LOCK_NB))
	{
		debugPrint(TYPE_FATAL, "Already running");
		#THIS IS A SPECIAL CASE OF FATAL ERROR; DIE MANUALLY UNLESS WE REALLY DON'T WANT TO
		if($runonce eq "true")
		{
			$robust = "false";
			debugPrint(TYPE_FATAL, "NOT RUN WITH MULTIPLEINSTANCE PRIVILEGES (-m); QUITTING REGARDLESS OF ROBUST SETTINGS");
			die;
		}
	}
	
	debugPrint(TYPE_MESSAGE, "EXECUTION STARTED");
	while(1)
	{
		debugPrint(TYPE_DEBUG, "Checking directories");
		
		processRootDir($inpath, $dirpattern, $filepattern);
		
		if($sleeplen == 0) { last; }
		sleep($sleeplen);
	}
	
	debugPrint(TYPE_MESSAGE, "EXECUTION FINISHED");

	close(SELF);
}



main();
