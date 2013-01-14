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
my $debuglevel = 0;				#DEBUGGING VERBOSITY [-1 == SILENT, 2 == VERY VERBOSE]
my $sleeplen = 5;				#LENGTH TO WAIT BETWEEN MAIN LOOPS
my $stablesleeplen = 2;			#LENGTH TO WAIT BETWEEN FILESIZE COMPARISONS IN A GIVEN FOLDER
my $harmless = "false";			#WHETHER OR NOT TO PROHIBIT FILE MODIFICATIONS
my $cleanup = "true";			#WHETHER OR NOT TO DELETE EMPTY DIRECTORIES


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
	$rootpath = realpath($rootpath) . "/";
	
	opendir ROOTDIR, $rootpath or die "Couldn't opern dir '$rootpath': $!";
	
	#PROCESS EACH DIRECTORY FOUND IN ROOT
	while(my $file = readdir(ROOTDIR))
	{
		if($file =~ /^\./) { next; }
		if($file !~ m/$dirfilter/) { if($debuglevel > 1) { print ".......$file didn't pass $dirfilter; skipping\n"; } next; }
		
		my @commandList = ($ZIPPATH);
		if($debuglevel < 1) { push(@commandList, "-q"); }
		push(@commandList, "$temppath$file.zip");

		#SKIP FILES IN THE ROOT DIRECTORY
		my $curdir = "$rootpath$file/";
		unless(-d $curdir) { next; }
		
		#CAN WE ZIP THE DIRECTORY?
		@curdirFileList = ();
		if($debuglevel > 1) { print "......Running subdirectory check with filter $filter on $curdir\n"; }
		my $retval = checkSubDir($curdir, "", $filter);
		
		#DELETE EMPTY DIRECTORY IF WE'VE BEEN TOLD TO
		if(($retval == WARNING_EMPTY_DIR) && ($cleanup eq "true"))
		{
			if($debuglevel > 0) { print "...Cleaning empty directory \"$curdir\" as per request.\n"; }
			rmdir($curdir);
		}
		elsif($retval == ERROR_SUCCESS)
		{
			unless(@curdirFileList) { if($debuglevel > 0) { print "...No matching files found for \"$curdir\". Skipping directory.\n"; } next; }
			push(@commandList, @curdirFileList);
			
			if($debuglevel > 0) { print "...Writing zip file $temppath$file.zip...\n"; }
			if($debuglevel > 1) { print "......Command is: \"@commandList\"\n"; }
			#DIRECTORY IS READY FOR ZIPPING###
			chdir($curdir);
			unless(system(@commandList))
			{
				chdir("$scriptpath");
				if($debuglevel > 0) { print "...Done.\nMoving zip file to output directory... \n"; }
				
				if(move("$temppath$file.zip", "$outpath$file.zip"))
				{
					if($debuglevel > 0) { print "...Done.\n"; }
				}
				
				if($harmless ne "true")
				{
					my $delfile;
					foreach $delfile (@curdirFileList)
					{
						if(unlink("$curdir$delfile")) { if($debuglevel > 1) { print "......Deleted \"$curdir$delfile\"\n"; } }
						else					 { if($debuglevel > 1) { print "......Couldn't delete \"$curdir$delfile\"\n"; }}
						
						#TRY TO DELETE THE DIRECTORY IF IT IS EMPTY
						if(rmdir(dirname("$curdir$delfile"))) { if($debuglevel > 1) { print "......Deleted empty directory \"" . dirname("$curdir$delfile") . "\"\n"; }}
					}
					
				}
			}
			else
			{
				if($debuglevel > 0) { print "...ZIP COMMAND FAILED.\n"; }
			}
			chdir("$scriptpath");
		}
		else
		{
			if($debuglevel > 0) { print "...CheckSubDir failed.\n"; }
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
	
	#BUILD A SIZELIST
	my $dirhandle;
	opendir $dirhandle, "$rootpath$dirpath" or return ERROR_INVALID_HANDLE;
	while(my $file = readdir($dirhandle))
	{
		my $filepath = "$rootpath$dirpath$file";
		
		#IGNORE . DIRECTORIES OR FILES NOT CAUGHT IN OUR REGEX
		if($file =~ /^\./) { next; }
		if($filter ne "") { if($filepath !~ m/$filter/) { next; } }
		
		#IF IT'S A DIRECTORY, SAVE IT FOR LATER
		if(-d $filepath)
		{
			if($debuglevel > 1) { print "......Found directory \"$dirpath$file\"\n"; }
			push(@directories, "$dirpath$file/");
		}
		#IF IT'S A FILE, ADD ITS ORIGINAL SIZE TO THE SIZELIST
		elsif(-e $filepath)
		{
			my $size = -s "$filepath";
			$filesizes{$file}  = $size;
			if($debuglevel > 1) { print "......\"$filepath\" holds size: $size\n"; }
		}
		
	}
	close $dirhandle;

	if(%filesizes)
	{
		#COMPARE THE SIZELIST
		sleep($stablesleeplen);

		opendir $dirhandle, "$rootpath$dirpath" or return ERROR_INVALID_HANDLE;
		while(my $file = readdir($dirhandle))
		{
			my $filepath = "$rootpath$dirpath$file";
		
			if($file =~ /^\./) { next; }
			if($filepattern ne "") { if($file !~ m/$filter/) { next; } }
		
			if(-d $filepath) {}
			elsif(-e $filepath)
			{
				#QUIT IF THE FILE HAS BEEN CREATED OR RESIZED SINCE WE CHECKED LAST
				if(!exists($filesizes{$file}))
				{
					if($debuglevel > 1) { print "......\"$filepath\" has been created since check\n"; }
					return ERROR_EXISTANCE_MISMATCH;
				}
		
				if($filesizes{$file} != -s "$filepath")
				{
					if($debuglevel > 1) { print "......\"$filepath\" fails filesize stability test\n"; }
					return ERROR_SIZE_MISMATCH;
				}
			
				push(@curdirFileList, "$dirpath$file");
			}
		}
		closedir $dirhandle;
	}
	
	if(@directories)
	{
		#IF WE MADE IT HERE, THE FILES IN THIS DIRECTORY ARE RELATIVELY STABLE (READ: PROBABLY FINISHED UPLOADING)
		#CHECK ON SUBDIRECTORIES IF WE HAVE THEM
		my $dir;
		foreach $dir (@directories)
		{
			#PASS A 1 UP THE CHAIN IF FOUND
			if($debuglevel > 1) { print "......Checking subdir $rootpath --> $dir\n"; }
			if(my $retval = checkSubDir($rootpath, $dir, $filter))
			{
				#DELETE EMPTY DIRECTORIES IF WE'VE BEEN TOLD TO
				if(($retval == WARNING_EMPTY_DIR) && ($cleanup eq "true"))
				{
					if($debuglevel > 0) { print "...Cleaning empty directory \"$rootpath$dir\" as per request.\n"; }
					rmdir("$rootpath$dir");
					delete $directories[$dir];
				}
				else
				{
					return $retval;
				}
			}
		}
	}
	
	#IF THIS DIRECTORY IS EMPTY
	if(!@directories && !%filesizes)
	{
		return WARNING_EMPTY_DIR;
	}
	
	return ERROR_SUCCESS;
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
				
				exit;
			}
			case ["-v", "--verbose"]
			{
				$debuglevel = 1;
			}
			case ["-vv"]
			{
				$debuglevel = 2;
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
			default:
			{
			}
		}

		shift(@ARGV);
	}

	##APPEND TRAILING SLASH ONTO DIRECTORIES WHERE NEEDED
	$scriptpath = getcwd();
	if($inpath !~ m/.*\/$/) { $inpath .= "/"; }
	if($temppath !~ m/.*\/$/) { $temppath .= "/"; }
	if($outpath !~ m/.*\/$/) { $outpath .= "/"; }
	
	make_path($temppath);
	make_path($outpath);
	
	if($debuglevel >= 0)
	{
		print "Input path: $inpath\n";
		print "Temporary path: $temppath\n";
		print "Output path: $outpath\n";
		if($debuglevel > 0)
		{
			print "...Pause between loops: $sleeplen\n";
			print "...Pause between filesize checks: $stablesleeplen\n";
		}
		if($harmless eq "true")	{ print "Running in harmless mode.\n"; }
		else			  			{ print "Running in dangerous mode (deleting processed directories).\n"; }
	}

	open(SELF, "<", $0) or die "Cannot open $0 -- $!";
	flock(SELF, LOCK_EX | LOCK_NB) or die "Already running";
	
	while(1)
	{
		if($debuglevel >= 0) { print "CHECKING DIRECTORIES...\n"; }
		
		processRootDir($inpath, $dirpattern, $filepattern);
		
		if($sleeplen == 0) { return; }
		sleep($sleeplen);
	}

	close(SELF);
}


main();
