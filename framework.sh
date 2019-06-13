#!/bin/bash

# = Regression/Integration Test Framework

set -euo pipefail

. "$(readlink -m "$BASH_SOURCE/..")"/utils.sh

# List of found tests (newline-delimited).
_regtest_found_file=$regtest_tmp/found
# Test statuses (newline-delimited). Record format: `<test> <status> <failure-detail> <time>`.
_regtest_status_file=$regtest_tmp/statuses

# regtest_ref_checksum <path>
# Prints checksum of a reference file.
regtest_ref_checksum() { true; }

# regtest_out_checksum <path>
# Prints checksum of an output file.
regtest_out_checksum() { true; }

# regtest_ref_diff <filename>
# Whether reference and output files (or directories) differ. Uses `regtest_ref_checksum` and
# `regtest_out_checksum` if they both return a non-empty string, otherwise, just uses `diff -r`.
regtest_ref_diff() {
    local out_name=$1 ref=$regtest_outdir/$out_name out=$regtest_refdir/$out_name
    local ref_sum out_sum

    ref_sum=$(regtest_ref_checksum "$regtest_refdir/$out_name") || return $regtest_ret_fatal
    out_sum=$(regtest_out_checksum "$regtest_outdir/$out_name") || return $regtest_ret_fatal

    if [[ -z "$ref_sum" || -z "$out_sum" ]]; then
        diff -qr "$ref" "$out" >/dev/null || {
            if [[ $? == 1 ]]; then return 1
            else return $regtest_ret_fatal
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

# regtest_ref_compare_impl <output-filename>
# Compare a reference and an output – implementation. Could be overridden (monkey-patched) if
# needed. Outputs full log to stdout, partial log and info messages to stderr.
regtest_ref_compare_impl() {
    local out_name=$1
    local ref=$regtest_refdir/$out_name
    local out=$regtest_outdir/$out_name

    regtest_diff "$ref" "$out" | tee >(head -n30 >&2; cat >/dev/null) || return 1
    return 0
}

# regtest_ref_compare <output-filename>
# Compare a reference and an output. Could be overridden (monkey-patched) if needed. It is
# expected that the partial log generated by `regtests_ref_compare_impl` will be sent to stderr
# while the full log will be sent to stdout.
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

regtest_matches_a_glob() {
    local name=$1

    local glob
    for glob in ${regtest_exclude_globs+"${regtest_exclude_globs[@]}"}; do
        [[ "$name" == $glob ]] && return 1
    done
    for glob in "${regtest_globs[@]}"; do
        [[ "$name" == $glob ]] && return 0
    done
    return 1
}

declare _name
declare _outputs
declare _tmpfiles
declare -a _extra_args

regtest() {
    local name=$1 extra_args=()
    shift

    while [[ ${1-} == -* ]]; do
        extra_args+=("$1")
        shift
    done

    [[ "$name" =~ $regtest_name_regex ]] || {
        regtest_printn >&2 'Error: Bad test name: %s. Was expected to match %s' \
                           "$name" "$regtest_name_regex"
        return 1
    }
    local name_only=${BASH_REMATCH[1]}

    # Can be used to reference outputs from a previous test. E.g.
    #     listing={ref}/$regtest_prev_test.listing.xml
    regtest_prev_test=$name

    if ! regtest_matches_a_glob "$name_only"; then
        # Skipping test "$name"
        return 0
    fi
    printf '%s\n' "$name" >> "$_regtest_found_file"

    local dir=$regtest_inputdir/$regtest_dir

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

    _name=$name
    _outputs="${!output_set[@]}"
    _tmpfiles="${!tmpfile_set[@]}"
    _extra_args=(${extra_args+"${extra_args[@]}"})
    regtest_impl "${args[@]}" ${regtest_extra_args[@]+"${regtest_extra_args[@]}"}
}

regtest_reset_timer() {
    regtest_timer_start=$(date +%s)
}

regtest_minutes_and_seconds() {
    printf '%02d:%02d\n' $(($1 / 60)) $(($1 % 60))
}

regtest_record_status() {
    local test=$1 status=$2 time time_mns

    time=$(($(date +%s) - regtest_timer_start))
    time_mns=$(regtest_minutes_and_seconds "$time")

    if [[ "$status" == ok ]]; then
        regtest_printn '\e[32;1m[OK]\e[0m \e[2m%s\e[0m  %s' "$_name" "$time_mns"
    else
        regtest_printn '\e[31;1m[FAILED]\e[0m \e[2m%s\e[0m  %s' "$_name" "$time_mns"
    fi

    printf '%s %s %s\n' "$test" "$status" "$time" >> "$_regtest_status_file"
}

regtest_report_run_error() {
    local name=$1 logfile=$2 ret=$3 ignored=${4-}
    regtest_printn >&2 "Error: Command %s exited with error (code %d)" "$name" "$ret"
    if [[ "$regtest_forward_output_pattern" != . ]]; then # (not everything forwarded already)
        regtest_printn >&2 "\e[34;1;2m=== Last 20 lines of log ===\e[0m"
        tail -n20 "$logfile" | sed -e$'s/^/\e[0;2m[.......] /' -e$'s/\(\e\[[^m]*\)m/\\1;2m/g'
        regtest_printn >&2 "\e[34;1;2m============================\e[0m"
    fi
    regtest_printn >&2 "Full log: less -R %s" "$logfile"
    regtest_record_status "$name" run${ignored:+"($ignored)"}
}

regtest_init_logdir() {
    mkdir -p "$regtest_logdir/$regtest_session"
    [[ -L "$regtest_logdir/last" || ! -e "$regtest_logdir/last" ]] || {
        super_printn "Error: %s exists and is not a symbolic link." "$regtest_logdir/last"
        return 1
    }
    ln -nsf "$regtest_session" "$regtest_logdir/last"
}

regtest_forward_command_output() {
    local user_pattern=${regtest_forward_output_pattern:+"\|\($regtest_forward_output_pattern\)"}
    grep --color=never -i "\[regtest\]$user_pattern"
}

# regtest_launch <command...>
# Launch command to be tested. Can be overridden (monkey-patched).
regtest_launch() {
    "$@"
}

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

    regtest_reset_timer
    regtest_init_logdir
    local logdir=$regtest_logdir/$regtest_session
    local logfile=$logdir/$_name
    local out_name tmp_name

    for out_name in $_outputs; do
        rm -rf "$regtest_outdir/$out_name"
    done

    if [[ "$regtest_generate" == 1 && ! -d "$regtest_refdir" ]]; then
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

    regtest_printn "Running test command '%s'." "$*" > "$logfile"
    regtest_printn "\e[32;1;2m[RUN]\e[0m %s" "$_name"
    regtest_kill_children_on_exit
    regtest_launch "$@" &> >(tee -a "$logfile" | regtest_forward_command_output) || {
        regtest_report_run_error "$_name" "$logfile" $? ${warn_only[$?]+ignored}
        return
    }

    for out_name in $_outputs; do
        # Test has outputs.
        regtest_printn 'Comparing output and reference (%s)...' "${out_name##*.}"
        local ret=0
        if [[ ! -e "$regtest_refdir/$out_name" ]]; then
            if [[ "$regtest_generate" == 1 ]]; then
                regtest_printn "Moving output file to reference directory..."
                cp -rn "$regtest_outdir/$out_name" "$regtest_refdir/"
            else
                regtest_printn >&2 "Error: Reference file not found."
                regtest_record_status "$_name" missing-ref
                return
            fi
        fi
        regtest_ref_diff "$out_name" || ret=$?
        if [[ $ret != 0 ]]; then
            [[ $ret == $regtest_ret_fatal ]] && {
                regtest_record_status "$_name" fatal
                return
            }
            regtest_printn >&2 "Output differs from reference output '%s'." \
                               "$regtest_outdir/$out_name"
            if regtest_ref_compare "$out_name"; then
                regtest_printn "(...but found no difference during comparison!)"
                regtest_record_status "$_name" diff
            else
                regtest_record_status "$_name" comparator
            fi
            return
        fi
        # OK. Remove the output.
        rm -r "$regtest_outdir/$out_name"
    done

    # Remove temporary files if all went well.
    if [[ "$regtest_keep_tmpfiles" == 0 ]]; then
        for tmp_name in $_tmpfiles; do
            rm -r "$regtest_tmpdir/$tmp_name"
        done
    fi

    regtest_record_status "$_name" ok
}

regtest_print_summary() {
    local total_time=$(regtest_minutes_and_seconds "$1")
    local ret=0 ignored_failures=0

    regtest_printn ''
    regtest_printn 'Summary'
    regtest_printn '-------'
    local testname status time
    while read -r testname status time; do
        time=$(regtest_minutes_and_seconds "$time")
        if [[ "$status" == ok ]]; then
            regtest_printn "%s \e[32mOK\e[0m - %s" "$testname" "$time"
        else
            if [[ "$status" != *'(ignored)' ]]; then
                ret=10
            else
                ((ignored_failures++))
            fi
            regtest_printn "%s \e[31mFAILED\e[0m (%s) %s" "$testname" "$status" "$time"
        fi
    done < <(sort "$_regtest_status_file") > >(column -t | sed 's/ //')

    sleep .1

    if [[ "$ret" == 0 ]]; then
        regtest_printn '=> \e[32mOK\e[0m  %s' "$total_time"
        ((ignored_failures > 0)) && {
            regtest_printn '\e[33;1mWarning: Ignored %s failure%s!\e[0m' \
                           "$ignored_failures" $( ((ignored_failures > 1)) && echo s )
        }
    else
        regtest_printn '=> \e[31mFAILED\e[0m  %s' "$total_time"
    fi

    [[ "$(wc -l "$_regtest_status_file" | awk '{print $1}')" == \
       "$(wc -l "$_regtest_found_file" | awk '{print $1}')" ]] || {
        regtest_printn "\e[33;1mWarning: Not all matching tests were run!\e[0m"
        return 11
    }

    return $ret
}

# regtest_kill_after_timeout <timeout> <command...>
# Run `<command...>`, and if that takes longer than `sleep <timeout>`, kill the process.
# Returns `$regtest_ret_timeout` in case of timeout.
regtest_kill_after_timeout() {
(
    local timeout=$1
    shift
    local killer pid ret timeout_canary

    timeout_canary=$(mktemp "$regtest_tmp/timeout-XXXXX")
    regtest_on_exit 'rm -f "$timeout_canary"'

    regtest_kill_children_on_exit
    "$@" & pid=$!
    (
        regtest_kill_children_on_exit
        sleep "$timeout"
        rm "$timeout_canary"
        # Print log in a detached process to make sure the log will be printed despite `kill -9`.
        regtest_printn >&2 \
            "\e[31;1mError: '%s' took too long (exceeded %s). Killing process!\e[0m" \
            "$*" "$timeout"
        regtest_nice_kill $pid
    ) >/dev/null </dev/null &

    wait $pid
    ret=$?
    [[ -e "$timeout_canary" ]] || return $regtest_ret_timeout
    return $ret
)
}

# Convert time in the format `[0-9]*.?[0-9]*[smh]` to seconds.
regtest_time_to_seconds() {
    local t=$1 f
    [[ "$t" =~ ^([0-9.]+)([smh]?)$ ]]
    case ${BASH_REMATCH[2]:-s} in s) f=1;; m) f=60;; h) f=3600;; esac
    awk </dev/null -vf="$f" -vt="${BASH_REMATCH[1]}" 'BEGIN { print f * t }'
}

regtest_suite_timeout() {
    local suite_file=$1

    if [[ "$regtest_suite_timeout" == inf ]]; then
        echo inf
    else
        awk -vt="$(regtest_time_to_seconds "$regtest_suite_timeout"))" '
            $1 == "#" && $2 == "regtest-timeout-factor:" { print $3 * t / 60 "m"; exit }
            ENDFILE                                      { print t / 60 "m" }' \
            "$suite_file"
    fi
}

# regtest_start
regtest_start() {
    _regtest_start_time=$(date +%s)

    # Prevent contamination of test suite environment.
    unset regtest_dir
}

# regtest_run_suite <name> <command...>
regtest_run_suite() {
    local name=$1
    shift
    regtest_kill_after_timeout "$regtest_suite_timeout" "$@" || {
        [[ $? == $regtest_ret_timeout ]] &&
            printf '%s[SUITE-TIMEOUT] timeout %.f\n' \
                   "$name" "$(regtest_time_to_seconds "$regtest_suite_timeout")" \
                   >>"$_regtest_status_file"
    }
}

# regtest_finish
regtest_finish() {
    [[ ! -s "$_regtest_found_file" ]] && return 1

    if [[ ! -s "$_regtest_status_file" ]]; then
        return 0
    elif [[ "$(wc -l "$_regtest_status_file")" == 1\ * ]]; then
        awk '$2 == "ok" { exit 0 } ENDFILE { exit 1 }' "$_regtest_status_file" || return 10
    else
        regtest_print_summary $(($(date +%s) - _regtest_start_time)) || return 10
    fi
}

# regtest_run_suites <dir> <suites...>
regtest_run_suites() {
    local dir=$1
    shift

    regtest_start

    for suite in $(
        if [[ "$regtest_run_suites_in_random_order" == 1 ]]; then
            shuf -e "$@"
        else
            printf '%s\n' "$@"
        fi
    ); do
        local timeout
        # A test suite should not take more than ~5 minutes.
        timeout=$(regtest_suite_timeout "$dir/$suite.sh")
        regtest_suite_timeout=$timeout regtest_run_suite "$suite" . "$dir/$suite.sh"
    done

    regtest_finish
}

# == Global Configuration

# Glob of names of tests to run.
regtest_globs=('*')
# Glob of names of tests not to run (takes priority over `regtest_globs`).
regtest_exclude_globs=()
# Extra arguments to pass to every regtest command to be run.
regtest_extra_args=()

# Path of directory containing input files. The pattern `{}` in regtest commands will be expanded
# to `$regtest_input_dir/$regtest_dir`, where `regtest_dir` is user-defined.
regtest_inputdir=${REGTEST_INPUTDIR-inputs}
# Path of directory containing input files. The pattern `{ref}` in regtest commands will be
# expanded to `$regtest_refdir`.
regtest_refdir=${REGTEST_REFDIR-refs}
# Path of directory to which to write output files (to be compared against reference files). The
# pattern `{out.<extension>}` in regtest commands will be expanded to
# `$regtest_outdir/<test-name>.<test-version>.<extension>`.
regtest_outdir=${REGTEST_OUTDIR-out}
# Directory to which to write temporary output files (i.e. which are not to be compared to
# reference files). The pattern `{ref.<extension>}` in regtest commands will be expanded to
# `$regtest_tmpdir/<test-name>.<test-version>.<extension>`.
regtest_tmpdir=${REGTEST_TMPDIR-$regtest_outdir/tmp}
# Directory to which to write log files (i.e. standard output and error of regtest commands).
regtest_logdir=${REGTEST_LOGDIR-log}

# Never remove "temporary" files on exit if a specific temporary directory has been requested.
# By default, only files from failed runs are kept.
regtest_keep_tmpfiles=$(if [[ -n "${REGTEST_TMPDIR-}" ]]; then echo 1; else echo 0; fi)

: ${regtest_session=$(date +%Y-%m-%d-%H:%M:%S)}

# Whether to generate reference files during this run.
regtest_generate=0

# Lines of a regtest command's output (on stderr or stdout) matching this grep regex will be
# forwarded to standard output (instead of being written only to the log file).
: ${regtest_forward_output_pattern=}

# Whether to launch test suites in random order. Tests within a test suite are always run in the
# order they are written in.
: ${regtest_run_suites_in_random_order=1}
# The base timeout for a test suite (in the format accepted by the `sleep` command). If a test
# suite file contains a line of the form `# regtest-timeout-factor: <n>`, where `<n>` is a real
# number, that suite's timeout will be multiplied by `<n>`. If a test suite exceeds said timeout,
# it will be immediately halted and an error will be generated regarding the timeout.
regtest_suite_timeout=${REGTEST_SUITE_TIMEOUT-5m}

# Bash regex which test names *must* match (useful for keeping things nice and consistent). Must
# contain a parenthesised part indicating the name (to match against `regtest_globs`). This makes
# it possible to have a version suffix for instance.
: ${regtest_name_regex='^([a-z0-9-]+)$'}
