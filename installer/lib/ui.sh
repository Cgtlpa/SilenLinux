#!/bin/bash

# Simple text-based UI for the Silen installer
# Uses only busybox sh and ANSI escape codes - no whiptail required

# Source this file to use the UI functions

# Detect terminal size
update_term_size() {
    COLS=$(tput cols 2>/dev/null || echo 80)
    LINES=$(tput lines 2>/dev/null || echo 24)
    [ "$COLS" -lt 40 ] && COLS=80
    [ "$LINES" -lt 15 ] && LINES=24
}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
RESET='\033[0m'

# Clear screen
clear_screen() { 
    update_term_size
    echo -ne '\033[2J\033[H'; 
}

# Move cursor
move_cursor() { echo -ne "\033[$1;${2}H"; }

# Hide/show cursor
hide_cursor() { echo -ne '\033[?25l'; }
show_cursor() { echo -ne '\033[?25h'; }

# Draw a box
draw_box() {
    local x=$1 y=$2 w=$3 h=$4 title="$5"
    move_cursor $y $x
    echo -ne "${CYAN}┌${RESET}"
    printf '%*s' $((w-2)) | tr ' ' '─'
    echo -ne "${CYAN}┐${RESET}"
    
    for ((i=1; i<h-1; i++)); do
        move_cursor $((y+i)) $x
        echo -ne "${CYAN}│${RESET}"
        move_cursor $((y+i)) $((x+w-1))
        echo -ne "${CYAN}│${RESET}"
    done
    
    move_cursor $((y+h-1)) $x
    echo -ne "${CYAN}└${RESET}"
    printf '%*s' $((w-2)) | tr ' ' '─'
    echo -ne "${CYAN}┘${RESET}"
    
    if [ -n "$title" ]; then
        move_cursor $y $((x+2))
        echo -ne " ${BOLD}${title}${RESET} "
    fi
}

# Print text at position
print_at() {
    local y=$1 x=$2 text="$3"
    move_cursor $y $x
    echo -ne "$text"
}

# Menu function
# Usage: ui_menu "Title" "Prompt" "opt1" "desc1" "opt2" "desc2" ...
# Returns selected option index (1-based) or 0 for cancel
ui_menu() {
    local title="$1" prompt="$2"
    shift 2
    local options=("$@")
    local num_opts=$(( ${#options[@]} / 2 ))
    local selected=1
    local key
    
    hide_cursor
    clear_screen
    
    local box_w=60
    local box_h=$((num_opts + 6))
    [ $box_w -gt $COLS ] && box_w=$((COLS - 4))
    [ $box_h -gt $LINES ] && box_h=$((LINES - 2))
    local box_x=$(( (COLS - box_w) / 2 ))
    local box_y=$(( (LINES - box_h) / 2 ))
    
    while true; do
        draw_box $box_x $box_y $box_w $box_h "$title"
        
        # Print prompt (wrapped)
        local prompt_x=$((box_x + 2))
        local prompt_y=$((box_y + 2))
        local max_w=$((box_w - 4))
        local line=""
        for word in $prompt; do
            if [ ${#line} -eq 0 ]; then
                line="$word"
            elif [ $((${#line} + 1 + ${#word})) -le $max_w ]; then
                line="$line $word"
            else
                print_at $prompt_y $prompt_x "$line"
                prompt_y=$((prompt_y+1))
                line="$word"
            fi
        done
        [ -n "$line" ] && print_at $prompt_y $prompt_x "$line"
        prompt_y=$((prompt_y+1))
        
        # Print options
        local i
        for ((i=0; i<num_opts; i++)); do
            local opt_idx=$((i*2))
            local desc_idx=$((i*2+1))
            local y=$((prompt_y + 1 + i))
            [ $y -ge $((box_y + box_h - 2)) ] && break
            local prefix="  "
            [ $((i+1)) -eq $selected ] && prefix="${GREEN}→ ${RESET}" || prefix="  "
            print_at $y $((box_x + 3)) "${prefix}${options[opt_idx]}"
            if [ -n "${options[desc_idx]}" ] && [ ${#options[opt_idx]} -lt 18 ]; then
                print_at $y $((box_x + 22)) "${CYAN}${options[desc_idx]}${RESET}"
            fi
        done
        
        # Instructions
        print_at $((box_y + box_h - 2)) $((box_x + 2)) "${YELLOW}↑/↓ or k/j to navigate, Enter to select, q/Esc to cancel${RESET}"
        
        # Read key
        IFS= read -rsn1 key
        case "$key" in
            $'\x1b') # Escape sequence
                IFS= read -rsn2 -t 0.1 key
                case "$key" in
                    '[A') [ $selected -gt 1 ] && selected=$((selected-1)) ;; # Up
                    '[B') [ $selected -lt $num_opts ] && selected=$((selected+1)) ;; # Down
                    *) show_cursor; return 0 ;; # Escape - cancel
                esac
                ;;
            'k') [ $selected -gt 1 ] && selected=$((selected-1)) ;;
            'j') [ $selected -lt $num_opts ] && selected=$((selected+1)) ;;
            '') show_cursor; return $selected ;; # Enter
            'q') show_cursor; return 0 ;; # Quit
        esac
    done
}

# Input box
# Usage: ui_input "Title" "Prompt" "Default"
# Returns input string or empty on cancel
ui_input() {
    local title="$1" prompt="$2" default="$3"
    local input="$default"
    local key
    local pos=${#input}
    
    hide_cursor
    clear_screen
    
    local box_w=60
    [ $box_w -gt $COLS ] && box_w=$((COLS - 4))
    local box_h=8
    local box_x=$(( (COLS - box_w) / 2 ))
    local box_y=$(( (LINES - box_h) / 2 ))
    
    while true; do
        draw_box $box_x $box_y $box_w $box_h "$title"
        print_at $((box_y + 2)) $((box_x + 2)) "$prompt"
        print_at $((box_y + 4)) $((box_x + 3)) " "
        print_at $((box_y + 4)) $((box_x + 4)) "$input"
        move_cursor $((box_y + 4)) $((box_x + 4 + pos))
        print_at $((box_y + 6)) $((box_x + 2)) "${YELLOW}Enter to confirm, Esc to cancel${RESET}"
        
        IFS= read -rsn1 key
        case "$key" in
            $'\x1b')
                IFS= read -rsn2 -t 0.1 key
                show_cursor
                return 0
                ;;
            $'\x7f'|$'\b') # Backspace
                [ $pos -gt 0 ] && input="${input:0:$((pos-1))}" && pos=$((pos-1))
                ;;
            '') # Enter
                echo "$input"
                show_cursor
                return 0
                ;;
            *)
                if [[ "$key" =~ [[:print:]] ]]; then
                    input="${input:0:$pos}${key}${input:$pos}"
                    pos=$((pos+1))
                fi
                ;;
        esac
    done
}

# Password box (hidden input)
# Usage: ui_password "Title" "Prompt"
# Returns password or empty on cancel
ui_password() {
    local title="$1" prompt="$2"
    local input=""
    local key
    local pos=0
    
    hide_cursor
    clear_screen
    
    local box_w=60
    [ $box_w -gt $COLS ] && box_w=$((COLS - 4))
    local box_h=8
    local box_x=$(( (COLS - box_w) / 2 ))
    local box_y=$(( (LINES - box_h) / 2 ))
    
    while true; do
        draw_box $box_x $box_y $box_w $box_h "$title"
        print_at $((box_y + 2)) $((box_x + 2)) "$prompt"
        print_at $((box_y + 4)) $((box_x + 3)) " "
        # Show asterisks
        local stars=$(printf '%*s' ${#input} | tr ' ' '*')
        print_at $((box_y + 4)) $((box_x + 4)) "$stars"
        move_cursor $((box_y + 4)) $((box_x + 4 + pos))
        print_at $((box_y + 6)) $((box_x + 2)) "${YELLOW}Enter to confirm, Esc to cancel${RESET}"
        
        IFS= read -rsn1 key
        case "$key" in
            $'\x1b')
                IFS= read -rsn2 -t 0.1 key
                show_cursor
                return 0
                ;;
            $'\x7f'|$'\b')
                [ $pos -gt 0 ] && input="${input:0:$((pos-1))}" && pos=$((pos-1))
                ;;
            '')
                echo "$input"
                show_cursor
                return 0
                ;;
            *)
                if [[ "$key" =~ [[:print:]] ]]; then
                    input="${input:0:$pos}${key}${input:$pos}"
                    pos=$((pos+1))
                fi
                ;;
        esac
    done
}

# Message box
# Usage: ui_msg "Title" "Message" "type" (type: info, warn, error)
ui_msg() {
    local title="$1" msg="$2" type="${3:-info}"
    local color="$CYAN"
    [ "$type" = "warn" ] && color="$YELLOW"
    [ "$type" = "error" ] && color="$RED"
    
    hide_cursor
    clear_screen
    
    local box_w=60
    [ $box_w -gt $COLS ] && box_w=$((COLS - 4))
    local box_h=8
    local box_x=$(( (COLS - box_w) / 2 ))
    local box_y=$(( (LINES - box_h) / 2 ))
    
    draw_box $box_x $box_y $box_w $box_h "$title"
    
    # Wrap message
    local prompt_x=$((box_x + 2))
    local prompt_y=$((box_y + 2))
    local max_w=$((box_w - 4))
    local line=""
    for word in $msg; do
        if [ ${#line} -eq 0 ]; then
            line="$word"
        elif [ $((${#line} + 1 + ${#word})) -le $max_w ]; then
            line="$line $word"
        else
            print_at $prompt_y $prompt_x "$line"
            prompt_y=$((prompt_y+1))
            line="$word"
        fi
    done
    [ -n "$line" ] && print_at $prompt_y $prompt_x "$line"
    
    print_at $((box_y + box_h - 2)) $((box_x + 2)) "${YELLOW}Press any key to continue...${RESET}"
    
    IFS= read -rsn1 key
    show_cursor
}

# Info box (non-blocking progress)
ui_info() {
    local title="$1" msg="$2"
    clear_screen
    local box_w=60
    [ $box_w -gt $COLS ] && box_w=$((COLS - 4))
    local box_h=6
    local box_x=$(( (COLS - box_w) / 2 ))
    local box_y=$(( (LINES - box_h) / 2 ))
    draw_box $box_x $box_y $box_w $box_h "$title"
    print_at $((box_y + 2)) $((box_x + 3)) "$msg"
}

# Yes/No confirmation
# Usage: ui_confirm "Title" "Message"
# Returns 0 for yes, 1 for no
ui_confirm() {
    local title="$1" msg="$2"
    ui_menu "$title" "$msg" "Yes" "Confirm" "No" "Cancel"
    [ $? -eq 1 ] && return 0 || return 1
}

# Initialize terminal
update_term_size
stty -echoctl 2>/dev/null || true