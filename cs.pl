#!/usr/bin/perl

use strict;
use File::Copy;
use File::Basename;
use File::Path qw/make_path/;
use Switch;
use Fcntl qw(:flock SEEK_END);



my $ZIPPATH = "/usr/bin/zip";
my $UNZIPPATH = "/usr/bin/unzip";

my $inpath = ".";
my $temppath = ".";
my $outpath = "./out";
#my $dirpattern = "[0-9]{8}\_.*";
my $dirpattern = ".*";
my $filepattern = ".*";
my $harmless = "false";

my $debuglevel = 0;
my $sleeplen = 5;
my $stablesleeplen = 2;

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
		if(-d $file)
		{
			next;
		}
		#CAN WE ZIP THE DIRECTORY?
		@curdirFileList = ();
		if($debuglevel > 1) { print "......Running subdirectory check with filter $filter\n"; }
		if(checkSubDir("$rootpath$file/", $filter) == 0)
		{
			unless(@curdirFileList) { if($debuglevel > 0) { print "...No matching files found for \"$rootpath$file\". Skipping directory.\n"; } next; }
			push(@commandList, @curdirFileList);
			
			if($debuglevel > 0) { print "...Writing zip file $temppath$file.zip...\n"; }
			if($debuglevel > 1) { print "......Command is: \"@commandList\""; }
			#DIRECTORY IS READY FOR ZIPPING###
			unless(system(@commandList))
			{
				if($debuglevel > 0) { print "...Done.\nMoving zip file to output directory...\n"; }
				
				if(move("$temppath$file.zip", "$outpath$file.zip"))
				{
					if($debuglevel > 0) { print "...Done.\n"; }
				}
				
				if($harmless ne "true")
				{
					my $delfile;
					foreach $delfile (@curdirFileList)
					{
						if(unlink($delfile)) { if($debuglevel > 1) { print "......Deleted \"$delfile\"\n"; } }
						else					 { if($debuglevel > 1) { print "......Couldn't delete \"$delfile\"\n"; }}
						
						#TRY TO DELETE THE DIRECTORY IF IT IS EMPTY
						if(rmdir(dirname($delfile))) { if($debuglevel > 1) { print "......Deleted empty directory \"" . dirname($delfile) . "\"\n"; }}
					}
					
				}
			}
			else
			{
				if($debuglevel > 0) { print "...ZIP COMMAND FAILED.\n"; }
			}
		}
	}

	closedir ROOTDIR;
}



###################################################################
## checkSubDir(DirPath, Filter)
## ---------------------------------
## COMPILE A LIST OF FILESIZES IN A SUBDIRECTORY, WAIT TWO SECONDS
## AND COMPARE THEM TO CURRENT FILESIZES [i.e. CHECK FILES ARE
## NOT BEING UPDATED]. RECURSES ON DIRECTORIES
## ... ARGUMENTS ...
##    -- DirPath (A directory path to check)
##    -- Filter (A filename regex filter to limit files/folders checked)
## ... RETURNS ...
##    -- 0 [Success; no files being updated]
##    -- 1 [Failure; filesize mismatch(es)]
##    -- 2 [Failure; new files detected]
###################################################################
sub checkSubDir
{
	my ($dirpath, $filter) = @_;
	
	my $originaldircount;
	my %filesizes;
	my @directories;
	
	#BUILD A SIZELIST
	my $dirhandle;
	opendir $dirhandle, $dirpath or return 3;
	while(my $file = readdir($dirhandle))
	{
		#IGNORE . DIRECTORIES OR FILES NOT CAUGHT IN OUR REGEX
		if($file =~ /^\./) { next; }
		if($filter ne "") { if($file !~ m/$filter/) { next; } }
		
		#IF IT'S A FILE, ADD ITS ORIGINAL SIZE TO THE SIZELIST
		if(-e "$dirpath$file")
		{
			my $size = -s "$dirpath$file";
			$filesizes{$file}  = $size;
			if($debuglevel > 1) { print "......\"$dirpath$file\" holds size: $size\n"; }
		}
		#IF IT'S A DIRECTORY, SAVE IT FOR LATER
		elsif (-d $file)
		{
			push(@directories, "$dirpath$file/");
		}
	}
	close $dirhandle;


	#COMPARE THE SIZELIST
	sleep($stablesleeplen);

	opendir $dirhandle, $dirpath or return 3;
	while(my $file = readdir($dirhandle))
	{
		if($file =~ /^\./) { next; }
		if($filepattern ne "") { if($file !~ m/$filter/) { next; } }

		if(-e "$dirpath$file")
		{
			#QUIT IF THE FILE HAS BEEN CREATED OR RESIZED SINCE WE CHECKED LAST
			if(!exists($filesizes{$file}))
			{
				if($debuglevel > 1) { print "......\"$dirpath$file\" has been created since check\n"; }
				return 2;
			}
		
			if($filesizes{$file} != -s "$dirpath$file")
			{
				if($debuglevel > 1) { print "......\"$dirpath$file\" fails filesize stability test\n"; }
				return 1;
			}
			
			push(@curdirFileList, "$dirpath$file");
		}
	}
	closedir $dirhandle;


	#IF WE MADE IT HERE, THE FILES IN THIS DIRECTORY ARE RELATIVELY STABLE (READ: PROBABLY FINISHED UPLOADING)
	#CHECK ON SUBDIRECTORIES IF WE HAVE THEM
	my $dir;
	foreach $dir (@directories)
	{
		#PASS A 1 UP THE CHAIN IF FOUND
		if(my $retval = checkSubDir($dir, $filter)) { return $retval; }
	}

	return 0;
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
				print "Usage:\ncs.pl [-v|-vv|-q] [-h|--harmless] [(-d|--sleepdelay)] [(-r|--root)=ROOPATH] [(-t|--temppath)=TEMPPATH] [(-o|--outpath)=OUTPUTPATH] [(-f|--root-filter)=FILTER [(-s|--subdirectory-filter)=SUBDIRECTORYFILTER]";
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
			case ["-h", "--harmless"]
			{
				$harmless = "true";
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
	flock(SELF, LOCK_EX) or die "Already running";
	
	while(1)
	{
		if($debuglevel >= 0) { print "CHECKING DIRECTORIES...\n"; }
		
		processRootDir($inpath, $dirpattern, $filepattern);
		sleep($sleeplen);
	}

	close(SELF);
}


main();
