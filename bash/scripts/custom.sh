function artisan-clear() {
    # Check if artisan file exists in current directory
    if [ ! -f "artisan" ]; then
        echo "Error: artisan file not found in current directory"
        return 1
    fi

    # Run Laravel clear commands
    php artisan view:clear && \
    php artisan cache:clear && \
    php artisan route:clear && \
    rm -f storage/framework/sessions/*

    if [ $? -eq 0 ]; then
        echo "✓ All caches cleared successfully"
    else
        echo "✗ An error occurred while clearing caches"
        return 1
    fi
}

function pint() {
    # Runs pint on files with status 'M' (Modified) or 'A' (Added)
    svn status | awk '/^[MA]/ {print $2}' | xargs -r vendor/bin/pint
}

# ll, but using octet permissions and human-readable sizes
alias lac='stat --printf="%a %A %s %.19y %U\t%G\t%n\n" $1/* | numfmt --to=iec-i --field=3 --delimiter=" " --suffix=B --padding=6'
# sail shortcut
alias sail='./vendor/bin/sail'
# Add an "alert" alias for long running commands.  Use like so:
#   sleep 10; alert
alias alert='notify-send --urgency=low -i "$([ $? = 0 ] && echo terminal || echo error)" "$(history|tail -n1|sed -e '\''s/^\s*[0-9]\+\s*//;s/[;&|]\s*alert$//'\'')"'
