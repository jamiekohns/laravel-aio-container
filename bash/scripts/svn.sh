export SVN_REPO_URL=https://code.sys.cogentco.com/svn/cogent/
export SVN_REPO_USERNAME=jkohns

function svn() {
    # Check if the command is 'status' or 'st'
    if [ "$1" = "status" ] || [ "$1" = "st" ]; then
        GREEN='\033[0;32m'
        ORANGE='\033[0;33m'
        RED='\033[0;31m'
        NC='\033[0m' # No color

        echo -e "${ORANGE}» On $(getSvnInfo branch)${NC}"
        echo -e "${ORANGE}» At revision $(getSvnInfo revision)${NC}"
        echo 
    fi

    # Add support for "svn add -A" to add all unversioned files
    if [ "$1" = "add" ]; then
        # ensure that we are in a project directory
        if [ ! -d ".svn" ]; then
            echo "Error: Not in a SVN project directory"
            return 1
        fi

        # Handle "svn add -A" to add all unversioned files
        if [ "$2" = "-A" ]; then
            # Get list of unversioned files (status starts with ?)
            local unversioned_files=$(command svn status | grep '^?' | awk '{print $2}')
            
            if [ -z "$unversioned_files" ]; then
                echo "No unversioned files to add"
                return 0
            fi
            
            echo "Adding unversioned files:"
            echo "$unversioned_files"
            local svn_bin=$(command -v svn)
            echo "$unversioned_files" | xargs "$svn_bin" add
            return $?
        fi
        
        # Pass through to regular svn add for other cases
        shift
        command svn add "$@"
        return
    fi

    # svn clone [REPO_NAME]
    # repo MUST have /trunk
    # e.g., svn clone project1 will checkout from SVN_REPO_URL/project1/trunk into ./project1
    if [ "$1" = "clone" ]; then
        # ensure that we are in the projects directory
        cd ~/projects || return

        # Prepend SVN_REPO_URL if not already present
        local repo_path="$2"
        if [[ ! "$repo_path" =~ ^"${SVN_REPO_URL}" ]]; then
            repo_path="${SVN_REPO_URL}${repo_path}/trunk"
        else
            repo_path="$2/trunk"
        fi

        command svn checkout "$repo_path" "$2" --username "${SVN_REPO_USERNAME}"
        return
    fi

    # Run the actual svn command with all arguments
    command svn "$@"
}

function getSvnInfo() {
    local parameter="$1"
    local info=$(svn info 2>/dev/null)
    if [ -z "$info" ]; then
        echo "Not an SVN repository"
        return 1
    fi

    case "$parameter" in
        url)
            echo "$info" | grep '^URL:' | awk '{print $2}'
            ;;
        revision)
            echo "$info" | grep '^Revision:' | awk '{print $2}'
            ;;
        branch)
            local url=$(echo "$info" | grep '^URL:' | awk '{print $2}')
            # Extract the branch name from the URL
            if [[ "$url" =~ /trunk$ ]]; then
                echo "trunk"
            elif [[ "$url" =~ /branches/([^/]+) ]]; then
                echo "/branches/${BASH_REMATCH[1]}"
            elif [[ "$url" =~ /tags/([^/]+) ]]; then
                echo "/tags/${BASH_REMATCH[1]}"
            else
                echo "Unknown branch"
            fi
            ;;
        *)
            echo "Usage: getSvnInfo [url|revision|branch]"
            return 1
            ;;
    esac
}