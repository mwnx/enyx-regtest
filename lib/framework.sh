#!/bin/bash

# = Regression/Integration Test Framework

set -euo pipefail

. "$(readlink -m "$BASH_SOURCE/..")"/utils.sh

# Check dependencies.
command -v column &>/dev/null || {
    regtest_printn >&2 '%s %s' 'Error: Required command `column` not found.' \
                               'Try installing `bsdmainutils`.'
    exit 1
}

# List of found tests (newline-delimited).
_regtest_found_file=$_regtest_tmp/found

# List of unmatched globs (newline-delimited).
_regtest_unmatched_glob_file=$_regtest_tmp/unmatched-globs

# Test statuses (newline-delimited).
# Record format: `<suite> <test> <status> <failure-detail> <time>`.
_regtest_status_file=$_regtest_tmp/statuses

## regtest_ref_checksum <path> (monkey-patchable)
# Print a checksum for the reference file at path <path>. May be used by 'regtest_ref_diff' to
# compare reference and output files. By default, don't print anything.
regtest_ref_checksum() { true; }

## regtest_out_checksum <path> (monkey-patchable)
# Print a checksum for the output file at path <path>. May be used by 'regtest_ref_diff' to
# compare reference and output files. By default, don't print anything.
regtest_out_checksum() { true; }

## regtest_ref_diff <filename> (monkey-patchable)
# Compare the reference and output files with name <name>. Returns 0 if files are identical, 1 if
# they differ, and something else if some error occurred. Does not output a diff. By default, just
# performs a (silent) diff, or if both 'regtest_ref_checksum' and 'regtest_out_checksum' print a
# non-empty string (assumed to be a checksum), compares those checksums.
regtest_ref_diff() {
    local out_name=$1 ref=$regtest_refdir/$out_name out=$regtest_outdir/$out_name
    local ref_sum out_sum

    ref_sum=$(regtest_ref_checksum "$regtest_refdir/$out_name") || return $_regtest_ret_fatal
    out_sum=$(regtest_out_checksum "$regtest_outdir/$out_name") || return $_regtest_ret_fatal

    if [[ -z "$ref_sum" || -z "$out_sum" ]]; then
        diff -qr "$ref" "$out" >/dev/null || {
            if [[ $? == 1 ]]; then return 1
            else return $_regtest_ret_fatal
            fi
        }
    else
        [[ "$ref_sum" == "$out_sum" ]]
    fi
}

regtest_print_and_run() {
    regtest_printn >&2 '\e[1m>>>\e[0m %s' "$*"
    "$@"
}

## regtest_ref_compare_impl <output-filename> (monkey-patchable)
# Compare a reference and an output – implementation. Outputs full log to stdout, partial log and
# info messages to stderr.
regtest_ref_compare_impl() {
    local out_name=$1
    local ref=$regtest_refdir/$out_name
    local out=$regtest_outdir/$out_name

    # The `2>&1` and `| cat` below are there to force the process substitution (`>(...)`) to exit
    # before the function does, and for that reason alone.
    regtest_diff "$ref" "$out" | tee >(head -n30 >&2; cat >/dev/null 2>&1) | cat || return 1
    return 0
}

## regtest_ref_compare <output-filename> (monkey-patchable)
# Compare a reference and an output. The full log is written in the log directory to a
# `.comparison` file while the partial log is printed to stderr. It is expected that the partial
# log generated by 'regtests_ref_compare_impl' will be sent to stderr while the full log will be
# sent to stdout. To implement a custom comparison function, it is usually best to monkey-patch
# 'regtest_ref_compare_impl' rather than this function.
regtest_ref_compare() {
    local out_name=$1
    local full_log=$regtest_logdir/$regtest_session/$_name.comparison
    regtest_ref_compare_impl "$out_name" >"$full_log" || {
        regtest_printn '\e[1;2m------------ 8< ------------\e[0m'
        regtest_printn '\e[1mThis is a partial comparison.\e[0m'
        regtest_printn 'Full diff: less -R %s' "$full_log"
        return 1
    }
}

# _regtest_check_test_name <name>
# Returns:
#
# - 2 if the name is not valid; otherwise
# - 0 if it matches matches a glob in 'regtest_globs', and does not match a glob in
#   'regtest_exclude_globs'; otherwise
# - 1 (valid but does not match).
_regtest_check_test_name() {
    local name=$1 name_only glob

    [[ "$name" < 0 ]] && {
        regtest_printn >&2 'Error: Bad test name: %s. Cannot start with punctuation.' "$name"
        return 2
    }
    [[ "$name" =~ $regtest_name_regex ]] || {
        regtest_printn >&2 'Error: Bad test name: %s. Was expected to match %s' \
                           "$name" "$regtest_name_regex"
        return 2
    }

    name_only=${BASH_REMATCH[1]}

    for glob in ${regtest_exclude_globs+"${regtest_exclude_globs[@]}"}; do
        [[ "$name_only" == $glob || "$name" == "$glob" ]] && return 1
    done
    [[ -e "$_regtest_unmatched_glob_file" ]] ||
        printf '%s\n' "${regtest_globs[@]}" >"$_regtest_unmatched_glob_file"
    for glob in "${regtest_globs[@]}"; do
        [[ "$name_only" == $glob || "$name" == "$glob" ]] && {
            regtest_remove_line_from_file "$_regtest_unmatched_glob_file" "$glob"
            return 0
        }
    done
    return 1
}

declare _name
declare _outputs
declare _tmpfiles
declare -a _extra_args

## regtest <name> [options] <command...>
# Define a single test named <name>, that will run <command...>. The test name must match the bash
# regex 'regtest_name_regex' (default: `^([a-z0-9-]+)$` (i.e. only alphanumeric characters and
# hyphens allowed)). Options may be provided after the name and before the command to alter the
# 'regtest' function's behaviour. The command itself is an (almost) ordinary shell command and its
# arguments. Shell functions are accepted just as well as executables. The command is run in a
# subshell however and can therefore not alter variables within the test suite's body itself. As
# detailed below, the command may contain special patterns `{}`, `{out.<ext>}`, and `{tmp.<ext>}`
# which will be replaced by directory of file paths by the 'regtest' function.
#
# Note: Since <command...> is an argument list, shell operators such as `&&`, `||`, and `$(...)`
# cannot be used directly as part of the command. If you need to use such constructs, you can
# either use one of the helpers defined in `utils-extra.sh` (e.g. 'regtest_run_in_sequence' as a
# replacement for `&&`) or define a separate shell function that performs the desired logic, and
# use it as the <command>. The latter solution has the drawback that printing the command with
# `run-tests`'s `-p` option will naturally only print said function's name (and its arguments),
# not its contents.
#
# Special patterns:
#
#     {}::
#         The current input directory: `$REGTEST_INPUTDIR/$regtest_dir`. 'REGTEST_INPUTDIR' is an
#         environment variable, and 'regtest_dir' is a test-suite-local shell variable.
#         'regtest_dir' may be left undefined and need not be static; it is permitted to redefine
#         it as many times as needed inside a test suite.
#     {out.<ext>}::
#         An output file, composed of the test's name and a custom extension, <ext>. A test may
#         have multiple such output files (with distinct extensions). They are placed in
#         `$REGTEST_OUTDIR` (`./out` by default). After the command has been run, if it returned
#         error code 0 (success), each of these output files will be compared to reference files
#         bearing the same names in the directory `$REGTEST_REFDIR` (`./refs` by default). Unless
#         the test fails, these files are deleted at the end of the test.
#     {tmp.<ext>}::
#         A temporary file with extension <ext>. 'tmp' patterns with same extension will refer to
#         the same file. Unlike 'out' patterns, these files will not be compared to reference
#         files. They are placed in directory the `$REGTEST_TMPDIR` (`$REGTEST_OUTDIR/tmp` by
#         default). All temporary files are deleted at the end of the test.
#
# Options:
#
#     --warn-only=<n>::
#         Don't count failure towards the test script's exit status. The failure will still be
#         reported right after the test's execution and in the test's summary line (albeit marked
#         as `(ignored)`). This is useful for instance if a test succeeds or fails inconsistently
#         and can't be fixed right away.
# //TODO
# //    -r<resource>=<n>::
# //        If resource management is supported, requests <n> units of resource
# //        <resource> to run the test. For instance to request two CPU cores
# //        and 1GB of memory: `-rcpu=2 -rmem=1000`. A test will be run in
# //        parallel of other already running tests if sufficient resources are
# //        available to satisfy its requests. The special resource 'all'
# //        requests all resources, effectively enforcing sequential execution.
# //        This is the default. See <<Resources>> subsection for details.
#
# Example:
#
#     regtest foobar-test1 \
#         --warn-only=2 \
#         foobar \
#         --input {}/a.foo \
#         --output {out.bar}
regtest() {
    local name=$1 extra_args=()
    shift

    while [[ ${1-} == -* ]]; do
        extra_args+=("$1")
        shift
    done

    # Can be used to reference outputs from a previous test. E.g.
    #     listing={ref}/$regtest_prev_test.listing.xml
    regtest_prev_test=$name

    _regtest_check_test_name "$name" ||
    case $? in
    1) return 0;; # Skipping test "$name"
    *) return 1;;
    esac

    printf '%s\n' "$name" >> "$_regtest_found_file"

    local dir=$regtest_inputdir${regtest_dir+/$regtest_dir}

    local args=("${@/'{}'/$dir}")
    local args=("${args[@]/'{ref}'/$regtest_refdir}")

    declare -A output_set=() tmpfile_set=()
    for ((i = 0; i < ${#args[@]}; i++)); do
        # Obviously limited: only supports up to one occurence of the {out.*} or {tmp.*} pattern
        # per arg.
        if [[ "${args[$i]}" =~ ^(.*)\{out(\.[a-zA-Z0-9._-]+)\}(.*)$ ]]; then
            local out_name=$name${BASH_REMATCH[2]}
            output_set[$out_name]=
            args[$i]=${BASH_REMATCH[1]}$regtest_outdir/$out_name${BASH_REMATCH[3]}
        elif [[ "${args[$i]}" =~ ^(.*)\{tmp(\.[a-zA-Z0-9._-]+)\}(.*)$ ]]; then
            local tmp_name=$name${BASH_REMATCH[2]}
            tmpfile_set[$tmp_name]=
            args[$i]=${BASH_REMATCH[1]}$regtest_tmpdir/$tmp_name${BASH_REMATCH[3]}
        fi
    done
    [[ ${#output_set[@]} != 0 ]] && mkdir -p "$regtest_outdir"
    [[ ${#tmpfile_set[@]} != 0 ]] && mkdir -p "$regtest_tmpdir"

    regtest_kill_children_on_exit
    (
        # Running `regtest_impl` in a subshell ensures it cannot modify the state of the test
        # suite subshell.
        _name=$name
        _outputs="${!output_set[@]}"
        _tmpfiles="${!tmpfile_set[@]}"
        _extra_args=(${extra_args+"${extra_args[@]}"})
        regtest_impl "${args[@]}" ${regtest_extra_args[@]+"${regtest_extra_args[@]}"}
    )
}

# _regtest_reset_timer
_regtest_reset_timer() {
    regtest_timer_start=$(date +%s)
}

# _regtest_minutes_and_seconds <seconds>
_regtest_minutes_and_seconds() {
    printf '%02d:%02d\n' $(($1 / 60)) $(($1 % 60))
}

# _regtest_record_status <test> <status>
# Record that test with name <test> exited with the status described by the string <status>, which
# must not contain spaces. If <status> is "ok", the test is considered to have succeeded,
# otherwise it is considered to have failed.
_regtest_record_status() {
    local test=$1 status=$2 time time_mns

    time=$(($(date +%s) - regtest_timer_start))
    time_mns=$(_regtest_minutes_and_seconds "$time")

    if [[ "$status" == ok ]]; then
        regtest_printn '\e[32;1m[OK]\e[0m \e[2m%s\e[0m  %s' "$_name" "$time_mns"
    else
        regtest_printn '\e[%s;1m[FAILED]\e[0m \e[2m%s\e[0m  (%s)  %s' \
                "$(if [[ "$status" != *'(ignored)' ]]; then echo 31; else echo 33; fi)" \
                "$_name" "$status" "$time_mns"
    fi

    printf '%s %s %s %s\n' "$regtest_suite" "$test" "$status" "$time" >> "$_regtest_status_file"
}

# _regtest_report_run_error <name> <logfile> <ret> [<ignored>]
# Report that the test with name <name> exited with (non-zero) error code <ret> and that a log of
# the test's standard and error outputs can be found in <logfile>, and print the last few lines of
# <logfile>. Records the status of the test as "run", or "run(<ignored>)" if <ignored> is not
# empty. In this manner, if <ignored> is "ignored", the 'regtest_print_summary' function can omit
# to count it towards the total error count.
_regtest_report_run_error() {
    local name=$1 logfile=$2 ret=$3 ignored=${4-}
    regtest_printn >&2 "Error: Command %s exited with error (code %d)" "$name" "$ret"
    if [[ "$regtest_forward_output_pattern" != . ]]; then # (not everything forwarded already)
        regtest_printn >&2 "\e[34;1;2m=== Last 20 lines of log ===\e[0m"
        tail -n20 "$logfile" | sed -e$'s/^/\e[0;2m[.......] /' -e$'s/\(\e\[[^m]*\)m/\\1;2m/g'
        regtest_printn >&2 "\e[34;1;2m============================\e[0m"
    fi
    regtest_printn >&2 "Full log: less -R %s" "$logfile"
    _regtest_record_status "$name" run${ignored:+"($ignored)"}
}

# _regtest_init_logdir
# Initialise the log directory for this session.
_regtest_init_logdir() {
    [[ -d "$regtest_logdir/$regtest_session" ]] || {
        if [[ "$regtest_run_loglevel" != error ]]; then
            regtest_printn 'Using %s as log directory.' "$regtest_logdir/$regtest_session"
        fi
        mkdir -p "$regtest_logdir/$regtest_session"
        [[ -L "$regtest_logdir/last" || ! -e "$regtest_logdir/last" ]] || {
            regtest_printn >&2 "Error: %s exists and is not a symbolic link." "$regtest_logdir/last"
            return 1
        }
        ln -nsf "$regtest_session" "$regtest_logdir/last"
    }
}

# _regtest_forward_command_output_full_pattern
# The (extended) regular expression describing which lines of a regtest's command standard and
# error output to forward to the current standard output.
_regtest_forward_command_output_full_pattern() {
    echo "\[regtest\]${regtest_forward_output_pattern:+"|($regtest_forward_output_pattern)"}"
}

# _regtest_forward_command_output
# Keep only lines in stdin matching (case-insensitively) "[regtest]" or the user-supplied
# 'regtest_forward_output_pattern' *and* not starting with "(regtest-ignore)". If
# 'regtest_forward_output_pattern' is set to "." however, this does not apply and all lines are
# kept.
_regtest_forward_command_output() {
    if [[ "${regtest_forward_output_pattern-}" == . ]]; then
        cat
    else
        gawk -vIGNORECASE=1 "
            /^\(regtest-ignore\)/ { next }
            /$(_regtest_forward_command_output_full_pattern)/ { print; fflush() }
            { next }"
    fi
}

## regtest_launch <command...> (monkey-patchable)
# Launch command to be tested.
regtest_launch() {
    "$@"
}

## regtest_impl <command...> (monkey-patchable)
# The central nervous system of the framework. Runs a test, handles its output, records its
# result, etc. Called by 'regtest'.
# Note: `run-tests.sh`'s `-l` and `-p` options are implemented by monkey-patching this function.
# The following (global) input variables are set by the 'regtest' function before it calls
# 'regtest_impl':
#
#    _name::
#        Test name (see 'regtest' <name>).
#    _outputs::
#        Space-separated list of (unique) output file names ({out.<ext>} patterns).
#    _tmpfiles::
#        Space-separated list of (unique) temporary file names ({tmp.<ext>} patterns).
#    _extra_args::
#        `[--warn-only=<return-code>...]`
#        If the <command...> returns any of the return codes specified by the `--warn-only`
#        options, its status will be recorded as "run(ignored)" and it will not be taken into
#        account for 'regtest_print_summary''s exit status (but will still result in a warning).
regtest_impl() {
    declare -A warn_only
    local arg
    for arg in ${_extra_args+"${_extra_args[@]}"}; do
        case $arg in
        --warn-only*)
            [[ "${arg#*=}" =~ ^[0-9]+$ ]] || {
                regtest_printn >&2 'Error: Invalid --warn-only=<retcode> argument: %s' "$arg"
                exit 1
            }
            warn_only[${arg#*=}]=1
            ;;
        *)
            regtest_printn >&2 'Error: Unrecognised option: %s' "$arg"
            exit 1
            ;;
        esac
    done

    _regtest_reset_timer
    _regtest_init_logdir
    local logdir=$regtest_logdir/$regtest_session
    local logfile=$logdir/$_name
    local out_name tmp_name

    for out_name in $_outputs; do
        rm -rf "$regtest_outdir/$out_name"
    done

    if [[ $regtest_generate && ! -d "$regtest_refdir" ]]; then
        regtest_printn >&2 "Error: Reference directory '%s' not found. Exiting." \
                           "$regtest_refdir"
        exit 1
    fi

    # Clear old output files to prevent false negatives.
    for out_name in $_outputs; do
        rm -rf "$regtest_outdir/$out_name"
    done
    for tmp_name in $_tmpfiles; do
        rm -rf "$regtest_tmpdir/$tmp_name"
    done

    _normal_exit=
    regtest_on_exit "
        [[ \$_normal_exit ]] || {
            regtest_printn >&2 '\e[31;1;1m[INTERRUPTED]\e[0m \e[2m%s\e[0m' $(printf %q "$_name")
            regtest_printn >&2 'Log: %s' $(printf %q "$logfile")
            _regtest_record_status "$_name" interrupted
        }"

    regtest_printn "Running test command '%s'." "$*" > "$logfile"
    regtest_printn "\e[32;1;2m[RUN]\e[0m %s" "$_name"
    regtest_kill_children_on_exit
    regtest_launch "$@" &> >(tee -a "$logfile" | _regtest_forward_command_output) || {
        _regtest_report_run_error "$_name" "$logfile" $? ${warn_only[$?]+ignored}
        _normal_exit=1
        return
    }

    for out_name in $_outputs; do
        # Test has outputs.
        regtest_printn 'Comparing output and reference (%s)...' "${out_name##*.}"
        if [[ ! -e "$regtest_refdir/$out_name" ]]; then
            if [[ $regtest_generate ]]; then
                regtest_printn "Moving output file to reference directory..."
                cp -rn "$regtest_outdir/$out_name" "$regtest_refdir/"
            else
                regtest_printn >&2 "Error: Reference file not found."
                _regtest_record_status "$_name" missing-ref
                _normal_exit=1
                return
            fi
        fi
        regtest_ref_diff "$out_name" || {
            [[ $? == $_regtest_ret_fatal ]] && {
                _regtest_record_status "$_name" fatal
                _normal_exit=1
                return
            }
            regtest_printn >&2 "Output differs from reference output '%s'." \
                               "$regtest_outdir/$out_name"
            if regtest_ref_compare "$out_name"; then
                regtest_printn "(...but found no difference during comparison!)"
                _regtest_record_status "$_name" diff
            else
                _regtest_record_status "$_name" comparator
            fi
            _normal_exit=1
            return
        }
        # OK. Remove the output.
        rm -r "$regtest_outdir/$out_name"
    done

    # Remove temporary files if all went well.
    if [[ ! $regtest_keep_tmpfiles ]]; then
        for tmp_name in $_tmpfiles; do
            rm -r "$regtest_tmpdir/$tmp_name"
        done
    fi

    _regtest_record_status "$_name" ok
    _normal_exit=1
}

## regtest_print_summary
# Print a summary of all tests that have already been run in the current session. Already called
# in 'regtest_finish'. Returns:
#
# - 0 if all tests were run and their statuses all match ``ok'' or ``*(ignored)'';
# - 11 if some tests that should have been run do not have a status recorded;
# - 10 otherwise (i.e. all tests were run but some failed and were not ignored).
regtest_print_summary() {
    local total_time=$(_regtest_minutes_and_seconds "$1")
    local ret=0 failures=() ignored_failures=() all_ok silent

    all_ok=$(awk '$3 != "ok" { exit 1 }' "$_regtest_status_file" && echo 1 || true)
    silent=$([[ $regtest_summary_loglevel == error && $all_ok ]] && echo 1 || true)

    [[ $silent ]] || {
        regtest_printn ''
        regtest_printn 'Summary'
        regtest_printn '-------'
    }
    local suite testname status time print_ok_tests=1
    while read -r suite testname status time; do
        time=$(_regtest_minutes_and_seconds "$time")
        if [[ "$testname" == - ]]; then
            # New test suite.
            if [[ "$status" == ok ]]; then
                [[ $silent ]] || printf '!!!!!!%s OK - %s\n' "$suite" "$time"
                print_ok_tests=$([[ $regtest_summary_loglevel == 'test' ]] && echo 1 || true)
            else
                ret=10
                printf '!!!!!!%s FAILED (%s) %s\n' "$suite" "$status" "$time"
                print_ok_tests=1
            fi
        else
            if [[ "$status" == ok ]]; then
                if [[ $print_ok_tests ]]; then
                    printf "%s OK - %s\n" "$testname" "$time"
                fi
            else
                if [[ "$status" != *'(ignored)' ]]; then
                    ret=10
                    failures+=("$testname")
                    printf "%s FAILED (%s) %s\n" "$testname" "$status" "$time"
                else
                    ignored_failures+=("$testname")
                    printf "%s failed (%s) %s\n" "$testname" "$status" "$time"
                fi
            fi
        fi
    done < <(LC_ALL=C sort -sk1,1 "$_regtest_status_file") \
         > >(column -t |
             sed -e$'s/^!!!!!!\([^ ]*\)/\e[1mSUITE \\1/' \
                 -e$'s/  OK  /  \e[32mOK\e[39m  /' \
                 -e$'s/  FAILED  /  \e[31mFAILED\e[39m  /' \
                 -e$'s/  failed  /  \e[33mFAILED\e[39m  /' \
                 -e"s/^/$regtest_print_prefix/" \
                 -e$'s/$/\e[0m/')
    wait_for_last_process_substitution

    if [[ $ret != 0 ]]; then
        regtest_printn '=> \e[31mFAILED\e[0m  %s' "$total_time"
    elif [[ ! $silent ]]; then
        regtest_printn '=> \e[32mOK\e[0m  %s' "$total_time"
    fi

    [[ ${#ignored_failures[@]} != 0 ]] && {
        regtest_printn '\e[33;1mWarning: Ignored %s failing test case%s:\e[0m %s' \
                       "${#ignored_failures[@]}" \
                       "$([[ ${#ignored_failures[@]} != 1 ]] && echo s)" \
                       "${ignored_failures[*]}"
    }
    [[ ${#failures[@]} != 0 ]] && {
        regtest_printn 'Recorded %s failing test case%s: %s' \
                       "${#failures[@]}" \
                       "$([[ ${#failures[@]} != 1 ]] && echo s)" \
                       "${failures[*]}"
    }

    local executed
    executed=$(awk '$2 != "-" { print $2 }' "$_regtest_status_file")
    [[ "$executed" == "$(cat "$_regtest_found_file")" ]] || {
        regtest_printn "\e[31;1mError: Not all matching tests were run!\e[0m"
        return 11
    }

    return $ret
}

# _regtest_kill_after_timeout <first-timeout> <second-timeout> <command...>
# Run `<command...>`, and if that takes longer than `sleep <first-timeout> <second-timeout>`, kill
# the process, although if <second-timeout> is of the form `*<n>`, it will be replaced with
# `$((<first-timeout> * <n>))`.
# Returns '_regtest_ret_timeout' if the command took longer than `sleep <first-timeout>`.
_regtest_kill_after_timeout() {
(
    local timeout1=$1 timeout2=$2 killer pid ret timeout_canary full_timeout
    shift 2

    if [[ "$timeout2" == '*'* ]]; then
        timeout2=$(_regtest_multiply_time "$timeout1" "${timeout2#'*'}")
    fi
    if [[ "$timeout2" == 0 ]]; then
        full_timeout=$timeout1
    else
        full_timeout=$timeout1+$timeout2
    fi

    timeout_canary=$(mktemp "$_regtest_tmp/timeout-XXXXX")
    regtest_on_exit 'rm -f "$timeout_canary"'

    regtest_kill_children_on_exit
    "$@" & pid=$!
    (
        regtest_kill_children_on_exit
        sleep "$timeout1" 2</dev/null # (redirection is a bash 4.2 workaround)
        rm "$timeout_canary"
        if [[ "$timeout2" != 0 ]]; then
            regtest_printn >&2 \
                "\e[31;1mError: '%s' took too long (exceeded %s). Will still wait another %s...\e[0m" \
                "$*" "$timeout1" "$timeout2"
            sleep "$timeout2"
        fi
        regtest_printn >&2 \
            "\e[31;1mError: '%s' took too long (exceeded %s). Killing process!\e[0m" \
            "$*" "$full_timeout"
        regtest_nice_kill $pid
    ) >/dev/null </dev/null &

    wait $pid
    ret=$?
    [[ -e "$timeout_canary" ]] || return $_regtest_ret_timeout
    return $ret
)
}

# _regtest_time_to_seconds <time>
# Convert time in the format `[0-9]*.?[0-9]*[smh]` to seconds.
_regtest_time_to_seconds() {
    local t=$1 f
    [[ "$t" =~ ^([0-9.]+)([smh]?)$ ]]
    case ${BASH_REMATCH[2]:-s} in s) f=1;; m) f=60;; h) f=3600;; esac
    gawk </dev/null -vf="$f" -vt="${BASH_REMATCH[1]}" 'BEGIN { print f * t }'
}

# _regtest_multiply_time <time> <factor>
# Print the result of multiplying <time> by <factor>.
_regtest_multiply_time() {
    local time=$1 factor=$2
    gawk </dev/null -vt="${time%[smh]}" -ve="${time##*[^smh]}" -vf="$factor" \
        'BEGIN { printf "%.3f%s\n", t * f, e }'
}

# _regtest_suite_timeout <suite-file>
# Determine the timeout to apply to the test suite corresponding to file path <suite-file> by
# multiplying the base timeout 'regtest_suite_timeout' by the "regtest-timeout-factor" if the test
# suite specifies one in a comment. Otherwise, just returns 'regtest_suite_timeout'.
_regtest_suite_timeout() {
    local suite_file=$1 factor

    if [[ "$regtest_suite_timeout" == inf ]]; then
        echo inf
    else
        factor=$(
            gawk '$1 == "#" && $2 == "regtest-timeout-factor:" { print $3; done = 1; exit }' \
                 "$suite_file"
        )
        if [[ -n "$factor" ]]; then
            _regtest_multiply_time "$regtest_suite_timeout" "$factor"
        else
            printf '%s\n' "$regtest_suite_timeout"
        fi
    fi
}

# _regtest_check_loglevel <log-level>
# Check that <log-level> is a valid log level.
_regtest_check_loglevel() {
    [[ "$1" =~ ^(error|suite|test)$ ]] || {
        regtest_printn >&2 "Error: Not a valid log level: %s" "$1"
        return 1
    }
}

## regtest_start
# Initialise variables in preparation for running the suite set.
regtest_start() {
    _regtest_start_time=$(date +%s)

    regtest_suite=-

    _regtest_check_loglevel "$regtest_run_loglevel" || exit 1
    _regtest_check_loglevel "$regtest_summary_loglevel" || exit 1

    # Prevent contamination of test suite environment.
    unset regtest_dir
}

# _suite_status <file>
# Prints a status summarising the statuses of all tests in status file <file>: "ok" or
# "<failed>/<total>".
_suite_status() {
    gawk '
        NR == 1 { suite = $1 }
        $1 != suite { print "Error: Different suites: " $1 " and " suite > "/dev/stderr"; exit 1 }
        $3 == "ok"          { next }
        $3 ~ /\(ignored\)$/ { next }
                            { failed++ }
        END { if (failed) print failed "/" NR; else print "ok" }
    ' "$1"
}

# _regtest_filter_suite_output <suite-name>
# Filter test suite output taking into account 'regtest_run_loglevel'.
_regtest_filter_suite_output() {
    local name=$1
    gawk -vlogfile="$regtest_logdir/$regtest_session/$name.suitelog" \
         -vprefix="${regtest_print_prefix//$'\e'/\\033}" \
         -vname="$name" \
         -vprint_suite=$([[ $regtest_run_loglevel =~ ^(suite|test)$ ]] && echo 1 || true) \
         -vprint_test=$([[ $regtest_run_loglevel == 'test' ]] && echo 1 || true) '
        NR == 1 {
            first_line = prefix "\033[32;1;2m[SUITE RUN]\033[0;1m " name "\033[0m"
            print first_line >>logfile
            if (print_suite) print first_line
        }
        { print >>logfile }
        print_test {
            print
            next
        }
        $1 == gensub(/\s*$/, "", 1, prefix) && $2 ~ /\[FAILED\]/ {
            close(logfile)
            if (print_suite) getline <logfile
            while (getline <logfile) print
            print_suite = print_test = 1
        }
    '
}

# _regtest_append_suite_status <suite> <start-time> <suite-return-code>
# Append status of suite <suite> to main status file.
_regtest_record_suite_status() {
    local name=$1 start_time=$2 r=$3
    local tmp_status_file=$_regtest_status_file.$name

    time=$(($(date +%s) - start_time))
    time_mns=$(_regtest_minutes_and_seconds "$time")
    [[ -s "$tmp_status_file" ]] && suite_status=$(_suite_status "$tmp_status_file")

    case $r in
    0)
        if [[ "$suite_status" ]]; then
            if [[ "$suite_status" == ok ]]; then
                if [[ $regtest_run_loglevel =~ ^(suite|test)$ ]]; then
                    regtest_printn '\e[32;1m[SUITE OK]\e[0m \e[1;2m%s\e[0;1m  %s\e[0m' \
                                   "$name" "$time_mns"
                fi
            else
                regtest_printn '\e[31;1m[SUITE FAILED]\e[0m \e[1;2m%s\e[0;1m  (%s)  %s\e[0m' \
                               "$name" "$suite_status" "$time_mns"
            fi
            printf '%s - %s %s\n' "$name" "$suite_status" "$time" >> "$_regtest_status_file"
        fi
        ;;
    $_regtest_ret_timeout)
        regtest_printn '\e[31;1m[SUITE TIMED OUT]\e[0m \e[2m%s\e[0m  %s' "$name" "$time_mns"
        printf '%s - timeout %s\n' "$name" "$time" >> "$_regtest_status_file"
        ;;
    '')
        regtest_printn '\e[31;1m[SUITE KILLED]\e[0m \e[2m%s\e[0m  %s' "$name" "$time_mns"
        printf '%s - killed %s\n' "$name" "$time" >> "$_regtest_status_file"
        ;;
    *)
        regtest_printn '\e[31;1m[SUITE FAILED UNEXPECTEDLY?!]\e[0m \e[2m%s\e[0m  %s' "$name" \
                                                                                     "$time_mns"
        printf '%s - unexpected-failure %s\n' "$name" "$time" >> "$_regtest_status_file"
        ;;
    esac

    if [[ -e "$tmp_status_file" ]]; then
        cat "$tmp_status_file" >> "$_regtest_status_file"
        rm "$tmp_status_file"
    fi
}

## regtest_run_suite <name> <command...>
# Run a single test suite <name>, using the command <command...>. <command...> will be killed if
# it exceeds 'regtest_suite_timeout'.
regtest_run_suite() {
(
    local name=$1 time r= suite_status= tmp_status_file
    shift

    time=$(date +%s)
    _regtest_init_logdir
    tmp_status_file=$_regtest_status_file.$name

    regtest_kill_children_on_exit
    regtest_on_exit '_regtest_record_suite_status "$name" "$time" "$r"'

    {
        regtest_kill_children_on_exit
        regtest_suite=$name \
        _regtest_status_file=$tmp_status_file \
        _regtest_kill_after_timeout "$regtest_suite_timeout" "$regtest_suite_timeout2" "$@"
    } |& _regtest_filter_suite_output "$name" && r=0 || r=${PIPESTATUS[0]}
)
}

## regtest_finish
# Finalise all tests by printing a summary and returning an error code. If there are still
# unmatched globs, returns error code 12. Otherwise, returns 'regtest_print_summary''s error code.
regtest_finish() {
    local ret=0

    if [[ ! -s "$_regtest_found_file" ]]; then
        regtest_printn >&2 'No matching tests found.'
        ret=12
    elif [[ -s "$_regtest_status_file" ]]; then
        if [[ "$(wc -l <"$_regtest_found_file")" == 1 ]]; then
            # Don't bother printing a summary if only one test was run.
            gawk -vr=10 '$3 == "ok" { r = 0 } END { exit r }' "$_regtest_status_file" || ret=$?
        else
            regtest_print_summary $(($(date +%s) - _regtest_start_time)) || ret=$?
        fi
    fi

    if [[ -s "$_regtest_unmatched_glob_file" ]]; then
        regtest_printn "\e[31;1mError: Unmatched glob%s: %s\e[0m" \
                "$([[ $(wc -l <"$_regtest_unmatched_glob_file") != 1 ]] && echo s)" \
                "$(tr '\n' ' ' <"$_regtest_unmatched_glob_file")"
        ret=12
    fi

    return $ret
}

## regtest_run_suites <dir> <suites...>
# For each test suite <suite> in <suites...>, run suite `<dir>/<suite>.sh`. A timeout of
# 'REGTEST_SUITE_TIMEOUT' (default: `5m` —5 minutes) will be applied to each test suite. If a test
# suite exceeds the timeout it will be canceled and an error (`<suite>[SUITE-TIMEOUT]`) will be
# appended to the error summary. If you need for a test suite to have a different timeout than
# 'REGTEST_SUITE_TIMEOUT' you can add a shell comment of the following form to the test suite
# file:
#
#     # regtest-timeout-factor: <f>
#
# Where <f> is a real number which will be multiplied by 'REGTEST_SUITE_TIMEOUT' to derive the new
# timeout. For instance, with the default timeout of 5 minutes, <f> = 2 implies a timeout of 10
# minutes, and <f> = .5 implies a timeout of 2 minutes and 30 seconds.
regtest_run_suites() {
    local dir=$1
    shift

    regtest_start
    regtest_on_exit regtest_finish

    for suite in $(
        if [[ $regtest_run_suites_in_random_order ]]; then
            shuf -e "$@"
        else
            printf '%s\n' "$@"
        fi
    ); do
        local timeout
        # A test suite should not take more than ~5 minutes.
        timeout=$(_regtest_suite_timeout "$dir/$suite.sh")
        regtest_suite_timeout=$timeout regtest_run_suite "${suite//\//-}" . "$dir/$suite.sh"
    done
}

## regtest_run_suite_func <name> <function>
# Run a single test suite, named <name>, defined by the function <function>. Useful for
# single-suite suite sets.
regtest_run_suite_func() {
    local name=$1 func=$2
    regtest_start
    regtest_on_exit regtest_finish
    regtest_run_suite "$name" "$func"
}

# == Global Configuration

# Glob of names of tests to run.
regtest_globs=('*')
# Glob of names of tests not to run (takes priority over 'regtest_globs').
regtest_exclude_globs=()
# Extra arguments to pass to every regtest command to be run.
regtest_extra_args=()

# Path of directory containing input files. The pattern `{}` in regtest commands will be expanded
# to `$regtest_input_dir/$regtest_dir`, where 'regtest_dir' is user-defined.
regtest_inputdir=${REGTEST_INPUTDIR-inputs}
# Path of directory containing input files. The pattern `{ref}` in regtest commands will be
# expanded to `$regtest_refdir`.
regtest_refdir=${REGTEST_REFDIR-refs}
# Path of directory to which to write output files (to be compared against reference files). The
# pattern `{out.<extension>}` in regtest commands will be expanded to
# `$regtest_outdir/<test-name>.<test-version>.<extension>`.
regtest_outdir=${REGTEST_OUTDIR-out}
# Directory to which to write temporary output files (i.e. which are not to be compared to
# reference files). The pattern `{tmp.<extension>}` in regtest commands will be expanded to
# `$regtest_tmpdir/<test-name>.<test-version>.<extension>`.
regtest_tmpdir=${REGTEST_TMPDIR-$regtest_outdir/tmp}
# Directory to which to write log files (i.e. standard output and error of regtest commands).
regtest_logdir=${REGTEST_LOGDIR-log}

# Never remove "temporary" files on exit if a specific temporary directory has been requested.
# By default, only files from failed runs are kept.
regtest_keep_tmpfiles=$(if [[ -n "${REGTEST_TMPDIR-}" ]]; then echo 1; fi)

_regtest_unique_session() {
    local r i
    r=$(date +%Y-%m-%d-%H:%M:%S)
    if [[ -e "$regtest_logdir/$r" ]]; then
        r=$r.$(date +%N)
        [[ -e "$r" ]] && {
            regtest_printn >&2 "Error: No way this session already exists: '%s'!" "$r"
            return 1
        }
    fi
    echo "$r"
}

[[ "${regtest_session-}" ]] || regtest_session=$(_regtest_unique_session)

# Whether to generate reference files during this run.
regtest_generate=

# The level of detail of information printed while running tests. From least to most verbose:
#
#     error:: Print error messages;
#     suite:: ...and information about test suites;
#     test::  ...and information about individual test cases (i.e. everything).
: ${regtest_run_loglevel=test}

# The level of detail of the summary. From least to most verbose:
#
#     error:: Print failed test suites and test cases;
#     suite:: ...and a line for each test suite (whether OK or FAILED);
#     test::  ...and a line for each test case (whether OK or FAILED).
: ${regtest_summary_loglevel=test}

# Lines of a regtest command's output (on stderr or stdout) matching this extended regex will be
# forwarded to standard output (instead of being written only to the log file).
: ${regtest_forward_output_pattern=}

# Whether to launch test suites in random order. Tests within a test suite are always run in the
# order they are written in.
: ${regtest_run_suites_in_random_order=1}

# The base timeout for a test suite (in the format accepted by the `sleep` command). If a test
# suite file contains a line of the form `# regtest-timeout-factor: <n>`, where `<n>` is a real
# number, that suite's timeout will be multiplied by `<n>`. If a test suite exceeds said timeout,
# an error will be generated regarding the timeout, and it will be halted immediately, unless
# 'regtest_suite_timeout2' is not "0".
regtest_suite_timeout=5m

# If non-zero ("0"), the test suite will be granted extra time to finish (but the suite itself
# will still fail with a timeout error). More precisely, this can be set to a time (in the format
# accepted by the `sleep` command), in which case that amount of extra time will be granted.
# Alternatively, a multiplicative factor can be given in the format `*<factor>`, in which case
# `<factor> * $regtest_suite_timeout` extra time will be granted.
regtest_suite_timeout2=0

case ${REGTEST_SUITE_TIMEOUT-} in
    '')  ;;
    +*)  regtest_suite_timeout2=${REGTEST_SUITE_TIMEOUT#+}
         ;;
    *+*) regtest_suite_timeout=${REGTEST_SUITE_TIMEOUT%+*}
         regtest_suite_timeout2=${REGTEST_SUITE_TIMEOUT#*+}
         ;;
    *)   regtest_suite_timeout=$REGTEST_SUITE_TIMEOUT
         ;;
esac

# Bash regex which test names _must_ match (useful for keeping things nice and consistent). Must
# contain a parenthesised part indicating the actual name part (to match against 'regtest_globs').
# This makes it possible to have a version suffix for instance.
: ${regtest_name_regex='^([a-z0-9-]+)$'}
