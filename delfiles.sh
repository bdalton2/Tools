#!/bin/bash

#DELFILES.sh
#Basic script to delete pdf files in directory SOURCE, AGE days old and matching the REGEX regular expression.
#
# USAGE
# ./delfiles.sh harmless [source [age [regex]]]
#
# DEFAULTS
# harmless -- a literal argument that causes the script to not delete anything, merely returning
#             the files that would have been deleted (harmless)
# SOURCE -- current dir (.)
# AGE    -- ten days (10)
# REGEX  -- pdf documents with hyphen-separated hexadecimal names ([-0-9A-F]*.pdf)



#SNARF PROVIDED ARGUMENTS [OR SET DEFAULTS]
# CHECK FOR HARMLESS
HARMLESS=$1
if [ "$HARMLESS" == "harmless" ]
then
	shift
fi

#SOURCE
var=$1
if [ -z "$var" ]
then
	var="."
fi
SOURCE="$var"

# AGE
var=$2
if [ -z "$var" ]
then
	var="10"
fi
AGE="$var"

# REGEX
var=$3
if [ -z "$var" ]
then
	var="[-0-9A-F]*.pdf"
fi
REGEX=".*/$var"

#SEARCH AND DESTROY
if [ "$HARMLESS" == "harmless" ]
then
	files=`/usr/bin/find $SOURCE -iregex "$REGEX" -mtime +$AGE -print`
	echo "FILES THAT WOULD BE DELETED:"
	echo $files | tr ' ' '\n'
	echo ""
	echo "TOTAL COUNT: "
	echo $files | tr ' ' '\n' | wc -l
else
	echo "NOT HARMLESS"
	/usr/bin/find $SOURCE -iregex "$REGEX" -mtime +$AGE -delete
fi
