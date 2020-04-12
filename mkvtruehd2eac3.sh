#!/bin/bash
# mkvTRUEHD2EAC3.sh - add an EAC3 track to an MKV from its TRUEHD track
# Author: Jake Wharton <jakewharton@gmail.com>
#         Chris Hoekstra <chris.hoekstra@gmail.com>
#         Gert van Yperenburg 
# Website: http://jakewharton.com
#          http://github.com/JakeWharton/mkvdts2EAC3/
# Version: 2.0.0
# License:
#   Copyright 2011 Jake Wharton
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.


# Display version header
echo "mkvTRUEHD2EAC3-2.0.0 - by Jake Wharton <jakewharton@gmail.com>"
echo "                      Chris Hoekstra <chris.hoekstra@gmail.com>"
echo "						Gert van Yperenburg"
echo

# Debugging flags
# DO NOT EDIT THESE! USE --debug OR --test ARGUMENT INSTEAD.
PRINT=0
PAUSE=0
EXECUTE=1

# Default values
PRIORITY=0
FORCE=0
NOCOLOR=0
MD5=0
INITIAL=0
NEW=0
COMP="none"
WD="/mnt/Downloads" # Working Directory (Use the -w/--wd argument to change)

# These are so you can make quick changes to the cmdline args without having to search and replace the entire script
DUCMD="$(which \du) -k"
RSYNCCMD="$(which \rsync) --progress -a"

# Check for a .mkvTRUEHD2EAC3.rc file in user's home directory for custom defaults
if [ -f ~/.mkvTRUEHD2EAC3.rc ]; then
	. ~/.mkvTRUEHD2EAC3.rc
fi

# Force English output, grepping for messages may fail otherwise
export LC_MESSAGES=C

#---------- FUNCTIONS --------
displayhelp() {
# Usage: displayhelp
	echo "Usage: `basename $0` [options] <filename>"
	echo "Options:"
	echo "     -c TITLE,        Custom EAC3 track title."
	echo "     --custom TITLE"
	echo "     -d, --default    Mark EAC3 track as default."
	echo "     -e, --external   Leave EAC3 track out of file. Does not modify the"
	echo "                      original matroska file. This overrides '-n' and"
	echo "                      '-d' arguments."
	echo "     -f, --force      Force processing when EAC3 track is detected"
	echo "     -i, --initial    New EAC3 track will be first in the file."
	echo "     -k, --keep-TRUEHD   Keep external TRUEHD track (implies '-n')."
	echo "     -m, --nocolor    Do not use colors (monotone)."
	echo "     --md5            Perform MD5 comparison when copying across drives."
	echo "     -n, --no-TRUEHD     Do not retain the TRUEHD track."
	echo "     --new            Do not copy over original. Create new adjacent file."
	echo "     -p PRIORITY      Modify niceness of executed commands."
	echo "     -s MODE,"
	echo "     --compress MODE  Apply header compression to streams (See mkvmerge's --compression)."
	echo "     -t TRACKID,"
	echo "     --track TRACKID  Specify alternate TRUEHD track."
	echo "     -w FOLDER,"
	echo "     --wd FOLDER      Specify alternate temporary working directory."
	echo
	echo "     --test           Print commands only, execute nothing."
	echo "     --debug          Print commands and pause before executing each."
	echo
	echo "     -h, --help       Print command usage."
	echo "     -v, --verbose    Turn on verbose output"
	echo "     -V, --version    Print script version information."
}


# Usage: color shade
function color {
	# Are we in Cron?
	if [ ! -t 0 -o $NOCOLOR = 1 ]; then return 1; fi
	case $1 in
		off|OFF)       echo -n '[0m';;
		red|RED)       echo -n '[1;31m';;
		yellow|YELLOW) echo -n '[1;33m';;
		green|GREEN)   echo -n '[1;32m';;
		blue|BLUE)     echo -n '[1;34m';;
		bell|BELL)     echo -n '';;
		*)             ;;
	esac
}

# Usage: timestamp ["String to preface time display"]
timestamp() {
	CURRTIME=$(date +%s)
	secs=$(($CURRTIME - $PREVTIME))
	PREVTIME=$((CURRTIME))
	h=$(( secs / 3600 ))
	m=$(( ( secs / 60 ) % 60 ))
	s=$(( secs % 60 ))

	if [ $EXECUTE = 1 -a $PAUSE = 0 ]; then
		echo -n "$1 "
		printf "%02d:%02d:%02d " $h $m $s
		echo $"($secs seconds)"
		echo ""
	fi
}

# Usage: error "String to display"
error() {
	color BELL;color RED
	printf "%s: %s\n" $"ERROR" "$1"
	color OFF
}

# Usage: warning "String to display"
warning() {
	color YELLOW
	printf "%s: %s\n" $"WARNING" "$1"
	color OFF
}

info() {
	color BLUE
	printf "%s: %s\n" $"INFO" "$1"
	color OFF
}

# Usage: dopause
dopause() {
	if [ $PAUSE = 1 ]; then
		read
	fi
}

# Usage: checkdep appname
checkdep() {
	if [ -z "$(which $1)" -o ! -x "$(which $1)" ]; then
		error $"The program '$1' is not in the path. Is $1 installed?"
		exit 1
	fi
}

# Usage: cleanup file
cleanup() {
	if [ -f "$1" ]; then
		rm -f "$1"
		if [ $? -ne 0 ]; then
			$"There was a problem removing the file \"$1\". Please remove manually."
			return 1
		fi
	fi
}

# Usage: checkerror $? "Error message to display" [exit on error:BOOL]
checkerror() {
	if [ $1 -ne 0 ]; then
		error "$2"
		# if optional BOOL then exit, otherwise return errorcode 1
		if [ $3 -gt 0 ]; then
			# honor KEEPTRUEHD
			if [ -z $KEEPTRUEHD ]; then
				cleanup "$TRUEHDFILE"
			fi

			cleanup "$EAC3FILE"
			cleanup "$TCFILE"
			exit 1
		fi
		return 1
	fi
}

# Usage: doprint "String to print"
doprint() {
	if [ $PRINT = 1 ]; then
		echo -e "$1"
	fi
}

#---------- START OF PROGRAM ----------
# Start the timer and make a working copy for future timings
START=$(date +%s)
PREVTIME=$(($START))

# Parse arguments and/or filename
while [ -z "$MKVFILE" ]; do

	# If we're out of arguments no filename was passed
	if [ $# -eq 0 ]; then
		error $"You must supply a filename."
		echo ""
		displayhelp
		exit 1
	fi

	case "$1" in
		"-c" | "--custom" ) # Use custom name for EAC3 track
			shift
			TRUEHDNAME=$1
		;;
		"-d" | "--default" ) # Only allow this if we aren't making the file external
			if [ -z $EXTERNAL ]; then
				DEFAULT=1
			fi
		;;
		"-e" | "--external" ) # Don't allow -d or -n switches if they're already set
			EXTERNAL=1
			NOTRUEHD=0
			KEEPTRUEHD=0
			DEFAULT=0
		;;
		"-f" | "--force" ) # Test for EAC3 track exits immediately. Use this to continue
			FORCE=1
		;;
		"-i" | "--initial" ) # Make new EAC3 track the first in the file
			INITIAL=1
		;;
		"-k" | "--keep-TRUEHD" ) # Only allow external TRUEHD track if muxing EAC3 track
			if [ -z $EXTERNAL ]; then
				KEEPTRUEHD=1
			fi
		;;
		"-m" | "--nocolor" | "--monotone" ) # Turns off colors
			NOCOLOR=1
		;;
		"--md5" ) #Perform MD5 comparison when copying across drives
			MD5=1
		;;
		"-n" | "--no-TRUEHD" ) # Only allow this if we aren't making the file external
			if [ -z $EXTERNAL ]; then
				NOTRUEHD=1
			fi
		;;
		"--new" ) # Do not overwrite original. Create new adjacent file.
			NEW=1
		;;
		"-p" ) # Move required priority value "up"
			shift
			PRIORITY=$1
		;;
		"-s" | "--compress" )
			shift
			COMP=$1
		;;
		"-t" | "--track" ) # Move required TRACKID argument "up"
			shift
			TRUEHDTRACK=$1
		;;
		"-w" | "--wd" ) # Specify working directory manually
			shift
			WD=$1
		;;
		"--test" ) # Echo commands and do not execute
			if [ $PAUSE = 1 ]; then
				warning $"--test overrides previous --debug flag."
			fi
			PRINT=1
			EXECUTE=0
		;;
		"--debug" ) # Echo commands and pause before executing
			if [ $EXECUTE = 0 ]; then
				error $"--debug flag not valid with --test."
				displayhelp
				exit 1
			fi
			PRINT=1
			PAUSE=1
			EXECUTE=1
		;;
		"-h" | "--help" )
			displayhelp
			exit 0
		;;
		"-v" | "--verbose" ) # Turn on verbosity
			PRINT=1
		;;
		"-V" | "--version" ) # Version information is always displayed so just exit here
			exit 0
		;;
		-* | --* )
			error $"Invalid argument '$1'."
			echo ""
			displayhelp
			exit 1
		;;
		* )
			MKVFILE=$1
			shift

			# Ensure there are no arguments after the filename
			if [ $# -ne 0 ]; then
				error $"You cannot supply any arguments after the filename. Please check the command syntax below against what has been parsed."
				echo ""
				echo $"Control Flags:"
				printf "  %s: %s" $"Strip TRUEHD:" $NOTRUEHD
				printf "  %s: %s" $"Keep TRUEHD: " $KEEPTRUEHD
				printf "  %s: %s" $"Set EAC3 default: " $DEFAULT
				printf "  %s: %s" $"External EAC3: " $EXTERNAL
				printf "  %s: %s" $"TRUEHD track: " $TRUEHDTRACK
				printf "  %s: %s" $"MKV file: " $MKVFILE
				echo ""
				echo $"Debugging Flags:"
				printf "  %s: %s" $"Print commands:" $PRINT
				printf "  %s: %s" $"Pause after print:" $PAUSE
				printf "  %s: %s" $"Execute commands:" $EXECUTE
				echo ""
				displayhelp
				exit 1
			fi
		;;
	esac

	# Move arguments "up" one spot
	shift
done

# File and dependency checks
if [ $EXECUTE = 1 ]; then
	# Check the file exists and we have permissions
	if [ ! -f "$MKVFILE" ]; then
		error $"'$MKVFILE' is not a file."
		exit 1
	elif [ ! -r "$MKVFILE" ]; then
		error $"Cannot read '$MKVFILE'."
		exit 1
	elif [ -z $EXTERNAL ]; then
		if [ ! -w "$MKVFILE" ]; then
			# Only check write permission if we're not keeping the EAC3 external
			error $"Cannot write '$MKVFILE'."
			exit 1
		fi
	fi

	# Check dependencies
	checkdep mkvmerge
	checkdep mkvextract
	checkdep mkvinfo
	checkdep ffmpeg
	checkdep rsync
	checkdep perl
fi

# Make some adjustments based on the version of mkvtoolnix
MKVTOOLNIXVERSION=$(mkvmerge -V | cut -d " " -f 2 | sed s/\[\^0-9\]//g)
if [ ${MKVTOOLNIXVERSION} -lt 670 ]; then
	AUDIOTRACKPREFIX="audio (A_"
	VIDEOTRACKPREFIX="video (V_"
else
	AUDIOTRACKPREFIX="audio ("
	VIDEOTRACKPREFIX="video ("
fi

# Added check to see if EAC3 track exists. If so, no need to continue
if [ "$(mkvmerge -i "$MKVFILE" | grep -i "${AUDIOTRACKPREFIX}AC-3")" ]; then
	echo $"EAC3 track already exists in '$MKVFILE'."
	echo ""
	if [ $FORCE = 0 ]; then
		info $"Use -f or --force argument to bypass this check."
		exit 1
	fi
	info $"Force mode is on. Continuing..."
fi

# Path to file
DEST=$(dirname "$MKVFILE")

# File name without the extension
NAME=$(basename "$MKVFILE" .mkv)

# Setup temporary files
TRUEHDFILE="$WD/$NAME.TRUEHD"
EAC3FILE="$WD/$NAME.EAC3"
TCFILE="$WD/$NAME.tc"
NEWFILE="$WD/$NAME.new.mkv"

doprint $"MKV FILE: $MKVFILE"
doprint $"TRUEHD FILE: $TRUEHDFILE"
doprint $"EAC3 FILE: $EAC3FILE"
doprint $"TIMECODE: $TCFILE"
doprint $"NEW FILE: $NEWFILE"
doprint $"WORKING DIRECTORY: $WD"

# ------ GATHER DATA ------
# If the track id wasn't specified via command line then search for the first TRUEHD audio track
if [ -z $TRUEHDTRACK ]; then
	doprint ""
	doprint $"Find first TRUEHD track in MKV file."
	doprint "> mkvmerge -i \"$MKVFILE\" | grep -m 1 \"${AUDIOTRACKPREFIX}TRUEHD)\" | cut -d ":" -f 1 | cut -d \" \" -f 3"
	TRUEHDTRACK="TRUEHDTRACK" #Value for debugging
	dopause
	if [ $EXECUTE = 1 ]; then
		TRUEHDTRACK=$(mkvmerge -i "$MKVFILE" | grep -m 1 "${AUDIOTRACKPREFIX}TrueHD" | cut -d ":" -f 1 | cut -d " " -f 3)

		# Check to make sure there is a TRUEHD track in the MVK
		if [ -z $TRUEHDTRACK ]; then
			error $"There are no TRUEHD tracks in '$MKVFILE'."
			exit 1
		fi
	fi
	doprint "RESULT:TRUEHDTRACK=$TRUEHDTRACK"
else
	# Checks to make sure the command line argument track id is valid
	doprint ""
	doprint $"Checking to see if TRUEHD track specified via arguments is valid."
	doprint "> mkvmerge -i \"$MKVFILE\" | grep \"Track ID $TRUEHDTRACK: ${AUDIOTRACKPREFIX}TRUEHD)\""
	VALID=$"VALID" #Value for debugging
	dopause
	if [ $EXECUTE = 1 ]; then
		VALID=$(mkvmerge -i "$MKVFILE" | grep "Track ID $TRUEHDTRACK: ${AUDIOTRACKPREFIX}TRUEHD)")

		if [ -z "$VALID" ]; then
			error $"Track ID '$TRUEHDTRACK' is not a TRUEHD track and/or does not exist."
			exit 1
		else
			info $"Using alternate TRUEHD track with ID '$TRUEHDTRACK'."
		fi
	fi
	doprint "RESULT:VALID=$VALID"
fi
# Get the specified TRUEHD track's information
doprint ""
doprint $"Extract track information for selected TRUEHD track."
doprint "> mkvinfo \"$MKVFILE\""

INFO=$"INFO" #Value for debugging
dopause
if [ $EXECUTE = 1 ]; then
	INFO=$(mkvinfo "$MKVFILE")
	FIRSTLINE=$(echo "$INFO" | grep -n -m 1 "Track number: $TRUEHDTRACK" | cut -d ":" -f 1)
	INFO=$(echo "$INFO" | tail -n +$FIRSTLINE)
	LASTLINE=$(echo "$INFO" | grep -n -m 1 "Track number: $(($TRUEHDTRACK+1))" | cut -d ":" -f 1)
	if [ -z "$LASTLINE" ]; then
		LASTLINE=$(echo "$INFO" | grep -m 1 -n "|+" | cut -d ":" -f 1)
	fi
	if [ -z "$LASTLINE" ]; then
		LASTLINE=$(echo "$INFO" | wc -l)
	fi
	INFO=$(echo "$INFO" | head -n $LASTLINE)
fi
doprint "RESULT:INFO=\n$INFO"

#Get the language for the TRUEHD track specified
doprint ""
doprint $"Extract language from track info."
doprint '> echo "$INFO" | grep -m 1 \"Language\" | cut -d \" \" -f 5'

TRUEHDLANG=$"TRUEHDLANG" #Value for debugging
dopause
if [ $EXECUTE = 1 ]; then
	TRUEHDLANG=$(echo "$INFO" | grep -m 1 "Language" | cut -d " " -f 5)
	if [ -z "$TRUEHDLANG" ]; then
		TRUEHDLANG=$"eng"
	fi
fi
doprint "RESULT:TRUEHDLANG=$TRUEHDLANG"

# Check if a custom name was already specified
if [ -z $TRUEHDNAME ]; then
	# Get the name for the TRUEHD track specified
	doprint ""
	doprint $"Extract name for selected TRUEHD track. Change TRUEHD to EAC3 and update bitrate if present."
	doprint '> echo "$INFO" | grep -m 1 "Name" | cut -d " " -f 5- | sed "s/TRUEHD/EAC3/" | awk '"'{gsub(/[0-9]+(\.[0-9]+)?(M|K)bps/,"6144kbps")}1'"''
	TRUEHDNAME="TRUEHDNAME" #Value for debugging
	dopause
	if [ $EXECUTE = 1 ]; then
		TRUEHDNAME=$(echo "$INFO" | grep -m 1 "Name" | cut -d " " -f 5- | sed "s/TRUEHD/EAC3/" | awk '{gsub(/[0-9]+(\.[0-9]+)?(M|K)bps/,"6144kbps")}1')
	fi
	doprint "RESULT:TRUEHDNAME=$TRUEHDNAME"
fi

# ------ EXTRACTION ------
# Extract timecode information for the target track
doprint ""
doprint $"Extract timecode information for the audio track."
doprint "> mkvextract timecodes_v2 \"$MKVFILE\" $TRUEHDTRACK:\"$TCFILE\""
doprint "> sed -n \"2p\" \"$TCFILE\""
doprint "> rm -f \"$TCFILE\""

DELAY=$"DELAY" #Value for debugging
dopause
if [ $EXECUTE = 1 ]; then
	color YELLOW; echo $"Extracting Timecodes:"; color OFF
	nice -n $PRIORITY mkvextract timecodes_v2 "$MKVFILE" $TRUEHDTRACK:"$TCFILE"
	DELAY=$(sed -n "2p" "$TCFILE")
	cleanup "$TCFILE"
	timestamp $"Timecode extraction took:	"
fi
doprint "RESULT:DELAY=$DELAY"

# Extract the TRUEHD track
doprint ""
doprint $"Extract TRUEHD file from MKV."
doprint "> mkvextract tracks \"$MKVFILE\" $TRUEHDTRACK:\"$TRUEHDFILE\""

dopause
if [ $EXECUTE = 1 ]; then
	color YELLOW; echo $"Extracting TRUEHD Track: "; color OFF
	nice -n $PRIORITY mkvextract tracks "$MKVFILE" $TRUEHDTRACK:"$TRUEHDFILE" 2>&1|perl -ne '$/="\015";next unless /Progress/;$|=1;print "%s\r",$_' #Use Perl to change EOL from \n to \r show Progress %
	checkerror $? $"Extracting TRUEHD track failed." 1
	timestamp $"TRUEHD track extracting took:	"
fi

# ------ CONVERSION ------
# Convert TRUEHD to EAC3
doprint $"Converting TRUEHD to EEAC3."
doprint "> ffmpeg -i \"$TRUEHDFILE\" -acodec eac3 -ac 6 -ab 6144k \"$EAC3FILE\""

dopause
if [ $EXECUTE = 1 ]; then
	color YELLOW; echo $"Converting TRUEHD to EAC3:"; color OFF
	TRUEHDFILESIZE=$($DUCMD "$TRUEHDFILE" | cut -f1) # Capture TRUEHD filesize for end summary
	nice -n $PRIORITY ffmpeg -i "$TRUEHDFILE" -acodec eac3 -ac 6 -ab 6144k "$EAC3FILE" 2>&1|perl -ne '$/="\015";next unless /size=\s*(\d+)/;$|=1;$s='$TRUEHDFILESIZE';printf "Progress: %.0f%\r",450*$1/$s' #run ffmpeg and only show Progress %. Need perl to read \r end of lines
	checkerror $? $"Converting the TRUEHD file to EAC3 failed" 1

	# If we are keeping the TRUEHD track external copy it back to original folder before deleting
	if [ ! -z $KEEPTRUEHD ]; then
		color YELLOW; echo $"Moving TRUEHD track to MKV directory."; color OFF
		$RSYNCCMD "$TRUEHDFILE" "$DEST"
		checkerror $? $"There was an error copying the TRUEHD track to the MKV directory. You can perform this manually from \"$TRUEHDFILE\"." 1
	fi
	cleanup "$TRUEHDFILE"
	echo "Progress: 100%"	#The last Progress % gets overwritten so let's put it back and make it pretty
	timestamp $"TRUEHD track conversion took:	"
fi

# Check there is enough free space for EAC3+MKV
if [ $EXECUTE = 1 ]; then
	MKVFILESIZE=$($DUCMD "$MKVFILE" | cut -f1)
	EAC3FILESIZE=$($DUCMD "$EAC3FILE" | cut -f1)
	WDFREESPACE=$(\df -Pk "$WD" | tail -1 | awk '{print $4}')
	if [ $(($MKVFILESIZE + $EAC3FILESIZE)) -gt $WDFREESPACE ]; then
		error $"There is not enough free space on \"$WD\" to create the new file."
		exit 1
	fi
fi

if [ $EXTERNAL ]; then
	# We need to trick the rest of the script so that there isn't a lot of
	# code duplication. Basically $NEWFILE will be the EAC3 track and we'll
	# change $MKVFILE to where we want the EAC3 track to be so we don't
	# overwrite the MKV file only an EAC3 track
	NEWFILE=$EAC3FILE
	MKVFILE="$DEST/$NAME.EAC3"
else
	# Start to "build" command
	CMD="nice -n $PRIORITY mkvmerge"

	# Puts the EAC3 track as the second in the file if indicated as initial
	if [ $INITIAL = 1 ]; then
		CMD="$CMD --track-order 0:1,1:0"
	fi

	# Declare output file
	CMD="$CMD -o \"$NEWFILE\""

	# If user doesn't want the original TRUEHD track drop it
	if [ $NOTRUEHD ]; then
		# Count the number of audio tracks in the file
		AUDIOTRACKS=$(mkvmerge -i "$MKVFILE" | grep "$AUDIOTRACKPREFIX" | wc -l)

		if [ $AUDIOTRACKS -eq 1 ]; then
			# If there is only the TRUEHD audio track then drop all audio tracks
			CMD="$CMD -A"
		else
			# Get a list of all the other audio tracks
			SAVETRACKS=$(mkvmerge -i "$MKVFILE" | grep "$AUDIOTRACKPREFIX" | cut -d ":" -f 1 | grep -vx "Track ID $TRUEHDTRACK" | cut -d " " -f 3 | awk '{ if (T == "") T=$1; else T=T","$1 } END { print T }')
			# And copy only those
			CMD="$CMD -a \"$SAVETRACKS\""

			# Set header compression scheme for all saved tracks
			while IFS="," read -ra TID; do
				for tid in "${TID[@]}"; do
					CMD="$CMD --compression $tid:$COMP"
				done
			done <<< $SAVETRACKS
		fi
	fi

	# Get track ID of video track
	VIDEOTRACK=$(mkvmerge -i "$MKVFILE" | grep -m 1 "$VIDEOTRACKPREFIX" | cut -d ":" -f 1 | cut -d " " -f 3)
	# Add original MKV file, set header compression scheme
	CMD="$CMD --compression $VIDEOTRACK:$COMP \"$MKVFILE\""


	# If user wants new EAC3 as default then add appropriate arguments to command
	if [ $DEFAULT ]; then
		CMD="$CMD --default-track 0"
	fi

	# If the language was set for the original TRUEHD track set it for the EAC3
	if [ $TRUEHDLANG ]; then
		CMD="$CMD --language 0:$TRUEHDLANG"
	fi

	# If the name was set for the original TRUEHD track set it for the EAC3
	if [ "$TRUEHDNAME" ]; then
		CMD="$CMD --track-name 0:\"$TRUEHDNAME\""
	fi

	# If there was a delay on the original TRUEHD set the delay for the new EAC3
	if [ $DELAY != 0 ]; then
		CMD="$CMD --sync 0:$DELAY"
	fi

	# Set track compression scheme and append new EAC3
	CMD="$CMD --compression 0:$COMP \"$EAC3FILE\""

	# ------ MUXING ------
	# Run it!
	doprint $"Running main remux."
	doprint "> $CMD"
	dopause
	if [ $EXECUTE = 1 ]; then
		color YELLOW; echo $"Muxing EAC3 Track in:"; color OFF
		eval $CMD 2>&1|perl -ne '$/="\015";next unless /(Progress:\s*\d+%)/;$|=1;print "\r",$1' #Use Perl to change EOL from \n to \r show Progress %
		checkerror $? $"Merging the EAC3 track back into the MKV failed." 1
		echo 	#Just need a CR to undo the last \r printed
		timestamp $"Muxing EAC3 track in took:	"
	fi

	# Delete EAC3 file if successful
	doprint $"Removing temporary EAC3 file."
	doprint "> rm -f \"$EAC3FILE\""
	dopause
	cleanup "$EAC3FILE"
fi

# If we are creating an adjacent file adjust the name of the original
if [ $NEW = 1 ]; then
	MKVFILE="$DEST/$NAME-EAC3.mkv"
fi

# Check to see if the two files are on the same device
NEWFILEDEVICE=$(\df "$WD" | tail -1 | cut -d" " -f1)
DSTFILEDEVICE=$(\df "$DEST" | tail -1 | cut -d" " -f1)

if [ "$NEWFILEDEVICE" = "$DSTFILEDEVICE" ]; then
	# If we're working on the same device just move the file over the old one
	if [ "$NEWFILE" = "$MKVFILE" ]; then
		doprint ""
		doprint $"New file and destination are the same. No action is required."
	else
		doprint ""
		doprint $"Moving new file over old one."
		doprint "> mv \"$NEWFILE\" \"$MKVFILE\""
		dopause
		if [ $EXECUTE = 1 ]; then
			info $"Moving new file over old file. DO NOT KILL THIS PROCESS OR YOU WILL EXPERIENCE DATA LOSS!"
			echo $"NEW FILE: $NEWFILE"
			echo $"MKV FILE: $MKVFILE"
			mv "$NEWFILE" "$MKVFILE"
			checkerror $? $"There was an error copying the new MKV over the old one. You can perform this manually by moving '$NEWFILE' over '$MKVFILE'."
		fi
	fi
else
	doprint ""
	doprint $"Copying new file over the old one."
	doprint "> cp \"$NEWFILE\" \"$MKVFILE\""
	dopause

	# Check there is enough free space for the new file
	if [ $EXECUTE = 1 ]; then
		MKVFILEDIFF=$(($($DUCMD "$NEWFILE" | cut -f1) - $MKVFILESIZE))
		DESTFREESPACE=$(\df -k "$DEST" | tail -1 | awk '{print $4*1024}')
		if [ $MKVFILEDIFF -gt $DESTFREESPACE ]; then
			error $"There is not enough free space to copy the new MKV over the old one. Free up some space and then copy '$NEWFILE' over '$MKVFILE'."
			exit 1
		fi

		# Rsync our new MKV with the EAC3 over the old one OR if we're using the -e
		# switch then this actually copies the EAC3 file to the original directory
		info $"Moving new file over old file. DO NOT KILL THIS PROCESS OR YOU WILL EXPERIENCE DATA LOSS!"
		$RSYNCCMD "$NEWFILE" "$MKVFILE"
		checkerror $? $"There was an error copying the new MKV over the old one. You can perform this manually by copying '$NEWFILE' over '$MKVFILE'." 1

		if [ $MD5 = 1 ]; then
			# Check MD5s are equal to ensure the full file was copied (because du sucks across filesystems and platforms)
			OLDFILEMD5=$(md5sum "$NEWFILE" | cut -d" " -f1)
			NEWFILEMD5=$(md5sum "$MKVFILE" | cut -d" " -f1)
			if [ $OLDFILEMD5 -ne $NEWFILEMD5 ]; then
				error $"'$NEWFILE' and '$MKVFILE' files do not match. You might want to investigate!"
			fi
		fi
	fi
	# Remove new file in $WD
	doprint ""
	doprint $"Remove working file."
	doprint "> rm -f \"$NEWFILE\""
	dopause
	cleanup "$NEWFILE"
fi

timestamp $"File copy took:		 	"

# Run through the timestamp function manually to display total execution time
END=$(date +%s)
secs=$(($END - $START))
h=$(( secs / 3600 ))
m=$(( ( secs / 60 ) % 60 ))
s=$(( secs % 60 ))

if [ $EXECUTE = 1 -a $PAUSE = 0 ];then
	color GREEN
	echo -n $"Total processing time:		"
	printf "%02d:%02d:%02d " $h $m $s
	echo $"($secs seconds)"
	color OFF
	echo
fi

NEWFILESIZE=$($DUCMD "$MKVFILE" | cut -f1) # NEWFILESIZE isn't available in some circumstances so just grab it again

# Print final filesize summary
if [ $EXECUTE = 1 -a $PAUSE = 0 ];then
	color YELLOW; printf $"Filesize summary:\n"; color OFF
	printf "%23s %15d KB\n" $"Original Filesize:" $MKVFILESIZE|sed -e :a -e 's/\(.*[0-9]\)\([0-9]\{3\}\)/\1,\2/;ta'
	printf "%23s %15d KB\n" $"Extracted TRUEHD Filesize:" $TRUEHDFILESIZE|sed -e :a -e 's/\(.*[0-9]\)\([0-9]\{3\}\)/\1,\2/;ta'
	printf "%23s %15d KB\n" $"Converted EAC3 Filesize:" $EAC3FILESIZE|sed -e :a -e 's/\(.*[0-9]\)\([0-9]\{3\}\)/\1,\2/;ta'
	printf "%23s %15d KB\n" $"Final Filesize:" $NEWFILESIZE|sed -e :a -e 's/\(.*[0-9]\)\([0-9]\{3\}\)/\1,\2/;ta'
fi
