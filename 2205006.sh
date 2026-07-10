#!/usr/bin/bash

usage(){
	echo "Usage:"
	echo "  bvcs init"
	echo "  bvcs add <file>..."
    	echo "  bvcs status"
    	echo "  bvcs commit -m \"message\""
    	echo "  bvcs log"
    	echo "  bvcs diff [file]"
    	echo "  bvcs restore <file>"
    	echo "  bvcs help"

}

check_repo(){
	if [ ! -d ".bvcs" ]; then
		echo "Error: Not a BVCS repository. Run 'init' first."
		exit 1
	fi
}

init_repo(){
	if [ -d ".bvcs" ]; then
		echo "Error: BVCS repository already exists."
		exit 1
	fi
	mkdir .bvcs
	mkdir .bvcs/objects
	
	touch .bvcs/staging
	touch .bvcs/log
	touch .bvcs/HEAD

	echo "Initialized empty BVCS repository."
}

add_files(){
	if [ $# -eq 0 ]; then
		echo "Error: No files specified."
		return
	fi

	for file in "$@"
	do
		if [ ! -f "$file" ]; then
			echo "Error: '$file' not found."
			continue
		fi

		if grep -qx "$file" .bvcs/staging; then
			echo "Already staged: $file"
			continue
		fi

		echo "$file" >> .bvcs/staging

		echo "Staged: $file"

	done
}

show_status(){
	staged=0
	modified=0
	untracked=0

	head=""
	staged_list=""


	if [ -s ".bvcs/staging" ]; then
		staged_list=$(cat .bvcs/staging)
	fi
	modified_list=""
	if [ -s ".bvcs/HEAD" ]; then
		read -r head < .bvcs/HEAD


		while IFS= read -r snap
		do
			relative="${snap#.bvcs/objects/$head/files/}"

			if grep -qx "$relative" .bvcs/staging 2>/dev/null; then
				continue
			fi
			if [ ! -f "$relative" ]; then
				modified_list="${modified_list}${relative}"$'\n'
				continue
			fi

			if ! diff -q "$snap" "$relative" >/dev/null 2>&1; then
				modified_list="${modified_list}${relative}"$'\n'
			fi
		done < <(find ".bvcs/objects/$head/files" -type f | sort)
		
	fi
	untracked_list=""
	while IFS= read -r file
	do
		relative="${file#./}"

		if grep -qx "$relative" .bvcs/staging 2>/dev/null; then
			continue
		fi

		if [ -n "$head" ] && [ -f ".bvcs/objects/$head/files/$relative" ]; then
			continue
		fi
		
		untracked_list="${untracked_list}${relative}"$'\n'
	done < <(find . -type f ! -path "./.bvcs/*" | sort)

	if [ -n "$staged_list" ]; then
		echo "Staged for commit:"
		printf '%s\n' "$staged_list"
		echo
		staged=1
	fi
	if [ -n "$modified_list" ]; then
		echo "Modified (not staged):"
		printf '%s' "$modified_list" | sort
		echo
		modified=1
	fi
	if [ -n "$untracked_list" ]; then
		echo "Untracked files:"
		printf '%s' "$untracked_list" | sort
		echo
		untracked=1
	fi

	if [ $staged -eq 0 ] && [ $modified -eq 0 ] && [ $untracked -eq 0 ]; then
		echo "Nothing to commit, working tree clean."
	fi

		
}
do_commit(){
	if [ "$1" != "-m" ]; then
		echo 'Error: Commit message required. Use -m "message".'
		return
	fi

	shift

	if [ "$#" -eq 0 ]; then
		echo 'Error: Commit message required. Use -m "message".'
		return
	fi

	msg="$*"

	if [ ! -s .bvcs/staging ]; then
		echo "Error: Nothing to commit."
		return
	fi

	count=$(find .bvcs/objects -mindepth 1 -maxdepth 1 -type d | wc -l)
	next=$((count + 1))
	id=$(printf "%04d" "$next")

	mkdir -p ".bvcs/objects/$id/files"

	if [ -s .bvcs/HEAD ]; then
		read -r head < .bvcs/HEAD
		cp -r ".bvcs/objects/$head/files/." ".bvcs/objects/$id/files/"
	fi

	if [ -s .bvcs/staging ]; then
		while IFS= read -r file
		do
			mkdir -p "$(dirname ".bvcs/objects/$id/files/$file")"
			cp "$file" ".bvcs/objects/$id/files/$file"
		done < .bvcs/staging
	fi
	
	echo "$msg" > ".bvcs/objects/$id/message"

	date +"%Y-%m-%d %H:%M:%S" > ".bvcs/objects/$id/timestamp"

	echo "$id" > .bvcs/HEAD

	echo "$id|$(date +"%Y-%m-%d %H:%M:%S")|$msg" >> ".bvcs/log"

	file_count=$(wc -l < .bvcs/staging)

	: > ".bvcs/staging"

	
	echo "[$id] $msg"
	echo "$file_count file(s) committed."

}
show_log(){

	if [ ! -s .bvcs/log ]; then
		echo "No commits yet."
		return
	fi

	tac .bvcs/log | while IFS="|" read -r id time msg
	do
		echo "commit $id"
		echo "Date: $time"
		echo "Message: $msg"
		echo
	done
}

show_diff(){
	check_repo

	if [ -s .bvcs/HEAD ]; then
		read -r head < .bvcs/HEAD
	else
		echo "Error: No commits yet."
		return
	fi

	if [ "$#" -eq 1 ]; then
		snap=".bvcs/objects/$head/files/$1"

		if [ ! -f "$snap" ]; then
			echo "Error: '$1' is not tracked."
			return
		fi  

		if diff -q "$snap" "$1" >/dev/null; then
			echo "$1: no changes."
		else
			diff -u \
                --label "$snap" \
                --label "$1" \
                "$snap" "$1"
		fi
		return
	fi

	while IFS= read -r snap
	do
		relative="${snap#.bvcs/objects/$head/files/}"

		if diff -q "$snap" "$relative" >/dev/null; then
			echo "$relative: no changes."
		else
			diff -u \
            	--label "$snap" \
                --label "$relative" \
                "$snap" "$relative"
		fi

	done < <(find ".bvcs/objects/$head/files" -type f | sort)
}

restore_file(){
	check_repo

	
	if [ "$#" -ne 1 ]; then
		echo "Error: No file specified."
		return
	fi


	if [ -s .bvcs/HEAD ]; then
		read -r head < .bvcs/HEAD
	else
		echo "Error: No commits yet."
		return
	fi

	snap=".bvcs/objects/$head/files/$1"
	if [ ! -f "$snap" ]; then
		echo "Error: '$1' not found in commit $head."
		return
	fi

	printf "Restore '%s' from commit %s? [y/N]: " "$1" "$head"
    read -r ans
	if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
		mkdir -p "$(dirname "$1")"
		cp "$snap" "$1"
		echo "Restored: $1"
	else
		echo "Aborted."
	fi
			
}


command="$1"

case "$command" in
	init)
		init_repo
		;;
	help)
		usage
		;;
	status)
		check_repo
		show_status
		;;
	add)
		check_repo
		shift
		add_files "$@"
		;;

	commit)
		check_repo
		shift
		do_commit "$@"
		;;

	log)
		check_repo
		show_log
		;;

	diff)
		shift
		show_diff "$@"
		;;

	restore)
		shift
		restore_file "$@"
		;;
	*)
		echo "Error: Unknown subcommand '$command'."
		exit 1
		;;
esac
